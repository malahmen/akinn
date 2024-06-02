#!/bin/sh

echo " Automated Kubernetes Installation for New Nodes - without user interaction."
if [ "$(id -u)" -ne 0 ]; then
    echo " Must be run as root. Trying with sudo..."
    exec sudo HOME="$HOME" "$0" "$@"
    exit 1
fi

# Regular expressions for validations
re_ip='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$' # Regex: checks if the input is a valid IPv4 address.
re_port='^[1-9][0-9]*$' # Regex: checks if the input is a positive integer (greater than zero).
re_cidr='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' # Regex for CIDR block.
re_own_ip='^(?<=inet\s)\d+(\.\d+){3}$' # Regex for the current node's IP address.
re_kver='Kubernetes\sv[0-9]+\.[0-9]+\.[0-9]+' # Regex for the kubernetes release version.
re_crds_ver='release-v[0-9]+\.[0-9]+\.[0-9]+' # Regex for the custom resources definitions release version.

# Define color codes
RED='\033[0;31m'    # execution error messages
YELLOW='\033[0;33m' # parameters error messages
GREEN='\033[0;32m'  # regular messages
NC='\033[0m'  # No Color

# Parameters with default values
HOSTNAME="" # Node reulting name (from master or worker option).
MASTER_NODE="" 	# Master node name - if installing one, need a name.
WORKER_NODE="" 	# Worker node name - if installing one, need a name.
VERSION="v1.30" # Kubernetes default version.
CRDS="v3.25.0"  # Kubernetes Custom Resources Definitions version.
CIDR="10.244.0.0/24" # Classless Inter-Domain Routing blocks for Kubernetes pods.
IP=$(ip addr show $(ip route | grep default | awk '{print $5}') | grep -oP $re_own_ip) # Worker node needs the master's IP address.
PORT="6443" # Worker node needs the master's port number.
TOKEN="" # Worker node needs a token to join master. 
HASH="" # Worker node needs a hash to join master. 
ARCH="$(dpkg --print-architecture)" # Architecture

# Variables
K_VERSIONS="" # Kubernetes versions
CRDS_VERSIONS="" # Kubernetes Custom Resources Definitions versions

# Configuration constants
DOCKER_REPO="https://download.docker.com/linux/ubuntu" # Docker repository
DOCKER_GPG_URL="https://download.docker.com/linux/ubuntu/gpg" # Docker GPG key url
DOCKER_GPG_TMP="/tmp/docker.gpg"
DOCKER_GPG_BKP="/tmp/bkp.docker.gpg"
DOCKER_GPG="/etc/apt/trusted.gpg.d/docker.gpg"

K_RELEASES="https://github.com/kubernetes/kubernetes/releases" # Kubernetes releases
K_CORE="https://pkgs.k8s.io/core" # Kubernetes core packages
K_REPO="$K_CORE:/stable:/${VERSION}/deb/"
K_LIST="/etc/apt/sources.list.d/kubernetes.list"
K_GPG_TMP="/tmp/kubernetes.gpg"
K_GPG_BKP=/tmp/bkp.kubernetes.gpg
K_GPG="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"

CRDS_RELEASES="https://github.com/projectcalico/calico/releases" # Kubernetes Custom Resources Definitions releases
CRDS_REPO="https://raw.githubusercontent.com/projectcalico/calico" # Kubernetes Custom Resources Definitions repository

