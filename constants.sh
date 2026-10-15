# Configuration constants
DOCKER_REPO="https://download.docker.com/linux/ubuntu" # Docker repository
DOCKER_GPG_URL="https://download.docker.com/linux/ubuntu/gpg" # Docker GPG key url
# signed-by keyring + a list file of its own, as Docker documents it. Not
# trusted.gpg.d / add-apt-repository: a key there is trusted for EVERY repo.
DOCKER_GPG="/etc/apt/keyrings/docker.gpg"
DOCKER_LIST="/etc/apt/sources.list.d/docker.list"
APT_SOURCES="/etc/apt/sources.list /etc/apt/sources.list.d" # where an older run's Docker entry may sit
OS_RELEASE="/etc/os-release" # VERSION_CODENAME, for the Docker repository line

# FILES
FSTABF="/etc/fstab"
CCF="/etc/containerd/config.toml"
MODULES_CONF="/etc/modules-load.d/containerd.conf"
SYSCTL_CONF="/etc/sysctl.d/kubernetes.conf"

# Backups and downloads go into a fresh folder per run (start_run), never fixed
# /tmp paths: a later run that failed early used to "restore" an earlier run's
# copies of fstab, the GPG keys and containerd's config.

K_RELEASES="https://github.com/kubernetes/kubernetes/releases" # Kubernetes releases
K_CORE="https://pkgs.k8s.io/core" # Kubernetes core packages
K_LIST="/etc/apt/sources.list.d/kubernetes.list"
K_GPG="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
K_CA="/etc/kubernetes/pki/ca.crt" # the cluster CA, for the join hash

CRDS_RELEASES="https://github.com/projectcalico/calico/releases" # Kubernetes Custom Resources Definitions releases
CRDS_REPO="https://raw.githubusercontent.com/projectcalico/calico" # Kubernetes Custom Resources Definitions repository
KBCTLOCFG="/etc/kubernetes/admin.conf"
