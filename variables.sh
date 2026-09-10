# Variables
NODE_NAME="" # Node resulting name (from master or worker option). Not HOSTNAME: that is bash-specific and undefined in dash.
MASTER_USER=$(echo $SUDO_USER) # master node user, defaults to current.
K_VERSIONS="" # Kubernetes versions
CRDS_VERSIONS="" # Kubernetes Custom Resources Definitions versions
K_REPO="$K_CORE:/stable:/${VERSION}/deb/" # from consts.sh and parameters.sh
KBCTLCFG="$HOME/.kube/config"
MNJCRDFS="$HOME/master_node"
INSTALL_STARTED="" # set by akinn.sh when the install phase begins; execution_error only rolls back after this.
KUBEADM_RAN="" # set right before this run calls kubeadm init/join; gates 'kubeadm reset' in rollback_files.
KBCTLCFG_CREATED="" # set when this run writes $KBCTLCFG; rollback only removes a kubeconfig we created.