# Variables
NODE_NAME="" # Node resulting name (from master or worker option). Not HOSTNAME: that is bash-specific and undefined in dash.
MASTER_USER=$(echo $SUDO_USER) # master node user, defaults to current.
K_VERSIONS="" # Kubernetes versions
CRDS_VERSIONS="" # Kubernetes Custom Resources Definitions versions
K_REPO="$K_CORE:/stable:/${VERSION}/deb/" # from consts.sh and parameters.sh
# The home of the user who ran sudo, for the files that are theirs (kubeconfig,
# join files). Not $HOME: `sudo sh akinn.sh` resets it to /root on Ubuntu, and
# those files then went to /root, owned by the caller and out of their reach.
CALLER_HOME="$HOME"
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != root ]; then
    CALLER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    [ -n "$CALLER_HOME" ] || CALLER_HOME="$HOME"
fi
KBCTLCFG="$CALLER_HOME/.kube/config"
MNJCRDFS="$CALLER_HOME/master_node"
INSTALL_STARTED="" # set by akinn.sh when the install phase begins; execution_error only rolls back after this.
KUBEADM_RAN="" # set right before this run calls kubeadm init/join; gates 'kubeadm reset' in rollback_files.
KBCTLCFG_CREATED="" # set when this run writes $KBCTLCFG; rollback only removes a kubeconfig we created.
RUN_DIR="" # this run's folder for backups and downloads (start_run); removed on success.
DOCKER_GPG_TMP="" # set by start_run, inside RUN_DIR
K_GPG_TMP="" # set by start_run, inside RUN_DIR