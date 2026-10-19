# Parameters with default values
MASTER_NODE="" 	# Master node name - if installing one, need a name.
WORKER_NODE="" 	# Worker node name - if installing one, need a name.
MASTER_LOGIN="" # Path to the file with the Master node ssh password.
VERSION=v1.34 # Kubernetes default version (minor; must appear on the GitHub releases page to validate).
CRDS=v3.32.2 # Calico (Custom Resources Definitions) version; must be listed on the Calico GitHub releases page.
CIDR=10.244.0.0/16 # Classless Inter-Domain Routing blocks for Kubernetes pods.
# The address the default route leaves from - not `hostname -I`'s first entry,
# which on a host with docker, virbr or several NICs can be any of them. The
# route lookup sends nothing. hostname -I only if there is no default route.
IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')
[ -n "$IP" ] || IP=$(hostname -I 2>/dev/null | awk '{print $1}')
PORT=6443 # Worker node needs the master's port number.
TOKEN="" # Worker node needs a token to join master. 
HASH="" # Worker node needs a hash to join master. 
ARCH="$(dpkg --print-architecture)" # Architecture
UNINSTALL="" # -x: undo what akinn's installs changed.
FORCE="" # -f (with -x): best-effort cleanup of a node installed without a record.
RESET_K8S="" # -k (with -x -f): also reset that node's Kubernetes - its cluster may not be akinn's.