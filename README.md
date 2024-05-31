# Akinn
Automated Kubernetes Installation for New Nodes

## Description
Akinn (Automated Kubernetes Installation for New Nodes) is a tool designed to simplify the process of setting up Kubernetes clusters on new nodes, specifically targeting Ubuntu and Raspberry Pi environments.

It supports configurations for multiple nodes, making it ideal for scalable deployments.

## Features
- **Automated Installation**: Streamline the setup of Kubernetes on new nodes with minimal manual intervention.
- **Multi-Node Support**: Easily configure and deploy multi-node Kubernetes clusters.
- **Compatibility**: Designed specifically for Ubuntu and Raspberry Pi systems.

## Requirements
- Ubuntu 18.04 LTS or newer / Raspberry Pi OS
- Internet connection
- User with sudo privileges

## Installation
To install akinn, clone the repository and run the installation script:
```bash
git clone https://github.com/akinn/akinn.git
cd akinn
chmod +x akinn.sh
./akinn.sh
```

## Usage
After installation, you can start setting up your Kubernetes cluster:
```bash
./akinn.sh -m <master-node-ip> -n <node-ip> -i <interface> -p <password> -t <token> -h <hostname> -a <architecture>
```

## Contributing
Contributions are welcome! Please fork the repository and submit pull requests with your proposed changes.

## License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments
- Thanks to all contributors who have helped or will help in developing Akinn.
- Special thanks to the Kubernetes community for their documentation.