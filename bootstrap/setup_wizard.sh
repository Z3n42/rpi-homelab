#!/bin/bash

# ==============================================================================
#  RPI 5 HOMELAB - MASTER SETUP WIZARD (AUTO-PILOT EDITION)
#  Includes: Boot Checks, K3s, Helm, SOPS, Age, and Auto-GitOps Setup
# ==============================================================================

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'
YELLOW='\033[1;33m'

# Check Root
if [ "$EUID" -ne 0 ]; then 
  echo -e "${RED}Please run as root (sudo ./setup_wizard.sh)${NC}"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT" || { echo -e "${RED}Error: Could not change to repo root.${NC}"; exit 1; }

REAL_USER=${SUDO_USER:-$(whoami)}
REAL_HOME=$(getent passwd $REAL_USER | cut -d: -f6)

echo -e "${BLUE}=================================================${NC}"
echo -e "${BLUE}   🚀 RPI 5 HOMELAB SETUP WIZARD                 ${NC}"
echo -e "${BLUE}      User detected: $REAL_USER ($REAL_HOME)     ${NC}"
echo -e "${BLUE}      Working Dir: $(pwd)                        ${NC}"
echo -e "${BLUE}=================================================${NC}"

# ------------------------------------------------------------------------------
# PHASE 0: PRE-FLIGHT CHECKS (BOOT CONFIG)
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}--> [0/5] Checking System Configuration...${NC}"

# 1. CGROUPS CHECK (Crucial for K3s on RPi)
CMDLINE_PATH=""
if [ -f /boot/firmware/cmdline.txt ]; then CMDLINE_PATH="/boot/firmware/cmdline.txt"; 
elif [ -f /boot/cmdline.txt ]; then CMDLINE_PATH="/boot/cmdline.txt"; fi

if [ ! -z "$CMDLINE_PATH" ]; then
    if ! grep -q "cgroup_memory=1" "$CMDLINE_PATH"; then
        echo -e "    - ${RED}Cgroups missing! Fixing automatically...${NC}"
        cp "$CMDLINE_PATH" "$CMDLINE_PATH.bak"
        sed -i 's/$/ cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory/' "$CMDLINE_PATH"
        
        echo -e "${RED}⚠️  SYSTEM REBOOT REQUIRED to apply kernel changes.${NC}"
        echo -e "${RED}Rebooting in 10 seconds... Please run this script again after reboot!${NC}"
        sleep 10
        reboot
        exit 0
    else
        echo "    - Boot config (cgroups) is OK."
    fi
else
    echo "⚠️  Warning: Could not find cmdline.txt. Skipping cgroup check."
fi

# ------------------------------------------------------------------------------
# PHASE 1: INSTALL DEPENDENCIES
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}--> [1/5] Installing System Dependencies...${NC}"
apt update -qq && apt install -y curl wget git htop vim open-iscsi nfs-common age jq > /dev/null

# Install K3s (Lightweight Kubernetes)
if ! command -v k3s &> /dev/null; then
    echo "    - Installing K3s..."
    curl -sfL https://get.k3s.io | sh -
    mkdir -p $REAL_HOME/.kube
    cp /etc/rancher/k3s/k3s.yaml $REAL_HOME/.kube/config
    chown $REAL_USER:$REAL_USER $REAL_HOME/.kube/config
    chmod 600 $REAL_HOME/.kube/config
    echo "export KUBECONFIG=$REAL_HOME/.kube/config" >> $REAL_HOME/.bashrc
else
    echo "    - K3s already installed."
fi

# Install Helm (Package Manager)
if ! command -v helm &> /dev/null; then
    echo "    - Installing Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    # Install Secrets Plugin as user
    sudo -u $REAL_USER helm plugin install https://github.com/jkroepke/helm-secrets > /dev/null 2>&1
fi

# Install Helmfile & SOPS (Declarative Deployments)
if ! command -v helmfile &> /dev/null; then
    echo "    - Installing Helmfile..."
    # Hardcoded version for stability, consider fetching latest API
    curl -sSfL https://github.com/helmfile/helmfile/releases/download/v0.169.1/helmfile_0.169.1_linux_arm64.tar.gz | tar xz
    mv helmfile /usr/local/bin/
fi

if ! command -v sops &> /dev/null; then
    echo "    - Installing SOPS..."
    curl -sSfL https://github.com/getsops/sops/releases/download/v3.9.0/sops-v3.9.0.linux.arm64 > sops
    chmod +x sops && mv sops /usr/local/bin/
fi

# ------------------------------------------------------------------------------
# PHASE 2: SECURITY SETUP (AGE KEY)
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}--> [2/5] configuring Encryption Keys...${NC}"
mkdir -p $REAL_HOME/.config/age
KEY_FILE="$REAL_HOME/.config/age/key.txt"

if [ ! -f "$KEY_FILE" ]; then
    echo -e "${RED}❌ AGE KEY NOT FOUND in $KEY_FILE${NC}"
    echo "Please copy your key.txt from your PC to this Raspberry Pi first."
    echo "Run: scp ~/.config/age/key.txt pi@<RPI_IP>:~/.config/age/"
    exit 1
