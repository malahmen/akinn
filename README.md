# Akinn
Automated Kubernetes Installation for New Nodes

## Description
Akinn (Automated Kubernetes Installation for New Nodes) is a tool designed to simplify the process of setting up Kubernetes clusters on new nodes, targeting Ubuntu environments, including Ubuntu Server on Raspberry Pi hardware.

It supports configurations for multiple nodes, making it ideal for scalable deployments.

## Requirements
- Ubuntu 18.04 LTS or newer (Ubuntu Server on a Raspberry Pi works)
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
 - `-i` <**IP**>: Master node IP address for the worker node. *(optional for master)*
 - `-p` <**PORT**>: Master node port number for the worker node. *(optional)*
 - `-t` <**TOKEN**>: File path for the token Worker node uses to join the Master. *(Worker only)*
 - `-h` <**HASH**> File path for the hash Worker node uses to join the Master. *(Worker only)*
 - `-l` <**LOGIN**>: File path for the Master node SSH password; the Worker uses it to copy the kubeconfig from the Master. *(Worker only)*
 - `-u` <**MASTER_USER**>: SSH user on the Master node for that copy. Defaults to the user who ran `sudo`. *(Worker only, optional)*
 - `-a` <**ARCH**> Architecture used. *(optional)*

*The `master node name` **or** the `worker node name` are __required__.*

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

## What the script writes
Besides the packages, repositories and kernel settings it installs system-wide, the script writes:
- `/etc/fstab`, `/etc/containerd/config.toml` and the Docker/Kubernetes GPG keyrings are backed up to `/tmp/backup.*` before being changed, and restored if the install fails.
- Master node: `/etc/kubernetes/admin.conf` is copied to `~/.kube/config` (owned by the user who ran `sudo`); the Calico manifest is saved as `crds.yaml` in the current directory; the join credentials are written to `~/master_node/token` and `~/master_node/hash`, the files to pass to a worker with `-t` and `-h`.
- Worker node: the Master's `/etc/kubernetes/admin.conf` is copied over SSH (`sshpass` + `scp`, using `-l`/`-u`) to `~/.kube/config`. Note that this file grants cluster-admin access to the cluster.

`~` is the home of the user who ran `sudo` (`HOME` is preserved across the re-execution).

## Contributing
Contributions are welcome! Please fork the repository and submit pull requests with your proposed changes.

## License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments
- Thanks to all contributors who have helped or will help in developing Akinn.
- Special thanks to the Kubernetes community for their documentation.