# ERROR MESSAGES
ERR_FFCRDVER=" Error: Failed to fetch Custom Resources Definitions versions."
ERR_FFKVER=" Error: Failed to fetch Kubernetes versions."
ERR_ANS=" Error: Architecture is not set."
ERR_HNNS=" Error: Node name is not set."
ERR_IPNS=" Error: IP address is not set."
ERR_IIP=" Error: IP address is invalid."
ERR_UNRIP=" Error: IP address is unreachable."
ERR_PRTNS=" Error: PORT number is not set."
ERR_IPRT=" Error: PORT number is invalid."
ERR_TFNS=" Error: TOKEN file path is not set."
ERR_TFNE=" Error: TOKEN file does not exist."
ERR_HFNS=" Error: HASH file path is not set."
ERR_HFNE=" Error: HASH file does not exist."
ERR_IUV=" Error: Invalid or unsupported version."
ERR_KVERNS=" Error: Kubernetes version is not set."
ERR_CDRVERNS=" Error: Custom Resources Definitions version is not set."
ERR_CIDRNS=" Error: CIDR block is not set."
ERR_ICIDR=" Error: Invalid CIDR block."
ERR_FEC=" Error: Failed to execute the command."
ERR_IRF=" Error: Installation failed after retry."
ERR_RF=" Error: Retry failed. Please check your internet connection or the URL and try again."
ERR_SE=" An error occurred. Exiting."
ERR_UO=" Error: Unknown option."
ERR_FWMLC=" Error: Failed to write module load configurations."
ERR_FWKP=" Error: Failed to write kernel parameters."
ERR_FFDGPGK=" Error: Failed to download docker GPG key. Please check your internet connection or the URL and try again."
ERR_FADR=" Error: Failed to add Docker repository."
ERR_FRC=" Error: Failed to restart containerd."
ERR_FFKKF=" Error: Failed to retrieve kubernetes release key file. Please check your internet connection or the URL and try again."
ERR_FAKR=" Error: Failed to add Kubernetes repository."

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
        printf "${GREEN}$message${NC}\n" 
    fi
}

# Function: prints error message in yellow.
# Usage example:
# wrn "some message"
wrn(){
    local message="$1"
    if [ -n "$message" ]; then
        printf "${YELLOW}$message${NC}\n" 
    fi
}

# Function: prints error message in red.
# Usage example:
# oerr "some message"
oerr(){
    local message="$1"
    if [ -n "$message" ]; then
        printf "${RED}$message${NC}\n" 
    fi
}

# Function: disable swap and backup fstab
# Usage example:
# disable_swap
disable_swap() {
    if [ -f "/etc/fstab" ]; then
        cp /etc/fstab /etc/fstab.backup
    fi
    swapoff -a
    sed -i '/ swap / s/^/#/' /etc/fstab
}

# Function: rollback fstab changes
# Usage example:
# rollback_fstab
rollback_fstab() {
     if [ -f "/etc/fstab.backup" ]; then
        mv /etc/fstab.backup /etc/fstab
        msg " Restored original fstab configuration."
    fi
}

# Function: exits with message.
# Usage example:
# trap execution_error ERR
# execution_error "$ERR"
execution_error() {
    rollback_fstab
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
    msg " Loading CRDs versions."
    if ! CRDS_VERSIONS=$(curl -s $CRDS_RELEASES | grep -Eo $re_crds_ver | sed 's/release-//' | sort | uniq); then
        execution_error "$ERR_FFCRDVER"
    fi
    msg " CRDs versions loaded:"
    echo "$CRDS_VERSIONS"
    msg " Loading Kubernetes versions."
    if ! K_VERSIONS=$(curl -s $K_RELEASES | grep -Eo $re_kver | sed 's/Kubernetes //' | sort | uniq); then
        execution_error "$ERR_FFKVER"
    fi
    msg " Kubernetes versions loaded:"
    echo "$K_VERSIONS"
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

# Function: checks if an IP address is valid
# Usage example:
# validate_ip_address "$IP"
validate_ip_address() {
    local ip=$1
    msg " Checking IP exists..."
    if [ -z "$ip" ]; then
        parameter_missing_error "$ERR_IPNS"
    fi
    msg " IP exists: $ip"
    msg " Validating IP: $ip"
    if ! echo "$ip" | grep -qE "$re_ip"; then
        execution_error "$ERR_IIP"
    fi
    msg " IP: $ip - valid."
    msg " Checking if reachable..."
    if ! ping -c 1 "$ip" > /dev/null 2>&1; then
        execution_error "$ERR_UNRIP"
    fi
    msg " IP $ip is valid and reachable."
}

# Function: checks if an port number is valid
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
    msg " Opening port $port."
    ufw allow $port/tcp
}

