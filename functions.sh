# Function: prints a help message.
# Usage example:
# display_usage
display_usage() {
    cat << EOF 1>&2
  Usage: $0 [options]
  Options:
    -m MASTER_NODE   Set the master node name
    -w WORKER_NODE   Set the worker node name
    -l LOGIN         Set the master node login password
    -v VERSION       Set the Kubernetes version
    -c CRDS          Set the Kubernetes Custom Resources Definitions version
    -n CIDR          Set the Classless Inter-Domain Routing blocks for Kubernetes pods
    -i IP            Worker: the master node IP to join. Master: advertise address (defaults to the node's first IP)
    -p PORT          Set the master node port number for the worker
    -t TOKEN         Set the token for the worker to join the master
    -h HASH          Set the hash for the worker to join the master
    -a ARCH          Set the architecture
    -u MASTER_USER   SSH user on the master node (worker uses it to copy kubeconfig; defaults to \$SUDO_USER)
    -x               Uninstall: undo what akinn's installs changed on this node (recorded in $AKINN_STATE)
    -f               With -x, on a node installed before akinn kept a record: a best-effort cleanup
EOF
}

# Function: prints message in green.
# Usage example:
# msg "some message"
msg(){
    local message="$1"
    if [ -n "$message" ]; then
        printf '%b %s%b\n' "$GREEN" "$message" "$NC"
    fi
}

# Function: prints error message in yellow.
# Usage example:
# wrn "some message"
wrn(){
    local message="$1"
    if [ -n "$message" ]; then
        printf '%b %s%b\n' "$YELLOW" "$message" "$NC"
    fi
}

# Function: prints error message in red.
# Usage example:
# oerr "some message"
oerr(){
    local message="$1"
    if [ -n "$message" ]; then
        printf '%b Error: %s%b\n' "$RED" "$message" "$NC"
    fi
}

# Function: expand a leading ~ to $HOME without eval.
# Using `eval` on a user-supplied path would let values like '$(reboot)' run as
# root; this expands only a leading tilde and returns everything else verbatim.
# Usage example:
# path=$(expand_path "$input")
expand_path() {
    case "$1" in
        "~")   printf '%s\n' "$HOME" ;;
        "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
        *)     printf '%s\n' "$1" ;;
    esac
}

# Function: remember a file's state before this run changes it.
# The copy goes into this run's folder and the change is recorded in its
# manifest, so a rollback restores exactly what THIS run touched - never an
# older run's leftovers. A file that does not exist yet is recorded too: if
# this run creates it, the rollback removes it.
# Usage example:
# backup_file "$origin"
backup_file() {
    local origin="$1"
    local kind="$2" # "edit": akinn only marks lines in it; "dir": a folder akinn may create
    local n
    if [ "$kind" = "dir" ]; then
        # Only a folder this run creates is recorded: one that was there stays.
        [ -d "$origin" ] || printf '%s\t%s\t%s\n' "-" "$origin" "dir" >> "$RUN_DIR/manifest"
    elif [ -f "$origin" ]; then
        n=$(( $(wc -l < "$RUN_DIR/manifest") + 1 ))
        if ! cp -p "$origin" "$RUN_DIR/backup.$n"; then
            wrn "failed to backup $origin."
            return
        fi
        printf '%s\t%s\t%s\n' "backup.$n" "$origin" "$kind" >> "$RUN_DIR/manifest"
        msg "$origin backed up."
    else
        printf '%s\t%s\t%s\n' "-" "$origin" "$kind" >> "$RUN_DIR/manifest"
        msg "$origin does not exist yet; a rollback removes it if this run creates it."
    fi
}

# Function: create this run's working folder (backups, manifest, downloads).
# Usage example:
# start_run
start_run() {
    RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/akinn.XXXXXX") || execution_error "$ERR_FRD"
    chmod 700 "$RUN_DIR" || execution_error "$ERR_FRD"
    : > "$RUN_DIR/manifest"
    DOCKER_GPG_TMP="$RUN_DIR/docker.gpg"
    K_GPG_TMP="$RUN_DIR/kubernetes.gpg"
    msg "Working folder for this run: $RUN_DIR"
}

# Function: a successful run keeps no backups behind.
# Usage example:
# finish_run
finish_run() {
    if [ -n "$RUN_DIR" ]; then
        rm -rf "$RUN_DIR"
    fi
}

