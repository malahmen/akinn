# Variables
HOSTNAME="" # Node reulting name (from master or worker option).
MASTER_USER=$(echo $SUDO_USER) # master node user, defaults to current.
K_VERSIONS="" # Kubernetes versions
CRDS_VERSIONS="" # Kubernetes Custom Resources Definitions versions
K_REPO="$K_CORE:/stable:/${VERSION}/deb/" # from consts.sh and parameters.sh
KBCTLCFG="$HOME/.kube/config"
MNJCRDFS="$HOME/master_node"