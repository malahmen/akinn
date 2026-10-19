# The -x flow: undo what akinn's installs changed on this node, from the
# records save_run keeps in $AKINN_STATE/runs (newest first). Best effort, step
# by step: one failure is reported and the rest still runs; the records are
# only removed once everything went through, so -x can be run again.

UNINSTALL_FAILS=0

# Function: report a failed step without stopping.
# Usage example:
# some_command || uninstall_failed "what failed"
uninstall_failed() {
    oerr "$1"
    UNINSTALL_FAILS=$((UNINSTALL_FAILS + 1))
}

# Function: the uninstall entry point (-x). Exits.
# Usage example:
# uninstall
uninstall() {
    local runs run name_before
    runs=$(ls -1r "$AKINN_STATE/runs" 2>/dev/null)
    if [ -z "$runs" ]; then
        if [ -z "$FORCE" ]; then
            oerr "$ERR_NOREC"
            exit 1
        fi
        uninstall_unrecorded
    fi
    msg "Uninstalling: undoing what akinn's installs changed on this node."

    if ls "$AKINN_STATE"/runs/*/kubeadm >/dev/null 2>&1; then
        reset_cluster
    else
        wrn "akinn did not run kubeadm init/join here (the cluster was there before it): not reset."
    fi

    # Files before packages: a purge then takes the restored package defaults
    # (containerd's config.toml) with it instead of leaving them orphaned.
    for run in $runs; do
        undo_files "$AKINN_STATE/runs/$run"
        # newest first, so this ends at the name before the first install that set one
        [ -s "$AKINN_STATE/runs/$run/hostname" ] && name_before=$(cat "$AKINN_STATE/runs/$run/hostname")
    done

    release_packages

    if grep -qF "$FSTABF" "$AKINN_STATE"/runs/*/manifest 2>/dev/null; then
        swapon -a || uninstall_failed "swapon -a failed: check the swap lines in $FSTABF."
    fi
    if [ -n "$name_before" ]; then
        hostnamectl set-hostname "$name_before" \
            || uninstall_failed "Could not restore the hostname."
    fi
    sysctl --system >/dev/null 2>&1 || true

    if [ "$UNINSTALL_FAILS" -ne 0 ]; then
        oerr "$UNINSTALL_FAILS step(s) failed (above). The record stays in $AKINN_STATE: fix them and run -x again."
        exit 1
    fi
    rm -rf "$AKINN_STATE"
    msg "Uninstalled. Reboot to unload the kernel modules and drop the leftover network interfaces (cni0, tunl0, cali*)."
    exit 0
}