# Function: keep a successful run's folder as its install record, for -x:
# the manifest and the originals, the packages it installed and held, the
# hostname before, whether it ran kubeadm. Numbered, so -x goes newest first.
# Usage example:
# save_run
save_run() {
    local n dest
    [ -n "$RUN_DIR" ] || return 0
    [ -n "$KUBEADM_RAN" ] && : > "$RUN_DIR/kubeadm"
    rm -f "$DOCKER_GPG_TMP" "$K_GPG_TMP"
    if mkdir -p "$AKINN_STATE/runs" && chmod 700 "$AKINN_STATE"; then
        n=$(( $(ls -1 "$AKINN_STATE/runs" | wc -l) + 1 ))
        dest="$AKINN_STATE/runs/$(printf '%04d' "$n")-$(date -u +%Y%m%dT%H%M%SZ)"
        if mv "$RUN_DIR" "$dest"; then
            RUN_DIR=""
            msg "What this install changed is recorded in $dest: 'sudo sh akinn.sh -x' undoes it."
            return 0
        fi
    fi
    wrn "Could not keep the install record in $AKINN_STATE: -x will only be able to clean up with -f."
    finish_run
}

# Function: updates destiny file with source file.
# Source file is deleted on success.
# Breaks execution on failure.
# Usage example:
# update_file "$source" "$destiny"
update_file() {
    local source="$1"
    local destiny="$2"
    if [ -f "$source" ]; then
        msg "$source exists, updating $destiny."
        if ! mv "$source" "$destiny"; then
            oerr "failed to update $destiny."
            exit 1
        else
            msg "$destiny updated."
        fi
    else
        oerr "$source not found, failed to update."
        exit 1
    fi
}

# Function: disable swap and backup fstab
# Usage example:
# disable_swap
disable_swap() {
    backup_file "$FSTABF" edit
    execute swapoff -a
    # Marked, and only lines not already commented: -x uncomments exactly
    # these, whatever else was edited in fstab since.
    execute sed -i "/^[[:space:]]*#/!{/[[:space:]]swap[[:space:]]/s/^/$SWAP_MARK/}" "$FSTABF"
}

# Function: undo this run's file changes, newest first, from its manifest.
# Usage example:
# rollback_files
rollback_files(){
    # Only undo a kubeadm init/join this run performed; never reset a pre-existing cluster.
    if [ -n "$KUBEADM_RAN" ]; then
        # POSIX redirect: under dash "&>" backgrounds the command and the test is always true.
        if command -v kubeadm >/dev/null 2>&1; then
            wrn "Reseting kubeadm."
            kubeadm reset -f
        fi
    fi
    if [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/manifest" ]; then
        local tab
        tab=$(printf '\t')
        # Newest first, so a file backed up twice ends at its oldest state.
        sed -n '1!G;h;$p' "$RUN_DIR/manifest" | while IFS="$tab" read -r saved origin kind; do
            if [ "$kind" = "dir" ]; then
                rmdir "$origin" 2>/dev/null && wrn "Removed $origin (created by this run)."
            elif [ "$saved" = "-" ]; then
                if [ -e "$origin" ]; then
                    rm -f "$origin" && wrn "Removed $origin (created by this run)."
                fi
            elif mv "$RUN_DIR/$saved" "$origin"; then
                wrn "$origin reverted."
            else
                wrn "failed to revert $origin."
            fi
        done
    fi
    finish_run
    if [ -n "$KBCTLCFG_CREATED" ]; then
        rm -f "$KBCTLCFG" # only the kubeconfig this run wrote; keep any pre-existing ~/.kube
    fi
}

# Function: exits with message.
# Usage example:
# trap execution_error ERR
# execution_error "$ERR"
execution_error() {
    # Validation-phase failures (bad flag, unknown version, ...) changed nothing: nothing to undo.
    if [ -n "$INSTALL_STARTED" ]; then
        rollback_files
    fi
    local err_code="$1"
    if [ -n "$err_code" ]; then
        oerr "$err_code"
    fi
    oerr "$ERR_SE"
    exit 1
}

# Function: exits with help message.
# Usage example:
# parameter_missing_error $ERR
parameter_missing_error() {
    local err_message=$1
    if [ -n "$err_message" ]; then
        wrn "$err_message"
    fi
    display_usage
    exit 1
}

# Function: loads available versions of Kubernetes and CRDs from their respective repositories.
# It fetches the versions by scraping GitHub release pages and stores them in K_VERSIONS and CRDS_VERSIONS.
# Usage example:
# load_versions
load_versions() {
    # Fetch first, parse after: inside 'curl | grep | ...' only the last command's
    # status is visible, so a failed download used to yield an empty list and a
    # misleading "invalid version" error instead of a fetch error.
    local page
    msg "Loading CRDs versions."
    page=$(curl -fsSL "$CRDS_RELEASES") || execution_error "$ERR_FFCRDVER"
    CRDS_VERSIONS=$(printf '%s\n' "$page" | grep -Eo "$re_crds_ver" | sed 's/release-//' | sort | uniq)
    if [ -z "$CRDS_VERSIONS" ]; then
        execution_error "$ERR_FFCRDVER"
    fi
    msg "CRDs versions loaded."
    msg "Loading Kubernetes versions."
    # GitHub's releases page lists bare patch tags (v1.34.2). The k8s apt repo
    # (pkgs.k8s.io/.../stable:/v1.34/deb/) and the VERSION input are keyed on the
    # MINOR version, so collapse patch tags to minors for validation.
    page=$(curl -fsSL "$K_RELEASES") || execution_error "$ERR_FFKVER"
    K_VERSIONS=$(printf '%s\n' "$page" | grep -Eo "$re_kver" | sed -E 's/(v[0-9]+\.[0-9]+)\.[0-9]+/\1/' | sort | uniq)
    if [ -z "$K_VERSIONS" ]; then
        execution_error "$ERR_FFKVER"
    fi
    msg "Kubernetes versions loaded."
}

# Function: validates the architecture: the apt lines are built from it.
# Debian's names are accepted, and the kernel's (uname -m) mapped onto them.
# Usage example:
# validate_architecture "$ARCH"
validate_architecture() {
    case "$1" in
        "")          parameter_missing_error "$ERR_ANS" ;;
        amd64|arm64) ARCH="$1" ;;
        x86_64)      ARCH=amd64; wrn "Architecture x86_64 is amd64 to apt; using amd64." ;;
        aarch64)     ARCH=arm64; wrn "Architecture aarch64 is arm64 to apt; using arm64." ;;
        *)           execution_error "$ERR_UARCH" ;;
    esac
}