# Function: validates the token input
# Usage example:
# validate_token "$TOKEN"
validate_token() {
    local token_file=$1
    if [ -z "$token_file" ]; then
        parameter_missing_error "$ERR_TFNS"
    fi
    token_file_path=$(eval echo "$token_file")
    msg " Looking for the token file: $token_file_path"
    if [ ! -f "$token_file_path" ]; then
        execution_error "$ERR_TFNE"
    fi
    msg " Token file exists. Reading it."
    TOKEN=$(cat "$token_file_path")
    msg " Token file read."
}

# Function: validates the hash input
# Usage example:
# validate_hash "$HASH"
validate_hash() {
    local hash_file=$1
    if [ -z "$hash_file" ]; then
        parameter_missing_error "$ERR_HFNS"
    fi
    hash_file_path=$(eval echo "$hash_file")
    msg " Looking for the hash file: $hash_file_path"
    if [ ! -f "$hash_file_path" ]; then
        execution_error "$ERR_HFNE"
    fi
    msg " Hash file exists. Reading it."
    HASH=$(cat "$hash_file_path")
    msg " Hash file read."
}

# Function: Validate Kubernetes and CRDs versions against existing ones
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

# Function: Validate Kubernetes version input
# Usage example:
# validate_kubernetes_version "$VERSION"
validate_kubernetes_version() {
    local version=$1
    if [ -z "$version" ]; then
        parameter_missing_error "$ERR_KVERNS"
    fi
    validate_version "$version" "kubernetes"
}

# Function: Validate Kubernetes crds version input
# Usage example:
# validate_crds_version "$CRDS"
validate_crds_version() {
    local version=$1
    if [ -z "$version" ]; then
        parameter_missing_error "$ERR_CDRVERNS"
    fi
    validate_version "$version" "crds"
}

# Function: Validate CIDR block
# Usage example:
# validate_cidr_block "$CIDR"
validate_cidr_block() {
    local cidr=$1
    if [ -z "$cidr" ]; then
        parameter_missing_error "$ERR_CIDRNS"
    fi
    if ! [[ $cidr =~ $re_cidr ]]; then
        execution_error "$ERR_ICIDR"
    fi
}

# Function: execute commands with enhanced error handling
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

# Function: execute commands with error handling (no vars printed)
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

# Function: package installation with automated error recovery
# Usage example:
# install_package containerd.io
install_package() {
    local package=$1
    if ! apt-get install -y "$package"; then
        wrn " Installation failed for $package, attempting to fix broken dependencies..."
        execute apt-get --fix-broken install
        msg " Retrying installation of $package..."
        if ! apt-get install -y "$package"; then
            execution_error "$ERR_IRF"
        fi
    fi
}

# Function: download and apply from external sources with validation
# Usage example:
# download_and_apply "https://raw.githubusercontent.com/projectcalico/calico/$CRDS/manifests/calico.yaml" "calico.yaml"
download_and_apply() {
    local url=$1
    local file=$2
    if curl -fsSL "$url" -o "$file"; then
        msg " $file downloaded successfully."
        execute kubectl apply -f "$file"
    else
        wrn "Error: Failed to download $file from $url. Retrying..."
        execute sleep 5
        if ! curl -fsSL "$url" -o "$file"; then
            execution_error "$ERR_RF"
        fi
    fi
}

# Function: read parameters from command line
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

# Function: Download and install Docker GPG key avoiding user interaction
# Usage example:
# install_docker_gpg_key
install_docker_gpg_key() {
    msg " Preparing to download Docker GPG key."

    if [ -f "$DOCKER_GPG" ]; then
        msg " Backing up current Docker GPG key."
        if ! cp "$DOCKER_GPG" "$DOCKER_GPG_BKP"; then
            wrn " Failed to backup current Docker GPG key."
        else
            msg " Current Docker GPG key backed up."
        fi
    fi

    msg " Downloading the Docker GPG key."
    if ! curl -fsSL "$DOCKER_GPG_URL" | gpg --dearmour -o "$DOCKER_GPG_TMP"; then
        wrn " Clearing backup file."
        rm -f "$DOCKER_GPG_BKP"
        wrn " Backup file cleared."
        execution_error "$ERR_FFDGPGK"
    fi

    msg " Docker GPG key downloaded."
    msg " Updating Docker GPG key from temporary file."
    if mv "$DOCKER_GPG_TMP" "$DOCKER_GPG"; then
        msg " Docker GPG key updated."
    else
        execution_error " Failed to update Docker GPG key."
    fi
}

