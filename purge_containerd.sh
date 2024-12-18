#!/bin/bash

# This script removes containerd and its associated files

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Stop and disable containerd service
if systemctl is-active --quiet containerd; then
    echo "Stopping containerd service..."
    sudo systemctl stop containerd
fi

if systemctl is-enabled --quiet containerd; then
    echo "Disabling containerd service..."
    sudo systemctl disable containerd
fi

# Remove containerd binary and package if installed via package manager
if command_exists apt; then
    echo "Removing containerd using apt..."
    sudo apt remove -y containerd
    sudo apt purge -y containerd
elif command_exists yum; then
    echo "Removing containerd using yum..."
    sudo yum remove -y containerd
elif command_exists dnf; then
    echo "Removing containerd using dnf..."
    sudo dnf remove -y containerd
else
    echo "No compatible package manager found. Skipping package removal."
fi

# Remove containerd directories, configuration files, and sockets
CONTAINERD_PATHS=(
    "/etc/containerd"
    "/var/lib/containerd"
    "/usr/local/bin/containerd"
    "/usr/local/bin/containerd-shim*"
    "/usr/local/bin/ctr"
    "/run/containerd"
    "/run/containerd/containerd.sock"
    "/run/containerd/containerd.sock.lock"
)

echo "Removing containerd-related files, directories, and sockets..."
for path in "${CONTAINERD_PATHS[@]}"; do
    if [ -e "$path" ]; then
        echo "Removing $path..."
        sudo rm -rf "$path"
    fi
done

# Reload system daemon to clean up lingering service definitions
if command_exists systemctl; then
    echo "Reloading system daemon..."
    sudo systemctl daemon-reload
fi

# Final cleanup
if command_exists apt; then
    echo "Running apt autoremove and clean..."
    sudo apt autoremove -y
    sudo apt clean
elif command_exists yum || command_exists dnf; then
    echo "Running clean-up for yum/dnf..."
    sudo yum clean all || sudo dnf clean all
fi

echo "Containerd has been successfully removed."