# Function: checks if a node name is given
# Usage example:
# validate_hostname
validate_hostname() {
    # master > worker
    if [ -n "$MASTER_NODE" ]; then
        NODE_NAME=${MASTER_NODE}
        WORKER_NODE="" # enforce Master
    elif [ -n "$WORKER_NODE" ]; then
        NODE_NAME=${WORKER_NODE}
    else
        parameter_missing_error "$ERR_HNNS"
    fi
}

# Function: checks if an IP address is valid.
# Usage example:
# validate_ip_address "$IP"
validate_ip_address() {
    local ip=$1
    msg "Checking IP exists..."
    if [ -z "$ip" ]; then
        parameter_missing_error "$ERR_IPNS"
    fi
    msg "IP exists: $ip"
    msg "Validating IP: $ip"
    if ! echo "$ip" | grep -qE "$re_ip"; then
        execution_error "$ERR_IIP"
    fi
    msg "IP: $ip - valid."
    ping_it "$ip"
}

# Function: checks if an IP address is reachable.
# Usage example:
# ping_it "$ip"
ping_it() {
    local address="$1"
    msg "Checking if $address is reachable."
    if ! ping -c 1 "$address" > /dev/null 2>&1; then
        execution_error "$ERR_UNRIP"
    fi
    msg "IP: $address - reachable."
}

# Function: checks if a port in a IP address is free.
# Also checks the local machine port.
# Usage example:
# poke_it "$port"
poke_it() {
    local this_port="$1"
    # poke worker node port: ss's own filter is an exact port match - grepping
    # ":$port" also matched 64430 when asked about 6443.
    if [ -n "$(ss -tuln "sport = :$this_port" 2>/dev/null | tail -n +2)" ]; then
        wrn "Local port $this_port is in use."
    else
        msg "Local port $this_port is free."
        #msg "Opening local port: $port."
        #ufw allow $port/tcp
    fi
    # poke master node port
    if [ -n "$IP" ]; then
        if nc -zv $IP $this_port 2>&1 | grep -q succeeded; then
            msg "Port $this_port is open on $IP"
        else
            execution_error "$ERR_MNPC"
        fi
    fi
}

# Function: checks common ports are free.
# Also checks the master node if IP is present.
# Usage example:
# poke_defaults
poke_defaults() {
    # List of usual ports to check
    DEFAULT_PORTS="6443 2379 2380 10250 10251 10252 10255"
    for port in $DEFAULT_PORTS; do
        poke_it "$port"
    done
}

