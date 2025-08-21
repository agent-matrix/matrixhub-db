#!/bin/bash

# This script is designed to optimize a free-tier Oracle Linux instance
# for better performance and usability, especially for development tasks.
# It includes adding swap space, cleaning DNF cache, and optionally
# disabling some non-essential services to free up resources.

# IMPORTANT:
# - Run this script as a user with sudo privileges.
# - Always back up important data before making significant system changes.
# - Review each section and uncomment/modify lines as needed for your specific use case.
# - Disabling services can affect system functionality. Proceed with caution.

echo "Starting Oracle Linux Free Tier Optimization Script..."

# --- Section 1: Memory Optimization (Swap Space) ---
echo -e "\n--- Configuring Swap Space ---"
# Check if swap file already exists to prevent re-creation
if [ ! -f /swapfile ]; then
    echo "Creating a 2GB swap file..."
    # 'fallocate' is faster than 'dd' for creating sparse files
    sudo fallocate -l 2G /swapfile
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create swap file with fallocate. Trying dd..."
        sudo dd if=/dev/zero of=/swapfile bs=1M count=2048
        if [ $? -ne 0 ]; then
            echo "Error: Failed to create swap file. Aborting swap configuration."
        else
            echo "Swap file created successfully with dd."
            sudo chmod 600 /swapfile          # Set correct permissions
            sudo mkswap /swapfile             # Set up the swap area
            sudo swapon /swapfile             # Enable the swap file
            # Make the swap file permanent across reboots by adding it to /etc/fstab
            # Check if the entry already exists before adding
            if ! grep -q "/swapfile none swap sw 0 0" /etc/fstab; then
                echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
                echo "Swap file entry added to /etc/fstab."
            else
                echo "Swap file entry already exists in /etc/fstab."
            fi
            echo "Swap space activated and configured to persist on reboot."
            echo "Current swap status:"
            free -h
        fi
    else
        echo "Swap file created successfully with fallocate."
        sudo chmod 600 /swapfile          # Set correct permissions
        sudo mkswap /swapfile             # Set up the swap area
        sudo swapon /swapfile             # Enable the swap file
        # Make the swap file permanent across reboots by adding it to /etc/fstab
        if ! grep -q "/swapfile none swap sw 0 0" /etc/fstab; then
            echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
            echo "Swap file entry added to /etc/fstab."
        else
            echo "Swap file entry already exists in /etc/fstab."
        fi
        echo "Swap space activated and configured to persist on reboot."
        echo "Current swap status:"
        free -h
    fi
else
    echo "Swap file already exists. Checking if it's enabled..."
    if ! swapon --show | grep -q "/swapfile"; then
        echo "Swap file exists but is not enabled. Enabling it now."
        sudo swapon /swapfile
        echo "Swap file enabled."
        echo "Current swap status:"
        free -h
    else
        echo "Swap file exists and is enabled."
    fi
fi

# Adjust swappiness (how often the system swaps) and vfs_cache_pressure (filesystem cache pressure)
# Lower swappiness (e.g., 10) means the kernel will try to avoid swapping processes out of physical memory for as long as possible.
# Lower vfs_cache_pressure (e.g., 50) makes the kernel less aggressive in reclaiming memory used for directory and inode caches.
echo "Adjusting swappiness and vfs_cache_pressure..."
echo 'vm.swappiness = 10' | sudo tee -a /etc/sysctl.d/99-custom-performance.conf
echo 'vm.vfs_cache_pressure = 50' | sudo tee -a /etc/sysctl.d/99-custom-performance.conf
sudo sysctl -p /etc/sysctl.d/99-custom-performance.conf
echo "Swappiness and vfs_cache_pressure adjusted."

# --- Section 2: DNF Package Manager Optimization ---
echo -e "\n--- Optimizing DNF Package Manager ---"
echo "Cleaning DNF cache to resolve potential issues and refresh metadata..."
sudo dnf clean all
echo "DNF cache cleaned."