# Function: kubeadm reset, then what it leaves for the admin to clean: the CNI
# configuration and the Kubernetes/Calico iptables rules.
# Usage example:
# reset_cluster
reset_cluster() {
    local f d
    if command -v kubeadm >/dev/null 2>&1; then
        msg "Resetting this node's Kubernetes state (kubeadm reset)."
        kubeadm reset -f || uninstall_failed "kubeadm reset failed."
        # rmdir, not rm -r: only what reset left empty goes.
        for d in $KUBEADM_DIRS; do
            rmdir "$d" 2>/dev/null && msg "Removed the empty $d."
        done
    else
        wrn "kubeadm is not installed: no cluster state to reset."
    fi
    # Calico's files only: another CNI user (podman, for one) may share the folder.
    for f in "$CNI_CONF"/*calico*; do
        [ -e "$f" ] && rm -f "$f" && msg "Removed $f."
    done
    rmdir "$CNI_CONF" 2>/dev/null
    if [ -d "$CALICO_STATE" ]; then
        rm -rf "$CALICO_STATE" && msg "Removed $CALICO_STATE."
    fi
    for f in $CALICO_CNI_BINS; do
        [ -e "$CNI_BIN/$f" ] && rm -f "$CNI_BIN/$f" && msg "Removed $CNI_BIN/$f."
    done
    rmdir "$CNI_BIN" "${CNI_BIN%/*}" 2>/dev/null
    clean_k8s_iptables
}

# Function: drop the KUBE-* and Calico (cali-) chains and the rules that jump
# to them, keeping every other rule (Docker's, a firewall's). Not a flush.
# Usage example:
# clean_k8s_iptables
clean_k8s_iptables() {
    local t rules
    for t in iptables ip6tables; do
        command -v "$t-save" >/dev/null 2>&1 || continue
        rules=$("$t-save" 2>/dev/null) || continue
        printf '%s\n' "$rules" | grep -qE 'KUBE-|cali-|cali:' || continue
        if printf '%s\n' "$rules" | grep -vE 'KUBE-|cali-|cali:' | "$t-restore"; then
            msg "Removed the Kubernetes and Calico $t rules."
        else
            uninstall_failed "Could not remove the Kubernetes and Calico $t rules."
        fi
    done
}

# Function: unhold what akinn held, purge the Kubernetes and container packages
# akinn installed - unless that would take other packages with them.
# Usage example:
# release_packages
release_packages() {
    local held installed p remove keep
    held=$(cat "$AKINN_STATE"/runs/*/held 2>/dev/null | sort -u)
    if [ -n "$held" ]; then
        # shellcheck disable=SC2086 # one package per word
        apt-mark unhold $held >/dev/null || uninstall_failed "apt-mark unhold failed for: $held"
    fi
    installed=$(cat "$AKINN_STATE"/runs/*/packages 2>/dev/null | sort -u)
    remove=""; keep=""
    for p in $installed; do
        case " $K8S_PACKAGES " in
            *" $p "*) remove="$remove $p" ;;
            *) keep="$keep $p" ;;
        esac
    done
    if [ -n "$remove" ]; then
        # shellcheck disable=SC2086
        purge_packages $remove
    fi
    if [ -n "$keep" ]; then
        wrn "Left installed (akinn installed them, but other software may use them now):$keep"
    fi
}

# Function: apt-get purge, after a dry run: if apt would remove anything else
# (docker-ce depends on containerd.io, say), nothing is purged.
# Usage example:
# purge_packages kubelet kubeadm
purge_packages() {
    local extra
    extra=$(apt-get -s purge "$@" 2>/dev/null | sed -nE 's/^(Purg|Remv) ([^ :]+).*/\2/p' | grep -vxF "$(printf '%s\n' "$@")" | tr '\n' ' ')
    if [ -n "$extra" ]; then
        wrn "Not removing $*: apt would also remove ${extra% }, which depend on them. Remove them yourself if nothing needs them: sudo apt-get purge $*"
        return
    fi
    msg "Removing the packages akinn installed: $*"
    apt_get purge -y "$@" || { uninstall_failed "apt-get purge failed for: $*"; return; }
    purge_orphaned_dependencies
}

# Function: purge what apt pulled in for the packages just purged
# (K8S_DEPENDENCIES), once apt lists them as autoremovable - which is exactly
# when nothing installed needs them any more. Found on a real uninstall:
# kubernetes-cni stayed behind.
# Usage example:
# purge_orphaned_dependencies
purge_orphaned_dependencies() {
    local orphans p remove=""
    orphans=$(apt-get -s autoremove 2>/dev/null | sed -nE 's/^(Purg|Remv) ([^ :]+).*/\2/p')
    for p in $K8S_DEPENDENCIES; do
        printf '%s\n' "$orphans" | grep -qxF "$p" && remove="$remove $p"
    done
    [ -n "$remove" ] || return 0
    msg "Removing what apt installed for them:$remove"
    # shellcheck disable=SC2086 # one package per word
    apt_get purge -y $remove || uninstall_failed "apt-get purge failed for:$remove"
}

