# Function: prints a help message.
# Usage example:
# display_usage
display_usage() {
    cat << EOF 1>&2
  Usage: $0 [options]
  Options:
    -m MASTER_NODE   Set the master node name
    -w WORKER_NODE   Set the worker node name
    -v VERSION       Set the Kubernetes version
    -c CRDS          Set the Kubernetes Custom Resources Definitions version
    -n CIDR          Set the Classless Inter-Domain Routing blocks for Kubernetes pods
    -i IP            Set the master node IP address for the worker
    -p PORT          Set the master node port number for the worker
    -t TOKEN         Set the token for the worker to join the master
    -h HASH          Set the hash for the worker to join the master
    -a ARCH          Set the architecture
EOF
}

# Function: prints message in green.
# Usage example:
# msg "some message"
msg(){
    local message="$1"
    if [ -n "$message" ]; then
        printf "${GREEN} $message${NC}\n" 
    fi
}

# Function: prints error message in yellow.
# Usage example:
# wrn "some message"
wrn(){
    local message="$1"
    if [ -n "$message" ]; then
        printf "${YELLOW} $message${NC}\n" 
    fi
}

# Function: prints error message in red.
# Usage example:
# oerr "some message"
oerr(){
    local message="$1"
    if [ -n "$message" ]; then
        printf "${RED} Error: $message${NC}\n" 
    fi
}

# Function: creates backup file from origin file.
# Usage example:
# backup_file "$origin" "$destiny"
backup_file() {
    local origin="$1"
    local destiny="$2"
    if [ -f "$origin" ]; then
        msg "$origin exists, backing up."
        if ! cp "$origin" "$destiny"; then
            wrn "failed to backup $origin."
        else
            msg "$origin backed up."
        fi
    else 
        wrn "$origin not found, nothing to backup."
    fi
}

# Function: updates origin file with backup file.
# Backup file is deleted on success.
# Usage example:
# revert_to_backup "$backup" "$origin"
revert_to_backup() {
    local backup="$1"
    local origin="$2"
    if [ -f "$backup" ]; then
        msg "$backup exists, reverting."
        if ! mv "$backup" "$origin"; then
            wrn "failed to revert $origin."
        else
            msg "$origin reverted."
        fi
    else
        wrn "$backup not found, nothing to revert."
    fi
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
    backup_file "$FSTABF" "$FSTABFB"
    swapoff -a
    sed -i '/ swap / s/^/#/' /etc/fstab
}

# Function: rollback file changes
# Usage example:
# rollback_files
rollback_files(){
    if [ -f "$KBCTLCFG" ]; then
        if command -v kubeadm &> /dev/null; then
            wrn "Reseting kubeadm."
            kubeadm reset -f
        fi
    fi
    revert_to_backup "$FSTABFB" "$FSTABF" # rollback fstab file
    revert_to_backup "$DOCKER_GPG_BKP" "$DOCKER_GPG" # rollback Docker GPG key
    revert_to_backup "$K_GPG_BKP" "$K_GPG" # rollback kubernetes GPG key
    revert_to_backup "$CCFB" "$CCF" # rollback containerd configuration
    rm -rf "$DOCKER_GPG_TMP" # remove tmp files to avoid overwrite input
    rm -rf "$K_GPG_TMP"
    rm -rf $HOME/.kube # clear kubectl configuration files
}

# Function: exits with message.
# Usage example:
# trap execution_error ERR
# execution_error "$ERR"
execution_error() {
    rollback_files
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
    msg "Loading CRDs versions."
    if ! CRDS_VERSIONS=$(curl -s $CRDS_RELEASES | grep -Eo $re_crds_ver | sed 's/release-//' | sort | uniq); then
        execution_error "$ERR_FFCRDVER"
    fi
    msg "CRDs versions loaded."
    msg "Loading Kubernetes versions."
    if ! K_VERSIONS=$(curl -s $K_RELEASES | grep -Eo $re_kver | sed 's/Kubernetes //' | sort | uniq); then
        execution_error "$ERR_FFKVER"
    fi
    msg "Kubernetes versions loaded."
}

# Function: validates the architecture input
# Usage example:
# validate_architecture "$ARCH"
validate_architecture() {
    local arch=$1
    if [ -z "$arch" ]; then
        parameter_missing_error "$ERR_ANS"
    fi
}

