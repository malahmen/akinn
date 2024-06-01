#!/bin/sh

echo " Automated Kubernetes Installation for New Nodes - without user interaction."
if [ "$(id -u)" -ne 0 ]; then
    echo " Must be run as root. Trying with sudo..."
    exec sudo "$0" "$@"
    exit 1
fi

# Regular expressions for validations
re_ip='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$' # Regex: checks if the input is a valid IPv4 address.
re_port='^[1-9][0-9]*$' # Regex: checks if the input is a positive integer (greater than zero).
re_cidr='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' # Regex for CIDR block.
re_own_ip='^(?<=inet\s)\d+(\.\d+){3}$' # Regex for the current node's IP address.
re_kver='Kubernetes v[0-9]+\.[0-9]+\.[0-9]+' # Regex for the kubernetes release version.
re_crds_ver='release-v[0-9]+\.[0-9]+\.[0-9]+' # Regex for the custom resources definitions release version.

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
ARCH="amd64" # Architecture

# Variables
K_VERSIONS="" # Kubernetes versions
CRDS_VERSIONS="" # Kubernetes Custom Resources Definitions versions

# Configuration constants
K_RELEASES="https://github.com/kubernetes/kubernetes/releases" # Kubernetes releases
K_CORE="https://pkgs.k8s.io/core" # Kubernetes core
CRDS_RELEASES="https://github.com/projectcalico/calico/releases" # Kubernetes Custom Resources Definitions releases
CRDS_REPO="https://raw.githubusercontent.com/projectcalico/calico" # Kubernetes Custom Resources Definitions repository
DOCKER_GPG_KEY="https://download.docker.com/linux/ubuntu/gpg" # Docker GPG key
DOCKER_REPO="https://download.docker.com/linux/ubuntu" # Docker repository

# ERROR MESSAGES
ERR_FFCRDVER=" Error: Failed to fetch Custom Resources Definitions versions. Exiting."
ERR_FFKVER=" Error: Failed to fetch Kubernetes versions. Exiting."
ERR_ANS=" Error: Architecture is not set. Exiting."
ERR_HNNS=" Error: Node name is not set. Exiting."
ERR_IPNS=" Error: IP address is not set. Exiting."
ERR_IIP=" Error: IP address is invalid. Exiting."
ERR_PRTNS=" Error: PORT number is not set. Exiting."
ERR_IPRT=" Error: PORT number is invalid. Exiting."
ERR_TFNS=" Error: TOKEN file path is not set. Exiting."
ERR_TFNE=" Error: TOKEN file does not exist. Exiting."
ERR_HFNS=" Error: HASH file path is not set. Exiting."
ERR_HFNE=" Error: HASH file does not exist. Exiting."
ERR_IUV=" Error: Invalid or unsupported version. Exiting."
ERR_KVERNS=" Error: Kubernetes version is not set. Exiting."
ERR_CDRVERNS=" Error: Custom Resources Definitions version is not set. Exiting."
ERR_CIDRNS=" Error: CIDR block is not set. Exiting."
ERR_ICIDR=" Error: Invalid CIDR block. Exiting."
ERR_FEC=" Error: Failed to execute the command."
ERR_IRF=" Error: Installation failed after retry. Exiting."
ERR_RF=" Error: Retry failed. Please check your internet connection or the URL and try again. Exiting."
ERR_SE=" Error: Script will now exit."
ERR_UO=" Error: Unknown option."
ERR_FWMLC=" Error: Failed to write module load configurations. Exiting."
ERR_FWKP=" Error: Failed to write kernel parameters. Exiting."
ERR_FFDGPGK=" Error: Failed to download docker GPG key. Please check your internet connection or the URL and try again."
ERR_FADR=" Error: Failed to add Docker repository. Exiting."
ERR_FRC=" Error: Failed to restart containerd. Exiting."
ERR_FFKKF=" Error: Failed to retrieve kubernetes release key file. Please check your internet connection or the URL and try again."
ERR_FAKR=" Error: Failed to add Kubernetes repository. Exiting."

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
        echo " Restored original fstab configuration."
    fi
}