# Function: checks if an port number is valid.
# Usage example:
# validate_port "$PORT"
validate_port() {
    local port=$1
    if [ -z "$port" ]; then
        parameter_missing_error "$ERR_PRTNS"
    fi
    if ! echo "$port" | grep -qE "$re_port"; then
        execution_error "$ERR_IPRT"
    fi
}

# Function: validates the token input.
# Also reads the token value from its file.
# Usage example:
# validate_token "$TOKEN"
validate_token() {
    local token_file=$1
    if [ -z "$token_file" ]; then
        parameter_missing_error "$ERR_TFNS"
    fi
    local token_file_path=$(expand_path "$token_file")
    msg "Looking for the token file: $token_file_path"
    if [ ! -f "$token_file_path" ]; then
        execution_error "$ERR_TFNE"
    fi
    msg "Token file exists. Reading it."
    TOKEN=$(cat "$token_file_path")
    msg "Token file read."
}

# Function: validates the hash input.
# Also reads the hash value from its file.
# Usage example:
# validate_hash "$HASH"
validate_hash() {
    local hash_file=$1
    if [ -z "$hash_file" ]; then
        parameter_missing_error "$ERR_HFNS"
    fi
    local hash_file_path=$(expand_path "$hash_file")
    msg "Looking for the hash file: $hash_file_path"
    if [ ! -f "$hash_file_path" ]; then
        execution_error "$ERR_HFNE"
    fi
    msg "Hash file exists. Reading it."
    HASH=$(cat "$hash_file_path")
    msg "Hash file read."
}

# Function: validates the login password input.
# Also reads the password value from its file.
# Usage example:
# validate_remote_password "$MASTER_LOGIN"
validate_remote_password() {
    local password_file=$1
    if [ -z "$password_file" ]; then
        parameter_missing_error "$ERR_PFNS"
    fi
    local password_file_path=$(expand_path "$password_file")
    msg "Looking for the Master node password file: $password_file_path"
    if [ ! -f "$password_file_path" ]; then
        execution_error "$ERR_PFNE"
    fi
    msg "Password file exists. Using it."
    MASTER_LOGIN=$password_file_path
    msg "Password file done."
}

# Function: Validate Kubernetes and CRDs versions against existing ones.
# Usage example:
# validate_version "$VERSION" "kubernetes"
# validate_version "$CRDS" "crds"
validate_version() {
    local version=$1
    local type=$2  # 'kubernetes' or 'crds'
    local versions=""
    if [ "$type" = "kubernetes" ]; then
        versions=$K_VERSIONS
    elif [ "$type" = "crds" ]; then
        versions=$CRDS_VERSIONS
    fi
    # Whole-line, literal match: a substring match let '-v 1' pass and build a bogus repo URL.
    if ! echo "$versions" | grep -qxF -- "$version"; then
        execution_error "$ERR_IUV"
    fi
}

# Function: Validate Kubernetes version input.
# Usage example:
# validate_kubernetes_version "$VERSION"
validate_kubernetes_version() {
    local version=$1
    if [ -z "$version" ]; then
        parameter_missing_error "$ERR_KVERNS"
    fi
    validate_version "$version" "kubernetes"
}

# Function: Validate Kubernetes crds version input.
# Usage example:
# validate_crds_version "$CRDS"
validate_crds_version() {
    local version=$1
    if [ -z "$version" ]; then
        parameter_missing_error "$ERR_CDRVERNS"
    fi
    validate_version "$version" "crds"
}

# Function: Validate CIDR block.
# Usage example:
# validate_cidr_block "$CIDR"
validate_cidr_block() {
    local cidr=$1
    if [ -z "$cidr" ]; then
        parameter_missing_error "$ERR_CIDRNS"
    fi
    if ! echo "$cidr" | grep -qE "$re_cidr"; then
        execution_error "$ERR_ICIDR"
    fi
}

# Function: execute commands with enhanced error handling.
# Usage example:
# execute apt update
# execute apt install -y kubelet kubeadm kubectl kubectx
execute() {
    "$@"
    local status=$?
    if [ $status -ne 0 ]; then
        execution_error " Error: Failed executing - '$*'"
    fi
}

# Function: execute commands with error handling (no vars printed).
# Usage example:
# execute_sensitive apt update
# execute_sensitive apt install -y kubelet kubeadm kubectl kubectx
execute_sensitive() {
    "$@"
    local status=$?
    if [ $status -ne 0 ]; then
        execution_error "$ERR_FEC"
    fi
}