# Function: checks if a node name is given
# Usage example:
# validate_hostname
validate_hostname() {
    # master > worker
    if [ -n "$MASTER_NODE" ]; then
        HOSTNAME=${MASTER_NODE}
        WORKER_NODE="" # enforce Master
    elif [ -n "$WORKER_NODE" ]; then
        HOSTNAME=${WORKER_NODE}
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
    # poke worker node port
    if ss -tuln | grep -q ":$this_port"; then
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
    token_file_path=$(eval echo "$token_file")
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
    hash_file_path=$(eval echo "$hash_file")
    msg "Looking for the hash file: $hash_file_path"
    if [ ! -f "$hash_file_path" ]; then
        execution_error "$ERR_HFNE"
    fi
    msg "Hash file exists. Reading it."
    HASH=$(cat "$hash_file_path")
    msg "Hash file read."
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
    if ! echo "$versions" | grep -q "$version"; then
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

# Function: package installation with automated error recovery.
# Usage example:
# install_package containerd.io
install_package() {
    local package=$1
    if ! is_package_installed $package; then
        if ! apt-get install -y "$package"; then
            wrn "Installation failed for $package, attempting to fix broken dependencies..."
            execute apt-get --fix-broken install
            msg "Retrying installation of $package..."
            if ! apt-get install -y "$package"; then
                execution_error "$ERR_IRF"
            fi
        fi
    fi
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
  while getopts ":m:w:v:c:n:i:p:t:h:a:" options; do
    case "${options}" in
      m)
        MASTER_NODE=${OPTARG}
        ;;
      w)
        WORKER_NODE=${OPTARG}
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
        if [ -n "$WORKER_NODE" ]; then
          IP=${OPTARG}
        fi
        ;;
      p)
        if [ -n "$WORKER_NODE" ]; then
          PORT=${OPTARG}
        fi
        ;;
      t)
        if [ -n "$WORKER_NODE" ]; then
          TOKEN=${OPTARG}
        fi
        ;;
      h)
        if [ -n "$WORKER_NODE" ]; then
          HASH=${OPTARG}
        fi
        ;;
      a)
        ARCH=${OPTARG}
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
    backup_file "$DOCKER_GPG" "$DOCKER_GPG_BKP"

    msg "Downloading the Docker GPG key."
    if ! curl -fsSL "$DOCKER_GPG_URL" | gpg --dearmour -o "$DOCKER_GPG_TMP"; then
        execution_error "$ERR_FFDGPGK"
    fi
    msg "Docker GPG key downloaded."

    msg "Updating Docker GPG key."
    update_file "$DOCKER_GPG_TMP" "$DOCKER_GPG"
    msg "Docker GPG key updated."
}

# Function: Add Docker repository.
add_docker_repository() {
    msg "Adding the Docker repository to the system."
    if ! add-apt-repository "deb [arch=$ARCH] $DOCKER_REPO $(lsb_release -cs) stable" -y; then
        execution_error "$ERR_FADR"
    fi
    msg "Docker repository added."
}

install_containerd() {
    # check how to install docker with their remote script if the previous method fails
    msg "Installing Containerd package."
    install_package containerd.io

    msg "Backing up Containerd configuration."
    backup_file "$CCF" "$CCFB"

    # configure containerd - DO NOT SKIP THIS STEP even if using docker shell script
    msg "Generating the default configuration for Containerd with superuser privileges, discarding any output and errors."
    execute containerd config default | tee $CCF >/dev/null 2>&1
    msg "Updating the default configuration for Containerd."
    execute sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' $CCF

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
    backup_file "$K_GPG" "$K_GPG_BKP"

    msg "Downloading the Kubernetes GPG key."
    msg "Using url: $K_GPG_URL"
    if ! curl -fsSL $K_GPG_URL | gpg --dearmor -o $K_GPG_TMP; then
        execution_error "$ERR_FFKKF"
    fi
    msg "Kubernetes GPG key downloaded."

    msg "Updating Kubernetes GPG key file."
    update_file "$K_GPG_TMP" "$K_GPG"
    msg "Kubernetes GPG key file updated."
}

# Function: Add Kubernetes repository.
add_kubernetes_repository() {
    msg "Adding the Kubernetes repository to the system."
    echo "deb [signed-by=$K_GPG] $K_REPO /" | tee $K_LIST > /dev/null
    if [ $? -ne 0 ]; then
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
    execute apt-get upgrade -y
}

# Function: Configure the kubectl tool.
# Will be needed to install the Custom Resources Definitions.
# Usage example:
# configure_kubectl
configure_kubectl() {  
    # Ensure the .kube directory exists
    if [ ! -d "$HOME/.kube" ]; then
        msg "Creating .kube directory."
        execute mkdir -p $HOME/.kube
    fi

    # Copy and set permissions for the configuration file
    if [ ! -f $KBCTLCFG ]; then
        if [ -f $KBCTLOCFG ]; then
            msg "Creating Kubectl user configuration."
            execute cp -i $KBCTLOCFG $KBCTLCFG
            msg "Setting configuration permissions."
            #urrent_user=$(echo $SUDO_USER)
            execute chown $(echo $SUDO_USER) $KBCTLCFG
            execute chmod u+rx $file_path
            #execute chown $(id -u):$(id -g) $HOME/.kube/config
            #execute chmod 600 $HOME/.kube/config
            msg "Permissions set to owner read/execute only."
        else
            oerr "$KBCTLOCFG is missing."
        fi
    else
        msg "kubectl configuration already exists."
    fi
}

# Function: Generates the discovery token.
# Will save it in a file in a configurable location.
# Usage example:
# generate_join_token "some-path"
generate_join_token() {
    local path="$1"
    wrn "Generating a new token."
    wrn "Using path: $path."
    echo $(sudo kubeadm token create) > "$path/token"
}

# Function: Generates the discovery token CA certificate hash.
# Will save it in a file in a configurable location.
# Usage example:
# generate_join_hash "some-path"
generate_join_hash() {
    local path="$1"
    wrn "Retrieving the discovery token CA certificate hash."
    wrn "Using path: $path."
    echo $(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
       openssl rsa -pubin -outform der 2>/dev/null | \
       openssl dgst -sha256 -hex | \
       sed 's/^.* //') > "$path/hash"
}

# Function: Generates the discovery token and its CA certificate hash.
# Usage example:
# generate_join_credentials
generate_join_credentials() {
    if [ ! -d "$directory" ]; then
        execute mkdir -p $MNJCRDFS
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
    execute_sensitive kubeadm join "$IP:$PORT" --token "$TOKEN" --discovery-token-ca-cert-hash "sha256:$HASH"
    msg "$HOSTNAME joined Master Node."
}