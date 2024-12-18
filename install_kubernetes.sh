#!/bin/bash

set -e  # Exit on error

# Usage message
usage() {
  echo "Usage: $0 [--role control-plane|node] [--control-plane-ip <IP>] [--token <TOKEN>] [--hash <HASH>]"
  echo "--role               Specify the role: 'control-plane' or 'node'."
  echo "--control-plane-ip  The IP address of the control plane (required for nodes)."
  echo "--token             The join token for the cluster (required for nodes)."
  echo "--hash              The discovery-token-ca-cert-hash (required for nodes)."
  exit 1
}

# Parse arguments
ROLE=""
CONTROL_PLANE_IP=""
TOKEN=""
HASH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)
      ROLE="$2"
      shift 2
      ;;
    --control-plane-ip)
      CONTROL_PLANE_IP="$2"
      shift 2
      ;;
    --token)
      TOKEN="$2"
      shift 2
      ;;
    --hash)
      HASH="$2"
      shift 2
      ;;
    *)
      echo "Unknown parameter: $1"
      usage
      ;;
  esac
done

# Validate arguments
if [[ -z "$ROLE" ]]; then
  echo "Error: --role is required."
  usage
fi

if [[ "$ROLE" == "node" && ( -z "$CONTROL_PLANE_IP" || -z "$TOKEN" || -z "$HASH" ) ]]; then
  echo "Error: --control-plane-ip, --token, and --hash are required for role 'node'."
  usage
fi

# Check for existing Kubernetes installation
echo "==> Checking for existing Kubernetes installation..."
EXISTING_PACKAGES=$(dpkg -l | grep -E 'kubelet|kubeadm|kubectl' | awk '{print $2}')
if [[ ! -z "$EXISTING_PACKAGES" ]]; then
  echo "Found existing Kubernetes packages: $EXISTING_PACKAGES"
  echo "==> Attempting to gracefully shut down existing Kubernetes services..."
  if systemctl is-active --quiet kubelet; then
    echo "Draining the node to evict all pods..."
    kubectl drain $(hostname) --ignore-daemonsets --delete-emptydir-data || echo "Failed to drain node. Continuing..."

    echo "Stopping kubelet service..."
    sudo systemctl stop kubelet
  fi

  echo "Removing existing Kubernetes packages..."
  sudo apt-get remove --purge -y --allow-change-held-packages $EXISTING_PACKAGES
  sudo apt-get autoremove -y
  echo "==> Attempting to gracefully release Kubernetes mounts..."
  if systemctl is-active --quiet kubelet; then
    echo "==> Draining the node to evict all pods..."
    kubectl drain $(hostname) --ignore-daemonsets --delete-emptydir-data || echo "Failed to drain node. Continuing..."

    echo "==> Stopping kubelet service..."
    sudo systemctl stop kubelet
  fi

  echo "==> Attempting to remove directories..."
  sudo rm -rf /etc/kubernetes /var/lib/kubelet /etc/cni /var/lib/etcd || {
    echo "==> Graceful removal failed. Forcing unmount and cleanup..."
    sudo umount -l /var/lib/kubelet/* || echo "No volumes to unmount."
    sudo rm -rf /etc/kubernetes /var/lib/kubelet /etc/cni /var/lib/etcd
  }
  echo "Existing Kubernetes installation removed."
else
  echo "No existing Kubernetes installation found."
fi

# Common steps
echo "==> Updating and installing dependencies..."
sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

echo "==> Configuring Kubernetes repository..."
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | \
  sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

if [[ "$ROLE" == "control-plane" ]]; then
  MAKE_WORKER=true
  echo "==> Checking for active services using port 6443..."
  if sudo ss -tuln | grep -q ':6443'; then
    echo "Port 6443 is in use. Attempting to stop conflicting services..."
    if systemctl is-active --quiet kubelet; then
      echo "Stopping kubelet service..."
      sudo systemctl stop kubelet
    fi

    echo "Killing processes using port 6443..."
    sudo lsof -i :6443 | awk 'NR>1 {print $2}' | xargs sudo kill -9 || echo "No processes to kill."

    echo "Verifying port availability..."
    if sudo ss -tuln | grep -q ':6443'; then
      echo "Port 6443 is still in use. Aborting initialization."
      exit 1
    fi
  fi

  echo "==> Initializing control plane..."
  POD_NETWORK_CIDR="10.244.0.0/16"  # Default pod network CIDR

  sudo kubeadm init --pod-network-cidr=$POD_NETWORK_CIDR --cri-socket=unix:///var/run/cri-dockerd.sock

  echo "==> Configuring kubectl for the current user..."
  mkdir -p $HOME/.kube
  sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

  echo "==> Installing Calico network plugin..."
  kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml

  echo "==> Control plane setup is complete. Save the join command below for worker nodes."

  if [[ "$MAKE_WORKER" == "true" ]]; then
    echo "==> Configuring control plane as a worker node..."
    sudo kubeadm join 127.0.0.1:6443 --token $(kubeadm token list | tail -n 1 | awk '{print $1}') \
      --discovery-token-ca-cert-hash $(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
      openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary | xxd -p -c 256)
  fi
  kubeadm token create --print-join-command | tee $HOME/kubeadm_join_command.txt

elif [[ "$ROLE" == "node" ]]; then
  echo "==> Joining the cluster as a worker node..."
  sudo kubeadm join $CONTROL_PLANE_IP:6443 --token $TOKEN \
    --discovery-token-ca-cert-hash $HASH

  echo "==> Node setup is complete."
else
  echo "Error: Invalid role specified. Use 'control-plane' or 'node'."
  usage
fi

