#!/bin/bash

# --- 1. PRE-FLIGHT AUDIT ---
# Identify the current environment and user privileges.
CURRENT_USER=$(whoami)
echo "Current user: $CURRENT_USER"

# Ensure the script is run with sudo privileges.
if [ "$EUID" -ne 0 ]; then
  if ! sudo -n true 2>/dev/null; then
    echo "Error: This script requires sudo privileges."
    exit 1
  fi
fi


# --- 1.5 SECURITY AUDIT: Check Open Ports & Sensitive Files ---
echo "Auditing open ports..."
# netstat or ss shows what services are currently listening
if command -v ss &> /dev/null; then
    sudo ss -tulpn | grep LISTEN
else
    sudo netstat -tulpn | grep LISTEN
fi

echo "Checking for sensitive exposed directories..."
# Checking for common DevOps leaks like .git or .env files
SENSITIVE_DIRS=(".git" ".env" ".aws" ".ssh")
for dir in "${SENSITIVE_DIRS[@]}"; do
    if [ -d "$HOME/$dir" ] || [ -f "$HOME/$dir" ]; then
        echo "WARNING: Sensitive item found: $HOME/$dir - Ensure this is not publicly accessible!"
    fi
done

# --- 2. PREPARATION: Update System and Install Essentials ---
# Standard procedure for a fresh server or maintenance.
echo "Updating system and installing essential tools..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y fail2ban ufw unattended-upgrades curl git tmux htop ccze

# --- 3. INTERACTIVE SSH HARDENING ---
# As seen in your logs, bots constantly target port 22.
# We offer a prompt to decide on security through obscurity.
SSH_CONFIG="/etc/ssh/sshd_config"
echo "------------------------------------------------"
read -p "Do you want to change the default SSH port (22)? [y/N]: " change_ssh
if [[ "$change_ssh" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    read -p "Enter new SSH port (e.g., 2234): " NEW_PORT
    echo "Changing SSH Port to $NEW_PORT..."
    sudo sed -i "s/^#Port 22/Port $NEW_PORT/" "$SSH_CONFIG"
    sudo sed -i "s/^Port 22/Port $NEW_PORT/" "$SSH_CONFIG"
    sudo ufw allow "$NEW_PORT"/tcp
    SSH_MSG="Connect using: ssh -p $NEW_PORT $CURRENT_USER@your_ip"
else
    echo "Keeping default SSH port 22."
    sudo ufw allow 22/tcp
    SSH_MSG="Connect using: ssh $CURRENT_USER@your_ip"
fi

# Apply SSH changes
sudo systemctl restart ssh

# --- 4. FIREWALL CONFIGURATION (UFW) ---
echo "Configuring Firewall..."
sudo ufw allow 80/tcp      # Standard HTTP
sudo ufw allow 443/tcp     # Standard HTTPS
sudo ufw --force enable

# --- 5. DOCKER LOG MANAGEMENT ---
# Prevents disk exhaustion—a common cause of server failure.
if command -v docker &> /dev/null; then
    echo "Configuring Docker log limits..."
    echo '{
      "log-driver": "json-file",
      "log-opts": {
        "max-size": "10m",
        "max-file": "3"
      }
    }' | sudo tee /etc/docker/daemon.json
    sudo systemctl restart docker
fi

# --- 6. LOG MAINTENANCE ---
# Ensures Logrotate manages system log growth.
echo "Ensuring Logrotate is active..."
sudo systemctl enable logrotate

echo "------------------------------------------------"
echo "--- INITIAL HARDENING COMPLETE ---"
echo "$SSH_MSG"
echo "------------------------------------------------"
