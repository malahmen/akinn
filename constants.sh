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
# What a worker copies from the master: the master user's own copy of
# admin.conf, which akinn put there. admin.conf itself is root's alone (0600),
# so an scp of it as that user always failed. Relative: their home, on the master.
MASTER_KBCTLCFG=".kube/config"

# UNINSTALL (-x)
AKINN_STATE="/var/lib/akinn" # each successful install's record: runs/NNNN-<time>/
# The only packages -x removes, and only those akinn installed. curl, gpg,
# sshpass & co. stay: other software may well use them by then.
K8S_PACKAGES="kubelet kubeadm kubectl kubectx containerd.io"
# What apt pulls in for those. Purged with them, and only once apt itself calls
# them orphans: an `apt-get autoremove` would take every other orphan too.
K8S_DEPENDENCIES="kubernetes-cni cri-tools"
# Folders kubeadm reset empties and leaves behind. Removed only if empty; child first.
KUBEADM_DIRS="/etc/kubernetes/pki /etc/kubernetes /var/lib/etcd"
CNI_CONF="/etc/cni/net.d" # only Calico's files in it are removed
CALICO_STATE="/var/lib/calico"
# The plugins Calico's install-cni container copies onto every node (flannel's
# included); ~190 MB that outlived -x until 2026-10-18. The folder goes too, if
# nothing else is left in it.
CNI_BIN="/opt/cni/bin"
CALICO_CNI_BINS="calico calico-ipam flannel"
# What akinn puts in front of a line it comments out in a file it shares with
# the system: -x removes exactly that, leaving any later edit in place.
SWAP_MARK="# akinn: "
DOCKER_MARK="# moved to docker.list by akinn: "
