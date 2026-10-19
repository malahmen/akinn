#!/bin/sh
# akinn's functions, driven one by one - no root, no network, nothing
# installed. The files are sourced as akinn.sh sources them; every command
# that would touch the system (kubeadm, apt-cache, ss, ip, ...) is a stub, and
# every system path points into a temporary folder.
#
# What it pins - the Ubuntu gaps fixed on 2026-10-15 (Kamino item 9):
#   - each run backs up into its own folder, and a rollback restores only what
#     that run touched (A1);
#   - the join token and hash are owner-only and validated before writing (A2);
#   - the port check is exact, the architecture validated, the default IP the
#     default route's;
#   - Docker's repository is a signed-by list, an older entry is retired;
#   - containerd's systemd cgroup switch is checked, against the real default
#     configs of containerd 1.7 and 2.4;
#   - kubectx is optional;
#   - a successful install keeps a record, and -x undoes exactly that: what it
#     created goes, what it replaced comes back, its marks leave shared files
#     (later edits stay), only the packages it installed are purged, only the
#     Kubernetes/Calico iptables rules dropped.
#
# A real install is not tested here: that needs a machine (see README).
# Run: sh tests/test-functions.sh   (dash on Ubuntu, as akinn itself runs)

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAILS=0

check() {
    desc="$1"; shift
    if "$@"; then echo "   ok   - $desc"; else echo "   FAIL - $desc"; FAILS=$((FAILS + 1)); fi
}
has() { grep -qF -- "$1" "$2"; }

# ---- stubs ---------------------------------------------------------------------
mkdir -p "$T/bin"
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
stub ip       'echo "1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.5 uid 0"'
stub hostname 'echo "172.17.0.1 10.0.0.5"'
stub ss       'echo "$*" >> "$STUB_LOG"; [ -n "$SS_BUSY" ] && printf "Netid State\ntcp LISTEN\n" || printf "Netid State\n"'
stub nc       'echo "succeeded"'
stub ping     'exit 0'
stub kubeadm  'echo "kubeadm $*" >> "$STUB_LOG"; case "$1" in token) printf "%s\n" "${KUBEADM_TOKEN:-abcdef.0123456789abcdef}" ;; join) exit "${KUBEADM_JOIN_RC:-0}" ;; esac'
stub apt-cache 'exit "${APT_CACHE_RC:-0}"'
stub apt-get  'echo "apt-get $*" >> "$STUB_LOG"'
stub dpkg-query 'exit 1'
export PATH="$T/bin:$PATH" STUB_LOG="$T/log"
: > "$STUB_LOG"

# ---- the files, as akinn.sh sources them ---------------------------------------------
SCRIPT_DIR="$ROOT"
for f in regex colors parameters constants variables errors functions protocols uninstall; do
    # shellcheck disable=SC1090
    . "$ROOT/$f.sh"
done
# Every system path into the sandbox.
mkdir -p "$T/etc/apt/sources.list.d" "$T/etc/apt/keyrings" "$T/home"
FSTABF="$T/etc/fstab"; CCF="$T/etc/config.toml"; MODULES_CONF="$T/etc/modules.conf"
DOCKER_GPG="$T/etc/apt/keyrings/docker.gpg"; DOCKER_LIST="$T/etc/apt/sources.list.d/docker.list"
APT_SOURCES="$T/etc/apt/sources.list $T/etc/apt/sources.list.d"; OS_RELEASE="$T/etc/os-release"
MNJCRDFS="$T/home/master_node"; K_CA="$T/ca.crt"
TMPDIR="$T"; export TMPDIR
SUDO_USER=""

# execution_error exits; run anything that may call it in a subshell.
fails() { ( "$@" ) > "$T/out" 2>&1; [ $? -ne 0 ]; }
succeeds() { ( "$@" ) > "$T/out" 2>&1; }

echo "## architecture"
arch_is() { ARCH=""; validate_architecture "$1" > /dev/null; [ "$ARCH" = "$2" ]; }
check "amd64 is accepted" arch_is amd64 amd64
check "arm64 is accepted" arch_is arm64 arm64
check "x86_64 becomes amd64" arch_is x86_64 amd64
check "aarch64 becomes arm64" arch_is aarch64 arm64
check "i386 is refused" fails validate_architecture i386
check "  with the reason" has "Unsupported architecture" "$T/out"

