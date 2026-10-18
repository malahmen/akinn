# Akinn
Automated Kubernetes Installation for New Nodes

## Description
Akinn (Automated Kubernetes Installation for New Nodes) is a tool designed to simplify the process of setting up Kubernetes clusters on new nodes, targeting Ubuntu environments, including Ubuntu Server on Raspberry Pi hardware.

It supports configurations for multiple nodes, making it ideal for scalable deployments.

> **Tested on real installs (2026-10-18)**, in VMs with one NIC each, with the
> defaults (Kubernetes v1.34, Calico v3.32.2): Ubuntu 24.04 amd64 master and
> worker, an arm64 worker joining that master, an arm64 master, and a 22.04
> amd64 master (`kubectx` skipped). Every node was then uninstalled with `-x`
> and compared with a snapshot taken before the install: only the general
> tools listed below stayed. Four bugs those runs found are fixed (the user's
> files under `sudo`, the worker's kubeconfig copy, and two `-x` leftovers).

## Requirements
- Ubuntu 18.04 LTS or newer (Ubuntu Server on a Raspberry Pi works). `kubectx` is installed where Ubuntu packages it (24.04 on) and skipped elsewhere
- amd64 or arm64 (`-a` also accepts `x86_64` and `aarch64`, and maps them)
- Raspberry Pi OS is **not supported as-is**: the Docker repository is added from `download.docker.com/linux/ubuntu` using the Ubuntu release codename, and swap is disabled by editing `/etc/fstab`, whereas Raspberry Pi OS manages swap with `dphys-swapfile`
- Internet connection
- User with sudo privileges

## Capabilities
- Automated Installation: Streamline the setup of Kubernetes on new nodes with minimal user input.
- Multi-Node Support: Easily configure and deploy master or worker nodes for Kubernetes clusters.
- Compatibility: Designed for Ubuntu systems, including Ubuntu on Raspberry Pi hardware.
- Troubleshooting: Includes error handling and logging functions for easier issue resolution.
- Security: Provides guidelines for securing Kubernetes clusters created with Akinn.

## Usage

### Installation
To install akinn, clone the repository and run the installation script:
```bash
git clone https://github.com/malahmen/akinn.git
cd akinn
chmod +x akinn.sh
./akinn.sh
```
The script must run as root; started as a regular user it re-executes itself through `sudo`. `sh akinn.sh` also works without the `chmod`.

### Setting up a Kubernetes Cluster
After installation, you can start setting up your Kubernetes cluster using the provided commands.

#### Master Node example
```bash
./akinn.sh -m <master-node-name> -n <cidr-block-string> -v <kubernetes-version> -c <crds-version>
```

#### Worker Node Example
```bash
./akinn.sh -w <worker-node-name> -i <master-node-ip> -p <master-node-port> -t <token-file-path> -h <hash-file-path> -l <master-password-file-path> -u <master-user> -v <kubernetes-version>
```
*`Token`, `Hash` and `Login` parameters **must be paths** to the files containing their values.*

## Options
 - `-m` <**MASTER_NODE**>: The master node name.
 - `-w` <**WORKER_NODE**>: The worker node name.
 - `-v` <**VERSION**>: Kubernetes version. *(optional)*
 - `-c` <**CRDS**>: Kubernetes Custom Resources Definitions version. *(optional)*
 - `-n` <**CIDR**>: Classless Inter-Domain Routing blocks for the Kubernetes pods. *(optional)*
 - `-i` <**IP**>: Master node IP address for the worker node. On the master, the advertise address; defaults to the address of the default route (not `hostname -I`'s first, which on a host with docker or several NICs can be any of them). *(optional for master)*
 - `-p` <**PORT**>: Master node port number for the worker node. *(optional)*
 - `-t` <**TOKEN**>: File path for the token Worker node uses to join the Master. *(Worker only)*
 - `-h` <**HASH**> File path for the hash Worker node uses to join the Master. *(Worker only)*
 - `-l` <**LOGIN**>: File path for the Master node SSH password; the Worker uses it to copy the kubeconfig from the Master. *(Worker only)*
 - `-u` <**MASTER_USER**>: SSH user on the Master node for that copy. Defaults to the user who ran `sudo`. *(Worker only, optional)*
 - `-a` <**ARCH**> Architecture: `amd64` or `arm64` (`x86_64`/`aarch64` are mapped). Defaults to `dpkg --print-architecture`. *(optional)*
 - `-x`: Uninstall - undo what akinn's installs changed on this node (see [Uninstalling](#uninstalling)). Takes no other option.
 - `-f`: With `-x`, on a node installed before akinn kept a record: a best-effort cleanup.

*The `master node name` **or** the `worker node name` are __required__ (except with `-x`).*

## Files
- `akinn.sh`: The main installation script.
- `regex.sh`: Regular expressions for validation purposes.
- `colors.sh`: Terminal colors to enhance the user interface.
- `parameters.sh`: Default values for parameters used in the installation process.
- `constants.sh`: Configuration constants used throughout the script.
- `variables.sh`: Variables required for the script, dependent on constants and parameters.
- `errors.sh`: Error messages and handling for better troubleshooting.
- `functions.sh`: Houses various functions used in the script for different tasks.
- `protocols.sh`: The master and worker installation flows (`master_protocol`, `worker_protocol`).
- `uninstall.sh`: The `-x` flow.

## What the script writes
Besides the packages, repositories and kernel settings it installs system-wide, the script writes:
- Every file the install changes - `/etc/fstab`, containerd's `config.toml`, the Docker and Kubernetes keyrings and repository lists, the kernel module and sysctl files - is first backed up into a folder of this run's own (`/tmp/akinn.XXXXXX`), and the change recorded. If the install fails, exactly those changes are undone, newest first, and files the run created are removed. On success the folder is kept as the install record, in `/var/lib/akinn/runs/` (root only), for `-x`. (Fixed `/tmp/backup.*` paths used to let a failed run "restore" an older run's copies.)
- Swap lines are commented out in `/etc/fstab` with a `# akinn: ` prefix, and only lines not already commented.
- The Docker repository goes to `/etc/apt/sources.list.d/docker.list`, with its key in `/etc/apt/keyrings/docker.gpg` (`signed-by`), as Docker documents it. A Docker entry an older akinn added with `add-apt-repository` is commented out (and backed up): apt refuses the two together.
- Master node: `/etc/kubernetes/admin.conf` is copied to `~/.kube/config` (owned by the user who ran `sudo`); the Calico manifest is saved as `crds.yaml` in the current directory; the join credentials are written to `~/master_node/token` and `~/master_node/hash`, the files to pass to a worker with `-t` and `-h` - readable by their owner only, and checked before they are written. **The token lasts 24 hours**; for a later join, create a new one on the master: `sudo kubeadm token create > ~/master_node/token`.
- Worker node: the Master user's `~/.kube/config` - akinn's copy of `admin.conf` there - is copied over SSH (`sshpass` + `scp`, as the `-u` user with the `-l` password) to `~/.kube/config`. Not `admin.conf` itself: it is root's alone, so copying it as that user always failed. Note that this file grants cluster-admin access to the cluster.

`~` is the home of the user who ran `sudo`, looked up from `SUDO_USER` - whether
akinn re-executed itself or you typed `sudo sh akinn.sh` (which on Ubuntu resets
`HOME` to `/root`). Run as root with no `sudo`, it is root's.

## Uninstalling
```sh
sudo sh akinn.sh -x
```
Undoes what akinn's installs changed on this node, newest first, from their
records in `/var/lib/akinn/runs/`:
- `kubeadm reset`, if akinn ran `kubeadm init`/`join` (a cluster that was there
  before is left alone), and the folders it leaves empty (`/etc/kubernetes`,
  `/var/lib/etcd`); Calico's files in `/etc/cni/net.d`, `/var/lib/calico` and
  its plugins in `/opt/cni/bin` (`calico`, `calico-ipam`, `flannel`); the
  `KUBE-*` and Calico iptables rules - every other rule (Docker's, a
  firewall's) stays, it is not a flush;
- files akinn created are removed (repository lists and keys, the kernel module
  and sysctl files, `~/.kube/config`, `crds.yaml`, `~/master_node`), files it
  replaced are put back; in `/etc/fstab` and the apt sources only akinn's
  marks are taken out, so anything edited there since stays; swap is turned
  back on, the hostname put back;
- the packages akinn held are released; of the ones it installed, `kubelet`,
  `kubeadm`, `kubectl`, `kubectx` and `containerd.io` are purged - unless apt
  would take other packages with them (Docker depends on `containerd.io`), in
  which case nothing is purged and it says what. Then what apt pulled in for
  them (`kubernetes-cni`, `cri-tools`), once apt lists it as orphaned - never a
  blanket `autoremove`. Packages that were there
  before stay. General tools akinn installed (`curl`, `gpg`, `sshpass`, ...)
  stay too, listed: other software may use them by then.

A step that fails is reported, the rest still runs, and the record is kept so
`-x` can run again. A reboot afterwards unloads the kernel modules and drops the
leftover network interfaces.

A node installed by an akinn without records refuses `-x`. `-x -f` resets the
cluster, removes the join files and Kubernetes iptables rules, releases the
holds, and lists what it cannot tell apart from your own changes (packages,
repository files, the swap lines an older akinn commented with a bare `#`, the
hostname).

### On a test machine
Single node: install a master, check it (`kubectl get nodes`, the Calico pods),
note `ls /var/lib/akinn/runs/*/`, then `sudo sh akinn.sh -x` and compare:
`/etc/fstab`, `/etc/apt/sources.list.d/`, `apt-mark showhold`, `hostname`,
`sudo iptables-save | grep -c KUBE` (0), `swapon --show`.

## Testing
```sh
sh tests/test-functions.sh
```
The functions one by one, under `sh` (dash on Ubuntu, as akinn runs): no root,
no network, nothing installed - every system command is a stub and every system
path a temporary folder. containerd's cgroup switch is checked against the real
default configurations of containerd 1.7 and 2.4 (`tests/fixtures/`); an install
record is made and `-x` run against it, with later edits to the shared files
and other tools' rules and CNI files that must survive. A full
install is not something a test can stand in for: that needs a machine.

## Contributing
Contributions are welcome! Please fork the repository and submit pull requests with your proposed changes.

## License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments
- Thanks to all contributors who have helped or will help in developing Akinn.
- Special thanks to the Kubernetes community for their documentation.