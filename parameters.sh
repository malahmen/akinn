# Parameters with default values
HOSTNAME="" # Node reulting name (from master or worker option).
MASTER_NODE="" 	# Master node name - if installing one, need a name.
WORKER_NODE="" 	# Worker node name - if installing one, need a name.
VERSION="v1.30.0" # Kubernetes default version.
CRDS="v3.25.2"  # Kubernetes Custom Resources Definitions version.
CIDR="10.244.0.0/24" # Classless Inter-Domain Routing blocks for Kubernetes pods.
IP=$(ip addr show $(ip route | grep default | awk '{print $5}') | grep -oP $re_device_ip_line | grep -oP $re_ip_numbers | grep -v 255$)
PORT="6443" # Worker node needs the master's port number.
TOKEN="" # Worker node needs a token to join master. 
HASH="" # Worker node needs a hash to join master. 
ARCH="$(dpkg --print-architecture)" # Architecture