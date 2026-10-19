#!/bin/sh

if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root. Trying with sudo..."
    # Run through sh: a fresh clone is not executable and $0 may be relative (sh akinn.sh).
    # HOME is not carried over: root's tools keep root's, and the caller's
    # files go to CALLER_HOME (variables.sh), found from SUDO_USER either way.
    exec sudo sh "$0" "$@"
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
. "$SCRIPT_DIR/protocols.sh" # loads the instalation flows for each kind of node used.
. "$SCRIPT_DIR/uninstall.sh" # loads the -x flow.

# Read parameters from command line
read_parameters "$@"

# -k needs -x -f: without a record nothing says the cluster is akinn's, so
# resetting it must be asked for; with one, -x decides from the record.
if [ -n "$RESET_K8S" ] && { [ -z "$UNINSTALL" ] || [ -z "$FORCE" ]; }; then
    execution_error "$ERR_KWXF"
fi
# -x: undo, from the install records; nothing below runs.
if [ -n "$UNINSTALL" ]; then
    uninstall
fi
if [ -n "$FORCE" ]; then
    execution_error "$ERR_FWX"
fi

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
  # validate the password file 
  validate_remote_password "$MASTER_LOGIN"
  # validate the port
  validate_port "$PORT"
  # validate the token
  validate_token "$TOKEN"  # Here $TOKEN is expected to be a path to the token file
  # validate the hash
  validate_hash "$HASH"    # Here $HASH is expected to be a path to the hash file
fi

# INSTALLING FLOW

# From here on the system is modified: failures now roll back (see execution_error).
# Every file this run changes is backed up into its own folder first, and only
# those are restored on failure; a successful run keeps it in $AKINN_STATE
# as its install record, for -x.
start_run
INSTALL_STARTED=1

# update and upgrade the system (all nodes)
refresh_packages_list
upgrade_installed_packages

# Error handling is explicit: POSIX sh has no ERR trap, so every state-changing
# command below is wrapped in `execute` / guarded with `|| execution_error`,
# which rolls back changes via rollback_files before exiting.

# disable swap - swap is bad for kubernetes (all nodes)
msg "Starting to disable swap..."
disable_swap
msg "Swap disabled successfully."

# add kernel modules to load on boot for containerd (all nodes)
msg "Adding kernel modules for containerd to be loaded on boot up."
backup_file "$MODULES_CONF"
if ! echo "overlay
br_netfilter" | tee "$MODULES_CONF" > /dev/null; then
    execution_error "$ERR_FWMLC"
fi
msg "Loading modules now."
execute modprobe overlay
execute modprobe br_netfilter

# configure kernel parameters for networking and IP forwarding related to Kubernetes (all nodes)
msg "Configuring system kernel parameters for networking and IP forwarding."
backup_file "$SYSCTL_CONF"
if ! echo "net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1" | tee "$SYSCTL_CONF" > /dev/null; then
    execution_error "$ERR_FWKP"
fi

# reload after 
msg "Reloading."
execute sysctl --system

# make sure we have the needed packages installed with automated error recovery (all nodes)
msg "Installing required packages."
install_package curl
install_package gnupg2
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
# kubectx only where the release packages it (Ubuntu 24.04 on): a hard
# requirement made every 20.04/22.04 install fail at this line.
KUBECTX_PKG=$(install_kubectx_if_packaged)

msg "Disabling auto-update for instaled packages."
# shellcheck disable=SC2086 # KUBECTX_PKG is empty or one word, on purpose unquoted
hold_packages kubelet kubeadm kubectl $KUBECTX_PKG # disable auto update
# set the hostname for each node
# NODE_NAME comes from -m/-w (validate_hostname), not from the machine.
msg "Setting the node hostname."
set_node_hostname "$NODE_NAME"
# enable kubelet
msg "Enabling Kubelet."
execute systemctl enable --now kubelet

if [ -n "$MASTER_NODE" ]; then
    # initialize the master node protocol
    master_protocol
elif [ -n "$WORKER_NODE" ]; then
    # initialize the worker node protocol
    worker_protocol   
else
    # how did we got here with the validation
    execution_error "$ERR_SE"
fi

save_run
msg "All done. "
exit 0