# Function: Add Docker repository
add_docker_repository() {
    msg " Adding the Docker repository to the system."
    if ! add-apt-repository "deb [arch=$ARCH] $DOCKER_REPO $(lsb_release -cs) stable" -y; then
        execution_error "$ERR_FADR"
    fi
    msg " Docker repository added."
}

install_containerd(){
    msg " Installing Containerd package."
    install_package containerd.io
    # check how to install docker with their remote script if the previous method fails
    # configure containerd - DO NOT SKIP THIS STEP even if using docker shell script
    msg " Generating the default configuration for Containerd with superuser privileges, discarding any output and errors."
    execute containerd config default | tee /etc/containerd/config.toml >/dev/null 2>&1
    msg " Updating the default configuration for Containerd."
    execute sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml

    # Restarting containerd to apply new configurations
    msg " Restarting containerd to apply new configurations."
    execute systemctl restart containerd
    if ! systemctl is-active --quiet containerd; then
        execution_error "$ERR_FRC"
    fi
    msg " Containerd restarted and is active."

    # Ensuring containerd is enabled on boot
    if ! systemctl is-enabled --quiet containerd; then
        msg " Enabling containerd to start on boot."
        execute systemctl enable containerd
        msg " Containerd enabled successfully."
    else
        msg " Containerd is already enabled on boot."
    fi
}

# Function: Download and install Kubernetes GPG key avoiding user interaction
# Usage example:
# install_kubernetes_gpg_key
install_kubernetes_gpg_key(){
    msg " Preparing to download Kubernetes GPG key."
    K_GPG_URL="$K_CORE:/stable:/$VERSION/deb/Release.key"

    if [ -f "$K_GPG" ]; then
        msg " Backing up current Kubernetes GPG key."
        if ! cp "$K_GPG" "$K_GPG_BKP"; then
            wrn " Failed to backup current Kubernetes GPG key."
        else
            msg " Current Kubernetes GPG key backed up."
        fi
    fi

    msg " Downloading the Kubernetes GPG key."
    msg " Using url: $K_GPG_URL"
    if ! curl -fsSL $K_GPG_URL | gpg --dearmor -o $K_GPG_TMP; then
        wrn " Clearing backup file."
        rm -f "$K_GPG_BKP"
        wrn " Backup file cleared."
        execution_error "$ERR_FFKKF"
    fi

    msg " Kubernetes GPG key downloaded."
    msg " Updating Kubernetes GPG key from temporary file."
    if mv "$K_GPG_TMP" "$K_GPG"; then
        msg " Kubernetes GPG key updated."
    else
        execution_error " Failed to update Kubernetes GPG key."
    fi
}

# Function: Add Kubernetes repository
add_kubernetes_repository() {
    msg " Adding the Kubernetes repository to the system."
    echo "deb [signed-by=$K_GPG] $K_REPO /" | tee $K_LIST > /dev/null
    if [ $? -ne 0 ]; then
        execution_error "$ERR_FAKR"
    fi
    msg " Kubernetes repository added."
}

refresh_packages_list() {
    msg " Refreshing the package lists."
    execute apt-get update
}

upgrade_installed_packages() {
    msg " Upgrading installed packages to their latest versions."
    execute apt-get upgrade -y
}

# Read parameters from command line
read_parameters "$@"

# check nodes common parameters
# validate the architecture
validate_architecture "$ARCH"
# start with the node name
validate_hostname
# validate the node final IP address
validate_ip_address "$IP"
# load existing versions
load_versions
# validate the kubernetes version
validate_kubernetes_version "$VERSION"

# check master node related parameters
if [ -n "$MASTER_NODE" ]; then
    # validate the kubernetes plugins version
    validate_crds_version "$CRDS"
    # validate the kubernetes pods IP range
    validate_cidr_block "$CIDR"
fi

# check worker node related parameters
if [ -n "$WORKER_NODE" ]; then
  # validate the port
  validate_port "$PORT"
  # validate the token
  validate_token "$TOKEN"  # Here $TOKEN is expected to be a path to the token file
  # validate the hash
  validate_hash "$HASH"    # Here $HASH is expected to be a path to the hash file
