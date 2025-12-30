#!/bin/bash

# ==============================================================================
#  RPI 5 HOMELAB - MASTER SETUP WIZARD
#  Includes: K3s, Helm, SOPS, Age, and GitHub Actions Runner Auto-Setup
# ==============================================================================

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Check Root
if [ "$EUID" -ne 0 ]; then 
  echo -e "${RED}Please run as root (sudo ./setup_wizard.sh)${NC}"
  exit 1
fi

# Detect actual user (not root) to install the Runner correctly
REAL_USER=${SUDO_USER:-$(whoami)}
REAL_HOME=$(getent passwd $REAL_USER | cut -d: -f6)

echo -e "${BLUE}=================================================${NC}"
echo -e "${BLUE}   🚀 RPI 5 HOMELAB SETUP WIZARD                 ${NC}"
echo -e "${BLUE}      User detected: $REAL_USER ($REAL_HOME)     ${NC}"
echo -e "${BLUE}=================================================${NC}"

# ------------------------------------------------------------------------------
# PHASE 1: SYSTEM TOOLS INSTALLATION
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}--> [1/4] Installing System Dependencies...${NC}"
apt update && apt install -y curl wget git htop vim open-iscsi nfs-common age jq

# Install K3s
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

# Install Helm & Helmfile
if ! command -v helm &> /dev/null; then
    echo "    - Installing Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    # Run plugin install as the real user to avoid permission issues later
    sudo -u $REAL_USER helm plugin install https://github.com/jkroepke/helm-secrets
fi

if ! command -v helmfile &> /dev/null; then
    echo "    - Installing Helmfile..."
    curl -sSfL https://github.com/helmfile/helmfile/releases/download/v0.169.1/helmfile_0.169.1_linux_arm64.tar.gz | tar xz
    mv helmfile /usr/local/bin/
fi

# Install SOPS
if ! command -v sops &> /dev/null; then
    echo "    - Installing SOPS..."
    curl -sSfL https://github.com/getsops/sops/releases/download/v3.9.0/sops-v3.9.0.linux.arm64 > sops
    chmod +x sops && mv sops /usr/local/bin/
fi

# ------------------------------------------------------------------------------
# PHASE 2: SECURITY SETUP (AGE KEY)
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}--> [2/4] Configuring Encryption Keys...${NC}"
mkdir -p $REAL_HOME/.config/age
KEY_FILE="$REAL_HOME/.config/age/key.txt"

if [ ! -f "$KEY_FILE" ]; then
    sudo -u $REAL_USER age-keygen -o "$KEY_FILE"
    echo -e "${RED}⚠️  IMPORTANT! SAVE THIS KEY SAFE:${NC}"
    cat "$KEY_FILE"
else
    echo "    - Age key found."
fi

# ------------------------------------------------------------------------------
# PHASE 3: MODE SELECTION
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}=================================================${NC}"
echo -e "${BLUE}   CHOOSE DEPLOYMENT MODE                        ${NC}"
echo -e "${BLUE}=================================================${NC}"
echo "1) LOCAL DEPLOY (I want to run everything NOW from this RPi)"
echo "2) GITOPS RUNNER (I want to connect to GitHub and deploy via git push)"
echo ""
read -p "Select option [1 or 2]: " MODE

if [ "$MODE" == "1" ]; then
    # --------------------------------------------------------------------------
    # OPTION 1: LOCAL DEPLOY (Original Logic)
    # --------------------------------------------------------------------------
    echo -e "\n${GREEN}--> [Local Mode] Configuring variables...${NC}"
    read -p "🔹 IP for Pi-hole DNS: " PIHOLE_IP
    read -p "🔹 IP for Homebridge: " HOMEBRIDGE_IP
    read -p "🔹 IP for Tailscale: " TAILSCALE_IP
    read -s -p "🔑 Admin Password: " PIHOLE_PASS
    echo ""
    read -s -p "🔑 Tailscale Key: " TAILSCALE_KEY
    echo ""

    export PIHOLE_IP
    export HOMEBRIDGE_IP
    export TAILSCALE_IP
    export SOPS_AGE_KEY_FILE=$KEY_FILE

    # Generate secrets locally
    mkdir -p secrets
    cat <<EOF > secrets/temp.yaml
adminPassword: "$PIHOLE_PASS"
tailscale:
  authKey: "$TAILSCALE_KEY"
EOF
    sops --age-file $KEY_FILE -e secrets/temp.yaml > secrets/app.sops.yaml
    rm secrets/temp.yaml

    echo -e "\n${GREEN}--> 🚀 Deploying...${NC}"
    helmfile --helm-secrets apply
    echo -e "${GREEN}✅ Done! Access Pi-hole at http://$PIHOLE_IP/admin${NC}"

elif [ "$MODE" == "2" ]; then
    # --------------------------------------------------------------------------
    # OPTION 2: GITHUB RUNNER SETUP
    # --------------------------------------------------------------------------
    echo -e "\n${GREEN}--> [GitOps Mode] Setting up GitHub Runner...${NC}"
    echo "You need to get a RUNNER TOKEN from GitHub:"
    echo "Go to: Repo Settings -> Actions -> Runners -> New Self-Hosted Runner"
    echo ""
    read -p "🔹 GitHub Repo URL (e.g., https://github.com/user/repo): " REPO_URL
    read -p "🔹 Runner Registration Token: " RUNNER_TOKEN

    RUNNER_DIR="$REAL_HOME/actions-runner"
    
    # Create dir as real user
    sudo -u $REAL_USER mkdir -p $RUNNER_DIR
    cd $RUNNER_DIR

    # Download Runner (ARM64)
    echo "    - Downloading Runner..."
    # Warning: Always check for latest version. This is hardcoded for stability.
    sudo -u $REAL_USER curl -o actions-runner-linux-arm64-2.311.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.311.0/actions-runner-linux-arm64-2.311.0.tar.gz
    sudo -u $REAL_USER tar xzf ./actions-runner-linux-arm64-2.311.0.tar.gz

    # Configure Runner
    echo "    - Registering Runner with GitHub..."
    sudo -u $REAL_USER ./config.sh --url $REPO_URL --token $RUNNER_TOKEN --unattended --name "rpi5-runner" --replace

    # Inject Environment Variables (CRITICAL STEP)
    echo "    - Configuring Environment Variables..."
    echo "KUBECONFIG=$REAL_HOME/.kube/config" | sudo -u $REAL_USER tee -a .env
    echo "SOPS_AGE_KEY_FILE=$KEY_FILE" | sudo -u $REAL_USER tee -a .env

    # Install Service
    echo "    - Installing Systemd Service..."
    sudo ./svc.sh install $REAL_USER
    sudo ./svc.sh start

    echo -e "\n${GREEN}✅ Runner Installed & Started!${NC}"
    echo "1. Push your code to GitHub."
    echo "2. Check the 'Actions' tab in your repo."
    echo "3. The Raspberry Pi will pick up the job and deploy automatically."

else
    echo "Invalid option."
    exit 1
fi
