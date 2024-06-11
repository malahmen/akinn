# Parameters with default values
MASTER_NODE="" 	# Master node name - if installing one, need a name.
WORKER_NODE="" 	# Worker node name - if installing one, need a name.
MASTER_LOGIN="" # Path to the file with the Master node ssh password.
VERSION=v1.30 # Kubernetes default version.
CRDS=v3.25.2 # Kubernetes Custom Resources Definitions version.
CIDR=10.244.0.0/24 # Classless Inter-Domain Routing blocks for Kubernetes pods.
IP=$(hostname -I | awk '{print $1}')
PORT=6443 # Worker node needs the master's port number.
TOKEN="" # Worker node needs a token to join master. 
HASH="" # Worker node needs a hash to join master. 
ARCH="$(dpkg --print-architecture)" # Architecture