# Function: execute commands ignoring resulting errors.
# Usage example:
# execute_non_blocking apt install -y kubelet kubeadm kubectl kubectx
execute_non_blocking() {
   "$@"
    local status=$?
    if [ $status -ne 0 ]; then
        oerr "$ERR_FEC"
    fi 
}

# Function: detects if package is installed.
# returns 0 if installed
# returns 1 if not installed
# Usage example:
# if ! is_package_installed $package; then [..]
is_package_installed() {
    PACKAGE_NAME=$1
    if dpkg-query -W -f='${Status}' "$PACKAGE_NAME" 2>/dev/null | grep -Eq "^(install|hold) ok installed$"; then
        wrn "Package $PACKAGE_NAME is already installed."
        return 0 # true in shell scripts
    else
        wrn "Package $PACKAGE_NAME is not yet installed."
        return 1 # false (anything above zero is) in shell scripts
    fi
}

# Function: apt-get without prompts. The script is unattended: a debconf or
# conffile question during upgrade/install would hang or fail the run.
# Usage example:
# apt_get install -y curl
apt_get() {
    DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

# Function: package installation with automated error recovery.
# Usage example:
# install_package containerd.io
install_package() {
    local package=$1
    if ! is_package_installed $package; then
        if ! apt_get install -y "$package"; then
            wrn "Installation failed for $package, attempting to fix broken dependencies..."
            execute apt_get --fix-broken install
            msg "Retrying installation of $package..."
            if ! apt_get install -y "$package"; then
                execution_error "$ERR_IRF"
            fi
        fi
        # A file, not a variable: kubectx is installed from a $(...) subshell.
        [ -n "$RUN_DIR" ] && printf '%s\n' "$package" >> "$RUN_DIR/packages"
    fi
}

# Function: apt-mark hold, recording which packages were not held before
# (-x releases only those).
# Usage example:
# hold_packages kubelet kubeadm kubectl
hold_packages() {
    local held p
    held=$(apt-mark showhold 2>/dev/null)
    for p in "$@"; do
        printf '%s\n' "$held" | grep -qxF "$p" || printf '%s\n' "$p" >> "$RUN_DIR/held"
    done
    execute apt-mark hold "$@"
}

# Function: set the node's hostname, recording the one it had (for -x).
# Usage example:
# set_node_hostname "$NODE_NAME"
set_node_hostname() {
    uname -n > "$RUN_DIR/hostname"
    execute hostnamectl set-hostname "$1"
}

# Function: download and apply from external sources with validation.
# Usage example:
# download_and_apply "https://raw.githubusercontent.com/projectcalico/calico/$CRDS/manifests/calico.yaml" "calico.yaml"
download_and_apply() {
    local url=$1
    local file=$2
    if curl -fsSL "$url" -o "$file"; then
        msg "$file downloaded successfully."
    else
        wrn "Error: Failed to download $file from $url. Retrying..."
        execute sleep 5
        if ! curl -fsSL "$url" -o "$file"; then
            execution_error "$ERR_RF"
        fi
    fi
    execute kubectl apply -f "$file"
}

# Function: read parameters from command line.
# Usage example:
# read_parameters "$@"
read_parameters() {
  while getopts ":m:w:l:v:c:n:i:p:t:h:a:u:xf" options; do
    case "${options}" in
      m)
        MASTER_NODE=${OPTARG}
        ;;
      w)
        WORKER_NODE=${OPTARG}
        ;;
      l)
        MASTER_LOGIN=${OPTARG}
        ;;
      v)
        VERSION=${OPTARG}
        ;;
      c)
        CRDS=${OPTARG}
        ;;
      n)
        CIDR=${OPTARG}
        ;;
      i)
        IP=${OPTARG}
        ;;
      p)
        PORT=${OPTARG}
        ;;
      t)
        TOKEN=${OPTARG}
        ;;
      h)
        HASH=${OPTARG}
        ;;
      a)
        ARCH=${OPTARG}
        ;;
      u)
        MASTER_USER=${OPTARG}
        ;;
      x)
        UNINSTALL=1
        ;;
      f)
        FORCE=1
        ;;
      *)
        execution_error "$ERR_UO"
        ;;
    esac
  done
}

