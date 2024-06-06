# Akinn
Automated Kubernetes Installation for New Nodes

## Description
Akinn (Automated Kubernetes Installation for New Nodes) is a tool designed to simplify the process of setting up Kubernetes clusters on new nodes, specifically targeting Ubuntu and Raspberry Pi environments.

It supports configurations for multiple nodes, making it ideal for scalable deployments.

## Requirements
- Ubuntu 18.04 LTS or newer / Raspberry Pi OS
- Internet connection
- User with sudo privileges

## Capabilities
- Automated Installation: Streamline the setup of Kubernetes on new nodes with minimal user input.
- Multi-Node Support: Easily configure and deploy master or worker nodes for Kubernetes clusters.
- Compatibility: Designed specifically for Ubuntu and Raspberry Pi systems.
- Troubleshooting: Includes error handling and logging functions for easier issue resolution.
- Security: Provides guidelines for securing Kubernetes clusters created with Akinn.

## Usage

### Installation
To install akinn, clone the repository and run the installation script:
```bash
git clone https://github.com/akinn/akinn.git
cd akinn
chmod +x akinn.sh
./akinn.sh
```

### Setting up a Kubernetes Cluster
After installation, you can start setting up your Kubernetes cluster using the provided commands.

#### Master Node example
```bash
./akinn.sh -m <master-node-name> -n <cidr-block-string> -v <kubernetes-version> -c <cdrs-version>
```

#### Worker Node Example
```bash
./akinn.sh -w <worker-node-name> -i <master-node-ip> -p <master-node-port> -t <token-file-path> -h <hash-file-path> -v <kubernetes-version>
```
*`Token` and `Hash` parameters **must be paths** to the files containing their values.*

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

## Contributing
Contributions are welcome! Please fork the repository and submit pull requests with your proposed changes.

## License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments
- Thanks to all contributors who have helped or will help in developing Akinn.
- Special thanks to the Kubernetes community for their documentation.