# Optional: Disable fast mirror plugin if DNF is still slow (sometimes causes issues)
# This can sometimes help if mirror selection is causing delays.
# echo "Disabling DNF fastest mirror plugin (uncomment to enable)..."
# sudo sed -i 's/fastestmirror=1/fastestmirror=0/' /etc/dnf/dnfrpms.conf || sudo sed -i 's/fastestmirror=1/fastestmirror=0/' /etc/dnf/dnf.conf


# --- Section 3: System Updates ---
echo -e "\n--- Performing System Updates ---"
echo "Updating all installed packages to their latest versions. This may take some time."
sudo dnf update -y
if [ $? -eq 0 ]; then
    echo "System packages updated successfully."
else
    echo "Warning: DNF update encountered errors. Please check the output above for details."
fi

# --- Section 4: Optional Service Disabling (Use with caution!) ---
echo -e "\n--- Optional: Disabling Non-Essential Services ---"
echo "Review the services below and uncomment 'sudo systemctl disable --now <service_name>' if you are sure you don't need them."
echo "Disabling services can free up RAM and CPU cycles, but may impact functionality."

# Example services you might consider disabling on a minimal server:
# If you don't use cockpit for web-based server management
# sudo systemctl disable --now cockpit.socket

# If you don't use firewalld and prefer managing iptables directly, or are sure your network security is handled externally
# However, firewalld is generally recommended for security. Disable with extreme caution!
# sudo systemctl disable --now firewalld

# If you don't use avahi-daemon (Bonjour/Zeroconf for network service discovery)
# sudo systemctl disable --now avahi-daemon

# If you don't use ModemManager (for mobile broadband devices)
# sudo systemctl disable --now ModemManager

# If you don't use NetworkManager-wait-online (waits for network to be online before other services start)
# This can sometimes speed up boot, but might cause issues if services depend on network at boot
# sudo systemctl disable --now NetworkManager-wait-online.service

# List of common services and their status (for your review)
echo "Current status of some common services:"
systemctl is-active cockpit.socket || echo "cockpit.socket: inactive or not found"
systemctl is-active firewalld || echo "firewalld: inactive or not found"
systemctl is-active avahi-daemon || echo "avahi-daemon: inactive or not found"
systemctl is-active ModemManager || echo "ModemManager: inactive or not found"
systemctl is-active NetworkManager-wait-online.service || echo "NetworkManager-wait-online.service: inactive or not found"

echo "To disable a service, uncomment the corresponding line in the script and run it again, e.g.:"
echo "# sudo systemctl disable --now cockpit.socket"


# --- Section 5: Basic Firewall Setup (Highly Recommended) ---
# This is a basic setup. Adjust rules as per your application's needs.
echo -e "\n--- Configuring Firewall (Firewalld) ---"
if ! systemctl is-active firewalld &>/dev/null; then
    echo "Firewalld is not active. Enabling and starting it now."
    sudo systemctl enable --now firewalld
    if [ $? -eq 0 ]; then
        echo "Firewalld enabled and started."
    else
        echo "Error: Failed to enable/start firewalld. Please check system logs."
    fi
else
    echo "Firewalld is already active."
fi

echo "Adding common services to firewall (SSH, HTTP, HTTPS)..."
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
# Reload firewalld to apply changes
sudo firewall-cmd --reload
echo "Firewall rules updated. SSH, HTTP, HTTPS ports are open."
echo "Current firewall status (public zone services):"
sudo firewall-cmd --list-services


# --- Section 6: Post-Optimization Recommendations ---
echo -e "\n--- Optimization Script Finished ---"
echo "Your Oracle Linux instance has been optimized!"
echo "It is highly recommended to **reboot** your instance now for all changes to take full effect, especially the swap and sysctl settings."
echo "You can do this by running: sudo reboot"
echo "After reboot, verify the swap space again with 'free -h'."
echo "Consider installing only the software you truly need to conserve resources."
echo "For more advanced performance tuning, explore CPU pinning and resource limits if using OCI's management tools."