# Function: Download and install Docker GPG key avoiding user interaction.
# Usage example:
# install_docker_gpg_key
install_docker_gpg_key() {
    msg "Backing up Docker GPG key."
    backup_file "$DOCKER_GPG"

    msg "Downloading the Docker GPG key."
    if ! curl -fsSL "$DOCKER_GPG_URL" | gpg --dearmour -o "$DOCKER_GPG_TMP"; then
        execution_error "$ERR_FFDGPGK"
    fi
    msg "Docker GPG key downloaded."

    msg "Updating Docker GPG key."
    execute mkdir -p "$(dirname "$DOCKER_GPG")" # the keyrings dir may not exist on an older release
    update_file "$DOCKER_GPG_TMP" "$DOCKER_GPG"
    execute chmod a+r "$DOCKER_GPG" # apt reads it as _apt, not as root
    msg "Docker GPG key updated."
}

# Function: the release codename for the Docker repository line.
# /etc/os-release first (always present); lsb_release only as a fallback.
# Usage example:
# codename=$(release_codename)
release_codename() {
    local codename=""
    if [ -f "$OS_RELEASE" ]; then
        codename=$(sed -n 's/^VERSION_CODENAME=//p' "$OS_RELEASE" | tr -d '"')
    fi
    if [ -z "$codename" ] && command -v lsb_release >/dev/null 2>&1; then
        codename=$(lsb_release -cs)
    fi
    printf '%s\n' "$codename"
}

# Function: comment out a Docker entry an older run added with
# add-apt-repository. Left next to docker.list, apt refuses the pair
# ("Conflicting values set for option Signed-By"). Backed up first.
# Usage example:
# retire_old_docker_sources
retire_old_docker_sources() {
    # shellcheck disable=SC2086 # APT_SOURCES is a list of paths
    grep -rlsF "$DOCKER_REPO" $APT_SOURCES 2>/dev/null | while read -r f; do
        [ "$f" = "$DOCKER_LIST" ] && continue
        wrn "Retiring an older Docker entry in $f (it now lives in $DOCKER_LIST)."
        backup_file "$f" edit
        execute sed -i "\\#^[[:space:]]*deb .*download\\.docker\\.com/linux/ubuntu#s/^/$DOCKER_MARK/" "$f"
    done
}

# Function: Add Docker repository.
# Usage example:
# add_docker_repository
add_docker_repository() {
    local codename
    msg "Adding the Docker repository to the system."
    codename=$(release_codename)
    if [ -z "$codename" ]; then
        execution_error "$ERR_FADR"
    fi
    retire_old_docker_sources
    backup_file "$DOCKER_LIST"
    if ! printf 'deb [arch=%s signed-by=%s] %s %s stable\n' "$ARCH" "$DOCKER_GPG" "$DOCKER_REPO" "$codename" > "$DOCKER_LIST"; then
        execution_error "$ERR_FADR"
    fi
    msg "Docker repository added."
}

# Function: switch containerd's runc to the systemd cgroup driver, as kubelet
# expects, and check that it took. Every containerd from 1.6 to 2.4 generates
# "SystemdCgroup = false" in its default config; one that stops doing so fails
# here, instead of leaving a node that runs with the wrong driver.
# Usage example:
# enable_systemd_cgroup "$CCF"
enable_systemd_cgroup() {
    local file="$1"
    execute sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' "$file"
    if ! grep -q 'SystemdCgroup = true' "$file"; then
        execution_error "$ERR_FSC"
    fi
}

install_containerd() {
    # check how to install docker with their remote script if the previous method fails
    msg "Installing Containerd package."
    install_package containerd.io

    msg "Backing up Containerd configuration."
    backup_file "$CCF"

    # configure containerd - DO NOT SKIP THIS STEP even if using docker shell script
    msg "Generating the default configuration for Containerd with superuser privileges, discarding any output and errors."
    # Not a pipeline: a failure in `containerd config default` inside `a | b`
    # would only exit the subshell, leaving a truncated config.toml behind.
    containerd config default > "$CCF" 2>/dev/null || execution_error "$ERR_FCC"
    msg "Updating the default configuration for Containerd."
    enable_systemd_cgroup "$CCF"

    # Restarting containerd to apply new configurations
    msg "Restarting containerd to apply new configurations."
    execute systemctl restart containerd
    if ! systemctl is-active --quiet containerd; then
        execution_error "$ERR_FRC"
    fi
    msg "Containerd restarted and is active."

    # Ensuring containerd is enabled on boot
    if ! systemctl is-enabled --quiet containerd; then
        msg "Enabling containerd to start on boot."
        execute systemctl enable containerd
        msg "Containerd enabled successfully."
    else
        msg "Containerd is already enabled on boot."
    fi
}