fi

# START INSTALLING

# update and upgrade the system (all nodes)
refresh_packages_list
upgrade_installed_packages

# enabling error handling with "automated recovery"
trap execution_error ERR

# disable swap - swap is bad for kubernetes (all nodes)
msg " Backing up fstab and disabling swap."
msg " Starting to disable swap..."
disable_swap
msg " Swap disabled successfully."

# add kernel modules to load on boot for containerd (all nodes)
msg " Adding kernel modules for containerd to be loaded on boot up."
if ! echo "overlay
br_netfilter" | tee /etc/modules-load.d/containerd.conf > /dev/null; then
    execution_error "$ERR_FWMLC"
fi
msg " Loading modules now."
execute modprobe overlay
execute modprobe br_netfilter

# configure kernel parameters for networking and IP forwarding related to Kubernetes (all nodes)
msg " Configuring system kernel parameters for networking and IP forwarding."
if ! echo "net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1" | tee /etc/sysctl.d/kubernetes.conf > /dev/null; then
    execution_error "$ERR_FWKP"
fi

# reload after 
msg " Reloading."
execute sysctl --system

# make sure we have the needed packages installed with automated error recovery (all nodes)
msg " Installing required packages."
install_package curl
install_package gnupg2
install_package software-properties-common
install_package apt-transport-https
install_package ca-certificates 
install_package gpg

# retrieves the GPG key for Docker, processes it, and saves it in the appropriate location for package management (all nodes)
install_docker_gpg_key
# add the Docker repository to the system software sources
add_docker_repository

refresh_packages_list

# install containerd
install_containerd

# retrieves the GPG key for Kubernetes, processes it, and saves it in the appropriate location for package management (all nodes)
install_kubernetes_gpg_key
# add kubernetes repository (all nodes)
add_kubernetes_repository

refresh_packages_list

# install
msg " Install Kubelet."
install_package kubelet
msg " Install Kubeadm."
install_package kubeadm
msg " Install Kubectl."
install_package kubectl
msg " Install Kubectx."
install_package kubectx

msg " Disabling auto-update for instaled packages."
execute apt-mark hold kubelet kubeadm kubectl kubectx # disable auto update
# set the hostname for each node
msg " Setting the node hostname."
execute hostnamectl set-hostname $HOSTNAME 
# enable kubelet
msg " Enabling Kubelet."
execute systemctl enable --now kubelet
# disable swap rollback from now on
execute rm "/etc/fstab.backup"

if [ -n "$MASTER_NODE" ]; then
    # initialize the cluster (MASTER ONLY)
    msg " Initializing the Cluster."
    execute kubeadm init --apiserver-advertise-address=$IP --pod-network-cidr=$CIDR
    # throw in some crds plugins (MASTER ONLY)
    msg " Installing Crds."
    download_and_apply $CRDS_REPO/$CRDS/manifests/calico.yaml calico.yaml
fi

if [ -n "$WORKER_NODE" ]; then
    # join the cluster (WORKER ONLY)
    # starting the kubeadm in the MASTER NODE will generate the complete join command
    msg " Joining Master Node."
    # Clean variables (remove whitespace)
    TOKEN=$(echo "$TOKEN" | xargs)
    HASH=$(echo "$HASH" | xargs)
    execute_sensitive kubeadm join "$IP:$PORT" --token "$TOKEN" --discovery-token-ca-cert-hash "sha256:$HASH"
    msg " Master has a new worker: $HOSTNAME"
fi

# configure the kubectl tool
# Ensure the .kube directory exists
if [ ! -d "$HOME/.kube" ]; then
    msg " Creating .kube directory."
    execute mkdir -p $HOME/.kube
fi

# Copy and set permissions for the configuration file
if [ ! -f $HOME/.kube/config ]; then
    msg " Creating Kubectl user configuration."
    execute cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    msg " Setting configuration permissions."
    execute chown $(id -u):$(id -g) $HOME/.kube/config
    execute chmod 600 $HOME/.kube/config
    msg " Permissions set to owner read/write only."
else
    msg " Kubectl configuration already exists."
fi
