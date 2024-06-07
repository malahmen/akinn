#!/bin/sh

if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root. Trying with sudo..."
    exec sudo HOME="$HOME" "$0" "$@"
    exit 1
fi
echo "Automated Kubernetes Installation for New Nodes - without user interaction."

# Get the current directory of this script.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Loads the external files in the same directory
. "$SCRIPT_DIR/regex.sh" # loads regular expressions for validation.
. "$SCRIPT_DIR/colors.sh" # loads terminal colors.
. "$SCRIPT_DIR/parameters.sh" # loads parameters default values.
. "$SCRIPT_DIR/constants.sh" # loads configuration constants.
. "$SCRIPT_DIR/variables.sh" # loads used variables. requires constants and parameters.
. "$SCRIPT_DIR/errors.sh" # loads the error messages.
. "$SCRIPT_DIR/functions.sh" # loads the functions used.

# Read parameters from command line
read_parameters "$@"

# VALIDATION FLOW

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

# INSTALLING FLOW

# update and upgrade the system (all nodes)
refresh_packages_list
upgrade_installed_packages

# enabling error handling with "automated recovery"
trap execution_error ERR

# disable swap - swap is bad for kubernetes (all nodes)
msg "Starting to disable swap..."
disable_swap
msg "Swap disabled successfully."

# add kernel modules to load on boot for containerd (all nodes)
msg "Adding kernel modules for containerd to be loaded on boot up."
if ! echo "overlay
br_netfilter" | tee /etc/modules-load.d/containerd.conf > /dev/null; then
    execution_error "$ERR_FWMLC"
fi
msg "Loading modules now."
execute modprobe overlay
execute modprobe br_netfilter

# configure kernel parameters for networking and IP forwarding related to Kubernetes (all nodes)
msg "Configuring system kernel parameters for networking and IP forwarding."
if ! echo "net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1" | tee /etc/sysctl.d/kubernetes.conf > /dev/null; then
    execution_error "$ERR_FWKP"
fi

# reload after 
msg "Reloading."
execute sysctl --system

# make sure we have the needed packages installed with automated error recovery (all nodes)
msg "Installing required packages."
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

# Install kubernetes
msg "Installing Kubernetes packages."
install_package kubelet
install_package kubeadm
install_package kubectl
install_package kubectx

msg "Disabling auto-update for instaled packages."
execute apt-mark hold kubelet kubeadm kubectl kubectx # disable auto update
# set the hostname for each node
msg "Setting the node hostname."
execute hostnamectl set-hostname $HOSTNAME 
# enable kubelet
msg "Enabling Kubelet."
execute systemctl enable --now kubelet

if [ -n "$MASTER_NODE" ]; then
    # initialize the cluster (MASTER ONLY)
    if [ ! -f $KBCTLOCFG ]; then
        msg "Initializing the Cluster."
        execute kubeadm init --apiserver-advertise-address=$IP --pod-network-cidr=$CIDR
    else
        wrn "Checking for a previous CLuster."
        if ! kubeadm init --apiserver-advertise-address=$IP --pod-network-cidr=$CIDR; then
            wrn "Continuing without initializing a new Cluster."
        else
            msg "Managed to initialize the Cluster."
        fi
    fi
fi

if [ -n "$WORKER_NODE" ]; then
    # join the cluster (WORKER ONLY)
    join_master
fi

# needs to be done after the node is running.
msg "Configuring Kubectl."
configure_kubectl

if [ -n "$MASTER_NODE" ]; then
    # install Custom Resources Definitions (MASTER ONLY)
    # needs kubectl installed and configured.
    msg "Installing Custom Resources Definitions."
    download_and_apply $CRDS_REPO/$CRDS/manifests/calico.yaml crds.yaml
    msg "Generating 'join' credentials."
    generate_join_credentials
fi

msg "All done. "
exit 0