# Function: Download and install Kubernetes GPG key avoiding user interaction.
# Usage example:
# install_kubernetes_gpg_key
install_kubernetes_gpg_key(){
    msg "Preparing to download Kubernetes GPG key."
    K_GPG_URL="$K_CORE:/stable:/$VERSION/deb/Release.key"

    msg "Backing up current Kubernetes GPG key."
    backup_file "$K_GPG"

    msg "Downloading the Kubernetes GPG key."
    msg "Using url: $K_GPG_URL"
    if ! curl -fsSL "$K_GPG_URL" | gpg --dearmor -o "$K_GPG_TMP"; then
        execution_error "$ERR_FFKKF"
    fi
    msg "Kubernetes GPG key downloaded."

    msg "Updating Kubernetes GPG key file."
    execute mkdir -p "$(dirname "$K_GPG")" # keyrings dir may not exist on a fresh node
    update_file "$K_GPG_TMP" "$K_GPG"
    msg "Kubernetes GPG key file updated."
}

# Function: Add Kubernetes repository.
add_kubernetes_repository() {
    msg "Adding the Kubernetes repository to the system."
    # Recompute from the final VERSION: variables.sh freezes K_REPO at the
    # default because it is sourced before read_parameters processes -v.
    K_REPO="$K_CORE:/stable:/${VERSION}/deb/"
    backup_file "$K_LIST"
    if ! echo "deb [signed-by=$K_GPG] $K_REPO /" > "$K_LIST"; then
        execution_error "$ERR_FAKR"
    fi
    msg "Kubernetes repository added."
}

refresh_packages_list() {
    msg "Refreshing the package lists."
    execute apt-get update
}

upgrade_installed_packages() {
    msg "Upgrading installed packages to their latest versions."
    execute apt_get upgrade -y
}

# Function: restrict the kubeconfig to its owner.
# chown only when there is a sudo caller: run directly as root, SUDO_USER is
# empty and `chown "" file` fails, which used to roll back a fresh cluster.
# Usage example:
# secure_kubeconfig
secure_kubeconfig() {
    if [ -n "$SUDO_USER" ]; then
        execute chown "$SUDO_USER" "$KBCTLCFG"
    fi
    execute chmod 600 "$KBCTLCFG" # it holds cluster-admin credentials
}

# Function: Configure the kubectl tool.
# Will be needed to install the Custom Resources Definitions.
# Usage example:
# configure_kubectl
configure_kubectl() {  
    # Ensure the .kube directory exists
    if [ ! -d "$HOME/.kube" ]; then
        backup_file "$HOME/.kube" dir
        msg "Creating .kube directory."
        execute mkdir -p $HOME/.kube
    fi

    # Check if we already got a configuration.
    if [ ! -f $KBCTLCFG ]; then
        KBCTLCFG_CREATED=1 # whatever lands in $KBCTLCFG below is ours to remove on rollback
        backup_file "$KBCTLCFG" # recorded as created, for -x
        if [ -n "$MASTER_NODE" ]; then
            # Copy and set permissions for the configuration file
            if [ -f $KBCTLOCFG ]; then
                msg "Creating Kubectl user configuration."
                execute cp -f "$KBCTLOCFG" "$KBCTLCFG" # -f: unattended run, nobody can answer a -i prompt
                msg "Setting configuration permissions."
                secure_kubeconfig
                msg "Permissions set to owner read/write only."
            else
                oerr "$KBCTLOCFG is missing."
            fi
        else
            # This package is only needed in this situation.
            install_package sshpass
            # Get the Master node config into the Worker node
            if [ -z "$MASTER_USER" ]; then
                # run directly as root without -u: SUDO_USER is empty and "@$IP" is not a login
                wrn "No master node user (-u) and no SUDO_USER: skipping the kubeconfig copy."
            else
                wrn "Copying configuration from Master node: $IP"
                # accept-new: an unknown host key would otherwise prompt and abort sshpass.
                # Not fatal (the node has joined), but say so instead of ending with "All done".
                if sshpass -f "$MASTER_LOGIN" scp -o StrictHostKeyChecking=accept-new "$MASTER_USER@$IP:$KBCTLOCFG" "$KBCTLCFG"; then
                    secure_kubeconfig
                    msg "Kubectl configuration copied from the Master node."
                else
                    wrn "Could not copy $KBCTLOCFG from $MASTER_USER@$IP: kubectl is not configured on this node. Copy it to $KBCTLCFG manually."
                fi
            fi
        fi
    else
        msg "kubectl configuration already exists."
    fi
}