echo "## default IP"
check "the default route's source address, not hostname -I's first" [ "$IP" = 10.0.0.5 ]
stub ip 'exit 1'
ip_fallback() { ( . "$ROOT/parameters.sh"; [ "$IP" = 172.17.0.1 ] ); }
check "hostname -I only without a default route" ip_fallback

echo "## port check"
: > "$STUB_LOG"
succeeds poke_it 6443
check "asks ss for that exact port" has "sport = :6443" "$STUB_LOG"
check "  and reports it free" has "Local port 6443 is free" "$T/out"
SS_BUSY=1; export SS_BUSY
succeeds poke_it 6443
check "a listener on it reports busy" has "Local port 6443 is in use" "$T/out"
unset SS_BUSY

echo "## backups: one folder per run, and only its own changes undone (A1)"
printf 'original fstab\n' > "$FSTABF"
rm -f "$CCF"
run_and_fail() {
    start_run > /dev/null
    INSTALL_STARTED=1
    backup_file "$FSTABF" > /dev/null
    backup_file "$CCF" > /dev/null
    printf 'changed\n' > "$FSTABF"
    printf 'created\n' > "$CCF"
    echo "$RUN_DIR" > "$T/run_dir"
    execution_error "simulated failure"
}
fails run_and_fail
check "a failed run restores the file it changed" has "original fstab" "$FSTABF"
check "  removes the file it created" [ ! -e "$CCF" ]
check "  and leaves no folder behind" [ ! -d "$(cat "$T/run_dir")" ]
check "nothing is written to the old fixed /tmp paths" [ ! -e /tmp/backup.fstab ] || [ "$(cat /tmp/backup.fstab 2>/dev/null)" != "changed" ]

second_run() {
    # A first run that succeeded: its folder is gone. A second one that fails
    # before backing anything up must not "restore" anything.
    start_run > /dev/null; INSTALL_STARTED=1
    backup_file "$FSTABF" > /dev/null
    printf 'first run result\n' > "$FSTABF"
    finish_run
    start_run > /dev/null
    execution_error "fails before any backup"
}
fails second_run
check "a later run that fails early leaves the earlier run's result alone" has "first run result" "$FSTABF"

twice() {
    printf 'v0\n' > "$FSTABF"
    start_run > /dev/null; INSTALL_STARTED=1
    backup_file "$FSTABF" > /dev/null; printf 'v1\n' > "$FSTABF"
    backup_file "$FSTABF" > /dev/null; printf 'v2\n' > "$FSTABF"
    execution_error "x"
}
fails twice
check "a file backed up twice goes back to its state before the run" has "v0" "$FSTABF"

echo "## the join files (A2)"
SUDO_USER=""
token_ok() {
    start_run > /dev/null; mkdir -p "$MNJCRDFS"
    generate_join_token "$MNJCRDFS"
}
succeeds token_ok
check "a valid token is written" has "abcdef.0123456789abcdef" "$MNJCRDFS/token"
check "  readable by its owner only" [ "$(ls -l "$MNJCRDFS/token" | cut -c1-10)" = "-rw-------" ]
check "  and says when it expires" has "valid for 24 hours" "$T/out"
KUBEADM_TOKEN="not a token"; export KUBEADM_TOKEN
rm -f "$MNJCRDFS/token"
check "a malformed token is refused" fails token_ok
check "  and not written" [ ! -e "$MNJCRDFS/token" ]
unset KUBEADM_TOKEN

