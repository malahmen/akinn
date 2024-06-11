
master_protocol() {
    # initialize the cluster
    if [ ! -f $KBCTLOCFG ]; then
        msg "Initializing the Master node."
        execute kubeadm init --apiserver-advertise-address=$IP --pod-network-cidr=$CIDR
    else
        wrn "Checking for a previous node."
        if ! kubeadm init --apiserver-advertise-address=$IP --pod-network-cidr=$CIDR; then
            wrn "Continuing without initializing a new node."
        else
            msg "Managed to initialize the node."
        fi
    fi

    msg "Configuring Kubectl."
    configure_kubectl

    # install Custom Resources Definitions (MASTER ONLY)
    # needs kubectl installed and configured.
    msg "Installing Custom Resources Definitions."
    download_and_apply $CRDS_REPO/$CRDS/manifests/calico.yaml crds.yaml
    
    msg "Generating 'join' credentials."
    generate_join_credentials
    
    exit 0
}

worker_protocol() {
    # join the master node.
    join_master

    # we need to fetch the configuration from the master node.
    msg "Configuring Kubectl."
    configure_kubectl
    
    exit 0
}