# Function: exits with message.
# Usage example:
# trap execution_error ERR
# execution_error "$ERR"
execution_error() {
    rollback_fstab;
    local err_code=$1
    if [ -z "$err_code" ]; then
        echo "$err_code"
    fi
    echo "$ERR_SE";
    exit 1
}

# Function: exits with help message.
# Usage example:
# parameter_missing_error $ERR
parameter_missing_error() {
    local err_message=$1
    if [ -z "$err_message" ]; then
        echo "$err_message"
    fi
    display_usage
    exit 1
}

# Function: loads available versions of Kubernetes and CRDs from their respective repositories.
# It fetches the versions by scraping GitHub release pages and stores them in K_VERSIONS and CRDS_VERSIONS.
# Usage example:
# load_versions
load_versions() {
    if ! CRDS_VERSIONS=$(curl -s $CRDS_RELEASES | grep -Eo $re_crds_ver | sed 's/release-//' | sort | uniq); then
        execution_error "$ERR_FFCRDVER"
    fi
    if ! K_VERSIONS=$(curl -s $K_RELEASES | grep -Eo $re_kver | sed 's/Kubernetes-//' | sort | uniq); then
        execution_error "$ERR_FFKVER"
    fi
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
    if [ -z "$ip" ]; then
        parameter_missing_error "$ERR_IPNS"
    fi
    if ! [[ $ip =~ $re_ip ]]; then
        execution_error "$ERR_IIP"
    fi
}

# Function: checks if an port number is valid
# Usage example:
# validate_port "$PORT"
validate_port() {
    local port=$1
    if [ -z "$port" ]; then
        parameter_missing_error "$ERR_PRTNS"
    fi
    if ! [[ $port =~ $re_port ]]; then
        execution_error "$ERR_IPRT"
    fi
}

# Function: validates the token input
# Usage example:
# validate_token "$TOKEN"
validate_token() {
    local token_file=$1
    if [ -z "$token_file" ]; then
        parameter_missing_error "$ERR_TFNS"
    fi
    if [ ! -f "$token_file" ]; then
        execution_error "$ERR_TFNE"
    fi
    TOKEN=$(< "$token_file")
}