# Function: undo one run's file changes, newest first: remove what it created,
# put back what it replaced, take its marks out of shared files (fstab, apt
# sources) so later edits there stay.
# Usage example:
# undo_files "$AKINN_STATE/runs/0001-..."
undo_files() {
    local run="$1" tab saved origin kind
    tab=$(printf '\t')
    # A here-document, not a pipe: the loop must run in this shell to count failures.
    while IFS="$tab" read -r saved origin kind; do
        [ -n "$origin" ] || continue
        if [ "$kind" = "dir" ]; then
            [ -d "$origin" ] || continue
            if rmdir "$origin" 2>/dev/null; then
                msg "Removed $origin."
            else
                wrn "Left $origin: akinn created it, but it is not empty now."
            fi
        elif [ "$kind" = "edit" ]; then
            [ -f "$origin" ] || continue
            if sed -i -e "s/^$SWAP_MARK//" -e "s/^$DOCKER_MARK//" "$origin"; then
                msg "Took akinn's marks out of $origin."
            else
                uninstall_failed "Could not edit $origin."
            fi
        elif [ "$saved" = "-" ]; then
            if [ -e "$origin" ]; then
                rm -f "$origin" && msg "Removed $origin."
            fi
        elif cp -p "$run/$saved" "$origin"; then
            msg "Restored $origin."
        else
            uninstall_failed "Could not restore $origin from $run/$saved."
        fi
    done <<EOF
$(sed -n '1!G;h;$p' "$run/manifest")
EOF
}

# Function: -x -f on a node without a record (installed before akinn kept
# one). Undoes only what is unmistakably akinn's - its holds on the Kubernetes
# packages, its join files, its marks in fstab and the apt sources - then lists
# what it cannot know. The cluster is one of those: a node with no record may
# run one akinn never installed, so kubeadm reset (and Calico's files, plugins
# and rules with it) runs only when asked for with -k. Exits.
# Usage example:
# uninstall_unrecorded
uninstall_unrecorded() {
    local held f
    wrn "No install record in $AKINN_STATE: a best-effort cleanup (-f)."
    if [ -n "$RESET_K8S" ]; then
        reset_cluster
    fi
    held=$(apt-mark showhold 2>/dev/null | grep -xE 'kubelet|kubeadm|kubectl|kubectx')
    if [ -n "$held" ]; then
        # shellcheck disable=SC2086
        apt-mark unhold $held >/dev/null || uninstall_failed "apt-mark unhold failed for: $held"
    fi
    for f in "$MNJCRDFS/token" "$MNJCRDFS/hash"; do
        [ -e "$f" ] && rm -f "$f" && msg "Removed $f."
    done
    rmdir "$MNJCRDFS" 2>/dev/null
    # shellcheck disable=SC2086 # APT_SOURCES is a list of paths
    for f in "$FSTABF" $(grep -rlsF "$DOCKER_MARK" $APT_SOURCES 2>/dev/null); do
        if grep -qE "^($SWAP_MARK|$DOCKER_MARK)" "$f" 2>/dev/null; then
            sed -i -e "s/^$SWAP_MARK//" -e "s/^$DOCKER_MARK//" "$f" && msg "Took akinn's marks out of $f."
        fi
    done
    wrn "Not undone - without a record akinn cannot tell its changes from yours:"
    if [ -z "$RESET_K8S" ] && command -v kubeadm >/dev/null 2>&1; then
        wrn "  cluster:   this node's Kubernetes was left as it is. If akinn set it up: sudo sh akinn.sh -x -f -k"
        wrn "             (kubeadm reset, then Calico's CNI files, plugins and iptables rules)"
    fi
    wrn "  packages:  sudo apt-get purge kubelet kubeadm kubectl kubectx containerd.io   (if nothing else uses them)"
    for f in "$DOCKER_LIST" "$DOCKER_GPG" "$K_LIST" "$K_GPG" "$MODULES_CONF" "$SYSCTL_CONF" "$CCF" "$KBCTLCFG"; do
        [ -e "$f" ] && wrn "  file:      $f"
    done
    wrn "  swap:      older akinn commented the swap lines in $FSTABF with a bare '#': uncomment them, then sudo swapon -a"
    wrn "  hostname:  set by akinn to the node name; the one before it was not recorded"
    if [ "$UNINSTALL_FAILS" -ne 0 ]; then
        oerr "$UNINSTALL_FAILS step(s) failed (above)."
        exit 1
    fi
    exit 0
}