if command -v openssl > /dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/ca.key" -out "$K_CA" -days 1 -subj "/CN=kubernetes" > /dev/null 2>&1
    expected=$(openssl x509 -pubkey -in "$K_CA" | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')
    hash_ok() { start_run > /dev/null; mkdir -p "$MNJCRDFS"; generate_join_hash "$MNJCRDFS" > /dev/null; }
    succeeds hash_ok
    check "the hash matches kubeadm's documented RSA pipeline" [ "$(cat "$MNJCRDFS/hash")" = "$expected" ]
    check "  is 64 hex digits" grep -Eqx '[0-9a-f]{64}' "$MNJCRDFS/hash"
    check "  and is owner-only" [ "$(ls -l "$MNJCRDFS/hash" | cut -c1-10)" = "-rw-------" ]
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$T/ec.key" -out "$K_CA" -days 1 -subj "/CN=kubernetes" > /dev/null 2>&1
    rm -f "$MNJCRDFS/hash"
    check "an ECDSA CA works too (openssl pkey, not rsa)" succeeds hash_ok
    rm -f "$K_CA" "$MNJCRDFS/hash"
    check "a missing CA fails" fails hash_ok
    check "  without writing a hash" [ ! -e "$MNJCRDFS/hash" ]
else
    echo "   skip - openssl not found: the hash checks need it"
fi

KUBEADM_JOIN_RC=1; export KUBEADM_JOIN_RC
TOKEN=abcdef.0123456789abcdef; HASH=00; PORT=6443; IP=10.0.0.9
check "a failed join fails" fails join_master
check "  and names the likeliest cause, an expired token" has "lasts 24 hours" "$T/out"
unset KUBEADM_JOIN_RC

echo "## the caller's files: in their home, not root's"
# `sudo sh akinn.sh` resets HOME to /root on Ubuntu; the kubeconfig and join
# files went there, owned by the caller and out of their reach (found on the
# first real install, 2026-10-18).
stub getent 'case "$2" in alice) echo "alice:x:1000:1000::/home/alice:/bin/bash" ;; *) exit 2 ;; esac'
home_for() { ( HOME=/root SUDO_USER="$1"; . "$ROOT/variables.sh"; printf '%s|%s' "$KBCTLCFG" "$MNJCRDFS" ); }
check "under sudo, the caller's home" [ "$(home_for alice)" = "/home/alice/.kube/config|/home/alice/master_node" ]
check "run as root itself, root's" [ "$(home_for "")" = "/root/.kube/config|/root/master_node" ]
check "an unknown caller falls back to HOME" [ "$(home_for nobody-here)" = "/root/.kube/config|/root/master_node" ]
check "a quoted ~ is the caller's too" [ "$( CALLER_HOME=/home/alice; expand_path '~/token' )" = /home/alice/token ]
stub chown 'echo "chown $*" >> "$STUB_LOG"'
kube_dir_owned() {
    rm -rf "$T/alice"; mkdir -p "$T/alice"; printf 'admin\n' > "$T/admin.conf"
    SUDO_USER=alice; KBCTLCFG="$T/alice/.kube/config"; KBCTLOCFG="$T/admin.conf"; MASTER_NODE=m1
    start_run; INSTALL_STARTED=1; configure_kubectl
}
: > "$STUB_LOG"
succeeds kube_dir_owned
check "a .kube it creates is given to the caller" has "chown alice: $T/alice/.kube" "$STUB_LOG"
check "  and so is the config" has "chown alice $T/alice/.kube/config" "$STUB_LOG"
rm -f "$T/bin/chown"
stub kubectl 'echo "kubectl $*" >> "$STUB_LOG"'
stub curl 'exit 0'
: > "$STUB_LOG"
succeeds download_and_apply https://example.invalid/calico.yaml "$T/crds.yaml"
check "Calico is applied with admin.conf, not root's HOME" has "kubectl --kubeconfig $KBCTLOCFG apply" "$STUB_LOG"
rm -f "$T/bin/kubectl" "$T/bin/curl" "$T/bin/getent"
stub sshpass 'echo "sshpass $*" >> "$STUB_LOG"; exit 0'
worker_copy() {
    rm -rf "$T/bob"; mkdir -p "$T/bob"
    SUDO_USER=""; MASTER_NODE=""; MASTER_USER=ubuntu; IP=10.0.0.9; MASTER_LOGIN="$T/login"
    KBCTLCFG="$T/bob/.kube/config"; start_run; INSTALL_STARTED=1; configure_kubectl
}
: > "$STUB_LOG"
succeeds worker_copy
check "a worker copies the master user's kubeconfig" has "ubuntu@10.0.0.9:.kube/config $T/bob/.kube/config" "$STUB_LOG"
check "  not root's admin.conf, which that user cannot read" sh -c '! grep -q "admin.conf" "$1"' _ "$STUB_LOG"
rm -f "$T/bin/sshpass"; MASTER_USER=""

echo "## Docker's repository"
printf 'NAME="Ubuntu"\nVERSION_CODENAME=noble\n' > "$OS_RELEASE"
printf 'deb http://archive.ubuntu.com/ubuntu noble main\ndeb [arch=arm64] https://download.docker.com/linux/ubuntu noble stable\n' > "$T/etc/apt/sources.list"
docker_repo() { start_run > /dev/null; ARCH=arm64; add_docker_repository > /dev/null; }
succeeds docker_repo
check "a signed-by list of its own" has "deb [arch=arm64 signed-by=$DOCKER_GPG] https://download.docker.com/linux/ubuntu noble stable" "$DOCKER_LIST"
check "an older add-apt-repository entry is commented out" has "# moved to docker.list by akinn: deb [arch=arm64] https://download.docker.com" "$T/etc/apt/sources.list"
check "  and the rest of that file is untouched" has "deb http://archive.ubuntu.com/ubuntu noble main" "$T/etc/apt/sources.list"
docker_repo_fails() { docker_repo; INSTALL_STARTED=1; execution_error "x"; }
printf 'deb http://archive.ubuntu.com/ubuntu noble main\ndeb [arch=arm64] https://download.docker.com/linux/ubuntu noble stable\n' > "$T/etc/apt/sources.list"
rm -f "$DOCKER_LIST"
fails docker_repo_fails
check "a rollback brings the older entry back" grep -qx "deb \[arch=arm64\] https://download.docker.com/linux/ubuntu noble stable" "$T/etc/apt/sources.list"
check "  and removes the list it created" [ ! -e "$DOCKER_LIST" ]

echo "## containerd's systemd cgroup"
for v in 1.7 2.4; do
    cp "$TEST_DIR/fixtures/containerd-$v.toml" "$CCF"
    check "containerd $v: switched on" succeeds enable_systemd_cgroup "$CCF"
    check "  in its runc options" has "SystemdCgroup = true" "$CCF"
done
printf '[plugins]\n' > "$CCF"
check "a config without the setting fails loudly" fails enable_systemd_cgroup "$CCF"
check "  and says so" has "no 'SystemdCgroup = false' to enable" "$T/out"

echo "## kubectx"
APT_CACHE_RC=0; export APT_CACHE_RC
check "packaged (24.04): installed and held" [ "$(install_kubectx_if_packaged 2>/dev/null)" = kubectx ]
APT_CACHE_RC=100
check "not packaged (20.04, 22.04): skipped, nothing to hold" [ -z "$(install_kubectx_if_packaged 2>"$T/out")" ]
check "  with a word about it" has "not packaged for this Ubuntu release" "$T/out"

echo "## rollback of a folder the run created"
dir_run() {
    start_run > /dev/null; INSTALL_STARTED=1
    backup_file "$T/newdir" dir > /dev/null; mkdir "$T/newdir"
    backup_file "$T/newdir/f" > /dev/null; : > "$T/newdir/f"
    execution_error "x"
}
fails dir_run
check "a failed run removes the folder it created, with its files" [ ! -e "$T/newdir" ]

echo "## -x and -f"
OPTIND=1; read_parameters -x -f -k
check "-x asks for an uninstall, -f forces it, -k adds the cluster reset" [ "$UNINSTALL" = 1 -a "$FORCE" = 1 -a "$RESET_K8S" = 1 ]
UNINSTALL=""; FORCE=""; RESET_K8S=""

echo "## the install record, and -x"
AKINN_STATE="$T/var/lib/akinn"; SYSCTL_CONF="$T/etc/sysctl.conf"
CNI_CONF="$T/etc/cni/net.d"; CALICO_STATE="$T/var/lib/calico"
K_LIST="$T/etc/apt/sources.list.d/kubernetes.list"; K_GPG="$T/etc/apt/keyrings/k.gpg"
stub dpkg-query 'case " $DPKG_INSTALLED " in *" $3 "*) echo "install ok installed" ;; *) exit 1 ;; esac'
stub apt-get 'echo "apt-get $*" >> "$STUB_LOG"; [ "$1" = -s ] && { [ "$2" = autoremove ] && printf "%s\n" "$APT_AUTO" || printf "%s\n" "$APT_SIM"; }; exit 0'
stub apt-mark 'echo "apt-mark $*" >> "$STUB_LOG"; [ "$1" = showhold ] && printf "%s\n" $APT_HELD; exit 0'
stub hostnamectl 'echo "hostnamectl $*" >> "$STUB_LOG"; exit "${HOSTNAMECTL_RC:-0}"'
for c in swapoff swapon sysctl; do stub "$c" "echo \"$c \$*\" >> \"\$STUB_LOG\""; done
stub iptables-save 'cat "$IPT_RULES"'
stub iptables-restore 'cat > "$IPT_RULES.restored"'
stub ip6tables-save 'exit 1'
DPKG_INSTALLED="kubeadm"; APT_HELD="kubeadm"; APT_SIM="Purg kubelet [1.34.1-1.1]"
IPT_RULES="$T/rules"
# what apt calls orphans once kubelet is gone: its CNI plugins, and one that is
# nothing to do with akinn and must stay
APT_AUTO=$(printf 'Remv kubernetes-cni [1.7.1-1.1]\nRemv libunrelated1 [2.0]')
export DPKG_INSTALLED APT_HELD APT_SIM APT_AUTO IPT_RULES
KUBEADM_DIRS="$T/etc/kubernetes/pki $T/etc/kubernetes $T/var/lib/etcd $T/var/lib/kept"
CNI_BIN="$T/opt/cni/bin"; mkdir -p "$CNI_BIN"; for f in calico calico-ipam flannel bridge; do : > "$CNI_BIN/$f"; done
mkdir -p "$T/etc/kubernetes/pki" "$T/var/lib/etcd" "$T/var/lib/kept"; : > "$T/var/lib/kept/data"

printf 'UUID=a / ext4 defaults 0 1\n/swap.img none swap sw 0 0\n#/old.img none swap sw 0 0\n' > "$FSTABF"
printf 'deb http://archive.ubuntu.com/ubuntu noble main\ndeb [arch=amd64] https://download.docker.com/linux/ubuntu noble stable\n' > "$T/etc/apt/sources.list"
printf 'old modules\n' > "$MODULES_CONF"
rm -f "$SYSCTL_CONF" "$DOCKER_LIST"; rm -rf "$T/home" "$MNJCRDFS"; mkdir -p "$T/home" "$T/work"
printf 'admin\n' > "$T/admin.conf"
command -v openssl > /dev/null 2>&1 && openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/ca.key" -out "$K_CA" -days 1 -subj "/CN=kubernetes" > /dev/null 2>&1
fake_install() {
    HOME="$T/home"; KBCTLCFG="$HOME/.kube/config"; KBCTLOCFG="$T/admin.conf"; MASTER_NODE=m1
    start_run; INSTALL_STARTED=1
    disable_swap
    retire_old_docker_sources
    backup_file "$DOCKER_LIST"; printf 'deb new\n' > "$DOCKER_LIST"
    backup_file "$MODULES_CONF"; printf 'overlay\n' > "$MODULES_CONF"
    backup_file "$SYSCTL_CONF"; printf 'net.ipv4.ip_forward = 1\n' > "$SYSCTL_CONF"
    install_package kubelet; install_package kubeadm; install_package curl
    hold_packages kubelet kubeadm
    set_node_hostname m1
    configure_kubectl
    cd "$T/work" && backup_file "$(pwd)/crds.yaml" && printf 'calico\n' > crds.yaml
    command -v openssl > /dev/null 2>&1 && generate_join_credentials
    KUBEADM_RAN=1
    save_run
}
: > "$STUB_LOG"
succeeds fake_install
check "the install succeeds" [ $? -eq 0 ]
REC=$(ls -d "$AKINN_STATE"/runs/0001-* 2>/dev/null)
check "it keeps a record" [ -f "$REC/manifest" ]
check "  that only root reads" [ "$(ls -ld "$AKINN_STATE" | cut -c1-10)" = "drwx------" ]
check "  and says how to undo it" has "akinn.sh -x" "$T/out"
check "the swap line is commented with akinn's mark" grep -qx "# akinn: /swap.img none swap sw 0 0" "$FSTABF"
check "  an already commented one is left alone" grep -qx "#/old.img none swap sw 0 0" "$FSTABF"
check "the packages it installed are recorded, not the one already there" [ "$(cat "$REC/packages")" = "kubelet
curl" ]
check "  so are the ones it held, not the one already held" [ "$(cat "$REC/held")" = kubelet ]
check "  and the hostname before" [ "$(cat "$REC/hostname")" = "$(uname -n)" ]
check "  and that it ran kubeadm" [ -e "$REC/kubeadm" ]
check "the downloads are not kept" [ ! -e "$REC/docker.gpg" ]

# What happens between the install and the uninstall: the admin edits the
# shared files, the cluster leaves its traces.
printf 'UUID=b /data ext4 defaults 0 2\n' >> "$FSTABF"
printf 'deb http://example.com/extra stable main\n' >> "$T/etc/apt/sources.list"
mkdir -p "$CNI_CONF" "$CALICO_STATE"
: > "$CNI_CONF/10-calico.conflist"; : > "$CNI_CONF/calico-kubeconfig"; : > "$CNI_CONF/87-podman-bridge.conflist"
cat > "$IPT_RULES" <<'RULES'
*filter
:INPUT ACCEPT [0:0]
:KUBE-FORWARD - [0:0]
:cali-FORWARD - [0:0]
:DOCKER - [0:0]
-A FORWARD -m comment --comment "kubernetes forwarding rules" -j KUBE-FORWARD
-A FORWARD -m comment --comment "cali:wUHhoiAYhphO9Mso" -j cali-FORWARD
-A FORWARD -o docker0 -j DOCKER
COMMIT
RULES
before=$(uname -n)
: > "$STUB_LOG"
succeeds uninstall
check "-x succeeds" [ $? -eq 0 ]
check "  resets the cluster" has "kubeadm reset -f" "$STUB_LOG"
check "  removes Calico's CNI files" [ ! -e "$CNI_CONF/10-calico.conflist" -a ! -e "$CNI_CONF/calico-kubeconfig" -a ! -e "$CALICO_STATE" ]
check "  but not another tool's" [ -e "$CNI_CONF/87-podman-bridge.conflist" ]
check "  drops the KUBE-* and cali- rules" sh -c '! grep -qE "KUBE-|cali" "$1"' _ "$IPT_RULES.restored"
check "  keeps every other rule" has "-A FORWARD -o docker0 -j DOCKER" "$IPT_RULES.restored"
check "  unholds what it held" grep -qx "apt-mark unhold kubelet" "$STUB_LOG"
check "  purges what it installed" grep -qx "apt-get purge -y kubelet" "$STUB_LOG"
check "  not the package that was already there" sh -c '! grep -q "purge.*kubeadm" "$1"' _ "$STUB_LOG"
check "  then what apt pulled in for it, now orphaned" grep -qx "apt-get purge -y kubernetes-cni" "$STUB_LOG"
check "  but no other orphan" sh -c '! grep -q "purge.*libunrelated1" "$1"' _ "$STUB_LOG"
check "  never a blanket autoremove" sh -c '! grep -qx "apt-get.* autoremove -y.*" "$1"' _ "$STUB_LOG"
check "the folders kubeadm reset left empty are gone" [ ! -e "$T/etc/kubernetes" -a ! -e "$T/var/lib/etcd" ]
check "  one that is not empty stays" [ -e "$T/var/lib/kept/data" ]
check "Calico's CNI plugins are removed" [ ! -e "$CNI_BIN/calico" -a ! -e "$CNI_BIN/calico-ipam" -a ! -e "$CNI_BIN/flannel" ]
check "  another plugin stays, and so does its folder" [ -e "$CNI_BIN/bridge" ]
check "  leaves curl, saying so" has "Left installed (akinn installed them, but other software may use them now): curl" "$T/out"
check "the swap line is back" grep -qx "/swap.img none swap sw 0 0" "$FSTABF"
check "  the one commented before stays commented" grep -qx "#/old.img none swap sw 0 0" "$FSTABF"
check "  the admin's later fstab line stays" grep -qx "UUID=b /data ext4 defaults 0 2" "$FSTABF"
check "  and swap is turned back on" has "swapon -a" "$STUB_LOG"
check "the older Docker entry is back" grep -qx "deb \[arch=amd64\] https://download.docker.com/linux/ubuntu noble stable" "$T/etc/apt/sources.list"
check "  the admin's later source stays" has "deb http://example.com/extra stable main" "$T/etc/apt/sources.list"
check "a file it replaced is restored" grep -qx "old modules" "$MODULES_CONF"
check "files it created are removed" [ ! -e "$SYSCTL_CONF" -a ! -e "$DOCKER_LIST" -a ! -e "$T/work/crds.yaml" ]
check "  the kubeconfig and the .kube it created too" [ ! -e "$T/home/.kube" ]
if command -v openssl > /dev/null 2>&1; then
    check "  and the join files with their folder" [ ! -e "$MNJCRDFS" ]
fi
check "the hostname is put back" has "hostnamectl set-hostname $before" "$STUB_LOG"
first_line() { grep -nF -- "$1" "$T/out" | head -1 | cut -d: -f1; }
check "files are undone before packages are purged" [ "$(first_line "Restored $MODULES_CONF")" -lt "$(first_line "Removing the packages")" ]
check "the record goes once everything is undone" [ ! -e "$AKINN_STATE" ]

echo "## -x: two installs, a failed step, a purge that would take more"
two_runs() {
    printf 'v0\n' > "$MODULES_CONF"
    start_run > /dev/null; backup_file "$MODULES_CONF" > /dev/null; printf 'v1\n' > "$MODULES_CONF"; save_run > /dev/null
    start_run > /dev/null; backup_file "$MODULES_CONF" > /dev/null; printf 'v2\n' > "$MODULES_CONF"; set_node_hostname m2; save_run > /dev/null
}
succeeds two_runs
check "two installs, two records" [ "$(ls "$AKINN_STATE/runs" | wc -l)" -eq 2 ]
# Each install records the name it found; -x puts back the first one's.
printf 'm0\n' > "$(ls -d "$AKINN_STATE"/runs/0001-*)/hostname"
printf 'm1\n' > "$(ls -d "$AKINN_STATE"/runs/0002-*)/hostname"
HOSTNAMECTL_RC=1; export HOSTNAMECTL_RC
check "a failed step fails -x" fails uninstall
check "  which keeps the record, to run again" [ -d "$AKINN_STATE/runs" ]
check "  and says so" has "The record stays" "$T/out"
unset HOSTNAMECTL_RC
: > "$STUB_LOG"
succeeds uninstall
check "run again, it goes back to the state before the first install" grep -qx v0 "$MODULES_CONF"
check "  and to the hostname before it" grep -qx "hostnamectl set-hostname m0" "$STUB_LOG"
APT_SIM=$(printf 'Purg containerd.io [2.1]\nRemv docker-ce [28.0]')
: > "$STUB_LOG"
succeeds purge_packages containerd.io
check "a purge that would remove docker-ce does not run" sh -c '! grep -q "purge -y" "$1"' _ "$STUB_LOG"
check "  and names it" has "also remove docker-ce" "$T/out"

echo "## -x without a record"
check "is refused" fails uninstall
check "  pointing to -f" has "akinn.sh -x -f" "$T/out"
printf '# akinn: /swap.img none swap sw 0 0\n#/old.img none swap sw 0 0\n' > "$FSTABF"
mkdir -p "$MNJCRDFS"; : > "$MNJCRDFS/token"; : > "$MNJCRDFS/hash"
FORCE=1; APT_HELD="kubelet kubeadm vim"
: > "$STUB_LOG"
mkdir -p "$CNI_CONF" "$CNI_BIN"; : > "$CNI_CONF/10-calico.conflist"; : > "$CNI_BIN/flannel"
succeeds uninstall
check "-f succeeds" [ $? -eq 0 ]
# No record, so nothing says this node's cluster is akinn's: left alone (item 98).
check "  leaves the cluster alone: no kubeadm reset" sh -c '! grep -q "kubeadm reset" "$1"' _ "$STUB_LOG"
check "  nor Calico's CNI configuration" [ -e "$CNI_CONF/10-calico.conflist" ]
check "  nor the CNI plugins" [ -e "$CNI_BIN/flannel" ]
check "  and says how to reset it if akinn set it up" has "akinn.sh -x -f -k" "$T/out"
check "  removes the join files" [ ! -e "$MNJCRDFS" ]
check "  takes its marks out of fstab" grep -qx "/swap.img none swap sw 0 0" "$FSTABF"
check "  unholds only the Kubernetes packages" grep -qx "apt-mark unhold kubelet kubeadm" "$STUB_LOG"
check "  purges nothing" sh -c '! grep -q purge "$1"' _ "$STUB_LOG"
check "  and lists what it could not know" has "sudo apt-get purge kubelet" "$T/out"
RESET_K8S=1
: > "$STUB_LOG"
succeeds uninstall
check "-f -k resets the cluster" has "kubeadm reset -f" "$STUB_LOG"
check "  with Calico's CNI configuration" [ ! -e "$CNI_CONF/10-calico.conflist" ]
check "  and plugins" [ ! -e "$CNI_BIN/flannel" ]
check "  and no longer offers -k" sh -c '! grep -q -- "-x -f -k" "$1"' _ "$T/out"
FORCE=""; RESET_K8S=""

echo
if [ "$FAILS" -ne 0 ]; then echo "$FAILS check(s) failed"; exit 1; fi
echo "all checks passed"