# Function: validates the hash input
# Usage example:
# validate_hash "$HASH"
validate_hash() {
    local hash_file=$1
    if [ -z "$hash_file" ]; then
        parameter_missing_error "$ERR_HFNS"
    fi
    if [ ! -f "$hash_file" ]; then
        execution_error "$ERR_HFNE"
    fi
    HASH=$(< "$hash_file")
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
        echo " Installation failed for $package, attempting to fix broken dependencies..."
        execute apt-get --fix-broken install
        echo " Retrying installation of $package..."
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
        echo " $file downloaded successfully."
        execute kubectl apply -f "$file"
    else
        echo "Error: Failed to download $file from $url. Retrying..."
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
echo " Updating the package lists from the configured repositories on the current system."
execute apt-get update
echo " Upgrading installed packages on the current system to their latest versions."
execute apt-get upgrade -y

# enabling error handling with "automated recovery"
trap execution_error ERR

# disable swap - swap is bad for kubernetes (all nodes)
echo " Backing up fstab and disabling swap."
echo " Starting to disable swap..."
disable_swap
echo " Swap disabled successfully."

# add kernel modules to load on boot for containerd (all nodes)
echo " Adding kernel modules for containerd to be loaded on boot up."
if ! echo "overlay
br_netfilter" | tee /etc/modules-load.d/containerd.conf > /dev/null; then
    execution_error "$ERR_FWMLC"
fi
echo " Loading modules now."
execute modprobe overlay
execute modprobe br_netfilter

# configure kernel parameters for networking and IP forwarding related to Kubernetes (all nodes)
echo " Configuring system kernel parameters for networking and IP forwarding."
if ! echo "net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1" | tee /etc/sysctl.d/kubernetes.conf > /dev/null; then
    execution_error "$ERR_FWKP"
fi

# reload after 
echo " Reloading."
execute sysctl --system

# make sure we have the needed packages installed with automated error recovery (all nodes)
echo " Installing required packages."
install_package curl
install_package gnupg2
install_package software-properties-common
install_package apt-transport-https
install_package ca-certificates 
install_package gpg

# retrieves the GPG key for Docker, processes it, and saves it in the appropriate location for package management (all nodes)
echo " Downloading the docker GPG key."
if ! curl -fsSL $DOCKER_GPG_KEY | gpg --dearmour -o /etc/apt/trusted.gpg.d/docker.gpg; then
    execution_error "$ERR_FFDGPGK"
fi
# add the Docker repository to the system software sources
echo " Adding the Docker repository to the system."
if ! add-apt-repository "deb [arch=$ARCH] $DOCKER_REPO $(lsb_release -cs) stable"; then
    execution_error "$ERR_FADR"
fi

# install containerd
echo " Refreshing the package lists from the configured repositories on the system."
execute apt-get update
echo " Installing Containerd package."
install_package containerd.io
# check how to install docker with their remote script if the previous method fails
# configure containerd - DO NOT SKIP THIS STEP even if using docker shell script
echo " Generating the default configuration for Containerd with superuser privileges, discarding any output and errors."
execute containerd config default | tee /etc/containerd/config.toml >/dev/null 2>&1
echo " Updating the default configuration for Containerd."
execute sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml

# Restarting containerd to apply new configurations
echo " Restarting containerd to apply new configurations."
execute systemctl restart containerd
if ! systemctl is-active --quiet containerd; then
    execution_error "$ERR_FRC"
fi
echo " Containerd restarted and is active."

# Ensuring containerd is enabled on boot
if ! systemctl is-enabled --quiet containerd; then
    echo " Enabling containerd to start on boot."
    execute systemctl enable containerd
    echo " Containerd enabled successfully."
else
    echo " Containerd is already enabled on boot."
fi

# add kubernetes repositories (all nodes)
echo " Retrieving the release key file for kubernetes."
if ! curl -fsSL $K_CORE:/stable:/$VERSION/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg; then
    execution_error "$ERR_FFKKF"
fi
echo " Adding the Kubernetes repository to the system."
if ! add-apt-repository "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] $K_CORE:/stable:/${VERSION}/deb/ /"; then
    execution_error "$ERR_FAKR"
fi

# refresh the package list
echo " Refreshing the package lists with the new repositories."
execute apt-get update
# install
echo " Install Kubelet."
install_package kubelet
echo " Install Kubeadm."
install_package kubeadm
echo " Install Kubectl."
install_package kubectl
echo " Install Kubectx."
install_package kubectx
#apt install -y kubelet kubeadm kubectl kubectx
echo " Disabling auto-update for instaled packages."
execute apt-mark hold kubelet kubeadm kubectl kubectx # disable auto update
# set the hostname for each node
echo " Setting the node hostname."
execute hostnamectl set-hostname $HOSTNAME 
# enable kubelet
echo " Enabling Kubelet."
execute systemctl enable --now kubelet

if [ -n "$MASTER_NODE" ]; then
    # initialize the cluster (MASTER ONLY)
    echo " Initializing the Cluster."
    execute kubeadm init --apiserver-advertise-address=$IP --pod-network-cidr=$CIDR
    # throw in some crds plugins (MASTER ONLY)
    echo " Installing Crds."
    download_and_apply $CRDS_REPO/$CRDS/manifests/calico.yaml calico.yaml
fi

if [ -n "$WORKER_NODE" ]; then
    # join the cluster (WORKER ONLY)
    # starting the kubeadm in the MASTER NODE will generate the complete join command
    echo " Joining Master Node."
    execute_sensitive kubeadm join $IP:$PORT --token $TOKEN --discovery-token-ca-cert-hash sha256:$HASH
fi

# configure the kubectl tool
# Ensure the .kube directory exists
if [ ! -d "$HOME/.kube" ]; then
    echo " Creating .kube directory."
    execute mkdir -p $HOME/.kube
fi

# Copy and set permissions for the configuration file
if [ ! -f $HOME/.kube/config ]; then
    echo " Creating Kubectl user configuration."
    execute cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    echo " Setting configuration permissions."
    execute chown $(id -u):$(id -g) $HOME/.kube/config
    execute chmod 600 $HOME/.kube/config
    echo " Permissions set to owner read/write only."
else
    echo " Kubectl configuration already exists."
fi