# Function: write a secret: readable by its owner only, and owned by the user
# who ran sudo, so they can read it without root. (The join files were 0644.)
# Usage example:
# write_private "$path" "$value"
write_private() {
    local path="$1"
    local value="$2"
    ( umask 077 && printf '%s\n' "$value" > "$path" ) || return 1
    if [ -n "$SUDO_USER" ]; then
        chown "$SUDO_USER" "$path" || return 1
    fi
}

# Function: Generates the discovery token, into "$path/token".
# A kubeadm token lasts 24 hours: a worker joining later needs a new one.
# Usage example:
# generate_join_token "some-path"
generate_join_token() {
    local path="$1"
    local token
    wrn "Generating a new token."
    wrn "Using path: $path."
    # Captured and checked before it is written: an empty or malformed file
    # would only fail later, on the worker, with a less useful message.
    token=$(kubeadm token create) || execution_error "$ERR_FGT"
    if ! printf '%s\n' "$token" | grep -Eqx '[a-z0-9]{6}\.[a-z0-9]{16}'; then
        execution_error "$ERR_IJT"
    fi
    write_private "$path/token" "$token" || execution_error "$ERR_FGT"
    wrn "The token is valid for 24 hours. After that, create a new one here: sudo kubeadm token create > $path/token"
}

# Function: the discovery token CA certificate hash, into "$path/hash".
# Step by step, each checked: in the old one-line pipeline only sed's exit
# status counted, so a failed openssl still wrote an (empty) hash.
# `openssl pkey` reads any key type; `rsa` only RSA.
# Usage example:
# generate_join_hash "some-path"
generate_join_hash() {
    local path="$1"
    local pubkey hash
    wrn "Retrieving the discovery token CA certificate hash."
    wrn "Using path: $path."
    pubkey=$(openssl x509 -pubkey -noout -in "$K_CA") || execution_error "$ERR_FGH"
    hash=$(printf '%s\n' "$pubkey" | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')
    if ! printf '%s\n' "$hash" | grep -Eqx '[0-9a-f]{64}'; then
        execution_error "$ERR_IJH"
    fi
    write_private "$path/hash" "$hash" || execution_error "$ERR_FGH"
}

# Function: Generates the discovery token and its CA certificate hash.
# Usage example:
# generate_join_credentials
generate_join_credentials() {
    backup_file "$MNJCRDFS" dir
    backup_file "$MNJCRDFS/token"
    backup_file "$MNJCRDFS/hash"
    if [ ! -d "$MNJCRDFS" ]; then
        execute mkdir -p "$MNJCRDFS"
    fi
    execute chmod 700 "$MNJCRDFS"
    if [ -n "$SUDO_USER" ]; then
        execute chown "$SUDO_USER" "$MNJCRDFS"
    fi
    generate_join_token "$MNJCRDFS"
    generate_join_hash "$MNJCRDFS"
}
# Function: Add current node to a Master Node.
# Starting the kubeadm in the MASTER NODE will generate the complete join command.
# Usage example:
# join_master
join_master() {
    msg "Joining Master Node."
    ping_it "$IP" # ping IP
    poke_it "$PORT" # check if port is free
    # Clean variables (remove whitespace)
    TOKEN=$(echo "$TOKEN" | xargs)
    HASH=$(echo "$HASH" | xargs)
    KUBEADM_RAN=1
    # Not execute_sensitive: its message would hide the likeliest cause, an expired token.
    if ! kubeadm join "$IP:$PORT" --token "$TOKEN" --discovery-token-ca-cert-hash "sha256:$HASH"; then
        execution_error "$ERR_JOIN"
    fi
    msg "$NODE_NAME joined Master Node."
}

# Function: install kubectx where the release packages it (Ubuntu 24.04 on),
# and say so where it does not: it is a convenience, kubectl works without it.
# Prints the package to hold, or nothing.
# Usage example:
# extra=$(install_kubectx_if_packaged)
install_kubectx_if_packaged() {
    if apt-cache show kubectx >/dev/null 2>&1; then
        install_package kubectx >&2
        printf 'kubectx\n'
    else
        wrn "kubectx is not packaged for this Ubuntu release (it is from 24.04 on) - skipped; kubectl works without it." >&2
    fi
}