else
    echo "    - Age key found."
    chown $REAL_USER:$REAL_USER $KEY_FILE
    chmod 600 $KEY_FILE
fi

if ! grep -q "SOPS_AGE_KEY_FILE" "$REAL_HOME/.bashrc"; then
    echo "    - Adding env var to .bashrc..."
    echo "export SOPS_AGE_KEY_FILE=$KEY_FILE" >> "$REAL_HOME/.bashrc"
fi

# ------------------------------------------------------------------------------
# PHASE 3: DEPLOYMENT MODE
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}=================================================${NC}"
echo -e "${BLUE}   CHOOSE DEPLOYMENT MODE                        ${NC}"
echo -e "${BLUE}=================================================${NC}"
echo "1) LOCAL DEPLOY (Safe to run anytime - Updates apps instantly)"
echo -e "2) GITOPS RUNNER ${YELLOW}(WARNING: REINSTALLS RUNNER! Requires new GitHub Token)${NC}"
echo ""
read -p "Select option [1 or 2]: " MODE

if [ "$MODE" == "1" ]; then
    # --- OPTION 1: LOCAL ---
    echo -e "\n${GREEN}--> [Local Mode] Applying Helmfile...${NC}"
    export SOPS_AGE_KEY_FILE=$KEY_FILE
    
    # Check if we have secrets
    if [ ! -f "secrets/app.sops.yaml" ]; then
        echo -e "${RED}Error: secrets/app.sops.yaml not found. Did you clone the repo?${NC}"
        echo "Current dir: $(pwd)"
        exit 1
    fi

    echo -e "\n${GREEN}--> 🚀 Deploying...${NC}"
    helmfile apply
    echo -e "${GREEN}✅ Done! Check your services.${NC}"

elif [ "$MODE" == "2" ]; then
    # --- OPTION 2: GITOPS RUNNER ---
    echo -e "\n${GREEN}--> [GitOps Mode] Setting up GitHub Runner...${NC}"
    echo -e "${YELLOW}⚠️  This will REMOVE any existing runner configuration.${NC}"
    echo "Need RUNNER TOKEN from: Repo Settings -> Actions -> Runners -> New Self-Hosted Runner"
    echo ""
    read -p "🔹 GitHub Repo URL: " REPO_URL
    read -p "🔹 Runner Registration Token: " RUNNER_TOKEN

    RUNNER_DIR="$REAL_HOME/actions-runner"
    
    # 1. Clean URL (Remove .git suffix if present)
    CLEAN_URL=${REPO_URL%.git}

    # 2. Prepare Directory
    if [ -d "$RUNNER_DIR" ]; then
        echo "    - Cleaning previous runner installation..."
        sudo ./svc.sh uninstall > /dev/null 2>&1
        rm -rf "$RUNNER_DIR"
    fi
    sudo -u $REAL_USER mkdir -p $RUNNER_DIR
    cd $RUNNER_DIR

    # 3. Download Latest Runner (Dynamic Version Fetch)
    echo "    - Fetching latest runner version..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/v//')
    echo "    - Downloading Runner v$LATEST_VERSION..."
    sudo -u $REAL_USER curl -o actions-runner.tar.gz -L "https://github.com/actions/runner/releases/download/v${LATEST_VERSION}/actions-runner-linux-arm64-${LATEST_VERSION}.tar.gz"
    sudo -u $REAL_USER tar xzf actions-runner.tar.gz

    # 4. Configure
    echo "    - Registering Runner..."
    sudo -u $REAL_USER ./config.sh --url $CLEAN_URL --token $RUNNER_TOKEN --unattended --name "$(hostname)" --replace

    # 5. Inject Environment (CRITICAL)
    echo "    - Injecting Secrets..."
    echo "KUBECONFIG=$REAL_HOME/.kube/config" | sudo -u $REAL_USER tee -a .env > /dev/null
    echo "SOPS_AGE_KEY_FILE=$KEY_FILE" | sudo -u $REAL_USER tee -a .env > /dev/null

    # 6. Install Service
    echo "    - Installing Service..."
    sudo ./svc.sh install $REAL_USER
    sudo ./svc.sh start

    echo -e "\n${GREEN}✅ SUCCESS! Your Raspberry Pi is now a GitOps Worker.${NC}"
else
    echo "Invalid option."
    exit 1
fi

echo -e "\n${BLUE}=================================================${NC}"
echo -e "${BLUE}   🎉 INSTALLATION COMPLETE!                     ${NC}"
echo -e "${BLUE}=================================================${NC}"
echo "It is recommended to reboot the Raspberry Pi to finalize all changes."
read -p "Do you want to reboot now? [y/N]: " REBOOT_NOW

if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Rebooting... See you on the other side! 👋${NC}"
    reboot
else
    echo -e "${GREEN}Okay. You can reboot manually later with 'sudo reboot'.${NC}"
fi
