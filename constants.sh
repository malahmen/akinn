# Configuration constants
DOCKER_REPO="https://download.docker.com/linux/ubuntu" # Docker repository
DOCKER_GPG_URL="https://download.docker.com/linux/ubuntu/gpg" # Docker GPG key url
DOCKER_GPG_TMP="/tmp/docker.gpg"
DOCKER_GPG_BKP="/tmp/backup.docker.gpg"
DOCKER_GPG="/etc/apt/trusted.gpg.d/docker.gpg"

# FILES
FSTABF="/etc/fstab"
FSTABFB="/tmp/backup.fstab" 
CCF="/etc/containerd/config.toml"
CCFB="/tmp/backup.config.toml"

K_RELEASES="https://github.com/kubernetes/kubernetes/releases" # Kubernetes releases
K_CORE="https://pkgs.k8s.io/core" # Kubernetes core packages
K_LIST="/etc/apt/sources.list.d/kubernetes.list"
K_GPG_TMP="/tmp/kubernetes.gpg"
K_GPG_BKP=/tmp/backup.kubernetes.gpg
K_GPG="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"

CRDS_RELEASES="https://github.com/projectcalico/calico/releases" # Kubernetes Custom Resources Definitions releases
CRDS_REPO="https://raw.githubusercontent.com/projectcalico/calico" # Kubernetes Custom Resources Definitions repository
KBCTLOCFG="/etc/kubernetes/admin.conf"