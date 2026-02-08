#!/bin/bash

# ==============================================================================
#  RPI 5 HOMELAB - MASTER SETUP WIZARD
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
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo -e "${BLUE}=================================================${NC}"
echo -e "${BLUE}    🚀 RPI 5 HOMELAB SETUP WIZARD                 ${NC}"
echo -e "${BLUE}      User detected: $REAL_USER ($REAL_HOME)     ${NC}"
echo -e "${BLUE}      Working Dir: $(pwd)                        ${NC}"
echo -e "${BLUE}=================================================${NC}"

# ------------------------------------------------------------------------------
# PHASE 0: PRE-FLIGHT CHECKS (BOOT CONFIG)
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}--> [0/5] Checking System Configuration...${NC}"

CMDLINE_PATH=""
if [ -f /boot/firmware/cmdline.txt ]; then
  CMDLINE_PATH="/boot/firmware/cmdline.txt"
elif [ -f /boot/cmdline.txt ]; then
  CMDLINE_PATH="/boot/cmdline.txt"
fi

if [ -n "$CMDLINE_PATH" ]; then
  if ! grep -q "cgroup_memory=1" "$CMDLINE_PATH"; then
    echo -e "    - ${RED}Cgroups missing! Fixing automatically...${NC}"
    cp "$CMDLINE_PATH" "$CMDLINE_PATH.bak"
    sed -i 's/$/ cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory/' "$CMDLINE_PATH"
    echo -e "${RED}⚠️  SYSTEM REBOOT REQUIRED. Rebooting in 10s...${NC}"
    sleep 10 && reboot && exit 0
  else
    echo "    - Boot config (cgroups) is OK."
  fi
else
  echo "⚠️  Warning: Could not find cmdline.txt. Skipping cgroup check."
fi

# ------------------------------------------------------------------------------
# PHASE 1: INSTALL DEPENDENCIES & NETWORK
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}--> [1/5] Installing System Dependencies...${NC}"

apt update -qq && apt install -y \
  curl wget git htop vim \
  open-iscsi nfs-common \
  age jq \
  libcups2 \
  > /dev/null

systemctl enable --now iscsid rpcbind nfs-client.target

ZENPI_IP=$(awk '/zenpi_ip/{print $2; exit}' values/network.yaml | tr -d '"')

if [ -n "$ZENPI_IP" ]; then
  echo -e "${GREEN}Configuring static IP $ZENPI_IP via netplan...${NC}"
  NETPLAN_FILE="/etc/netplan/01-zenpi.yaml"
  cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    eth0:
      dhcp4: false
      dhcp6: true
      addresses:
        - ${ZENPI_IP}/24
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses:
EOF
  chmod 600 "$NETPLAN_FILE"
  netplan generate && netplan apply
  echo "✅ IP applied: $(ip addr show eth0 | grep 'inet ' | awk '{print $2}')"
fi

# ------------------------------------------------------------------------------
# PHASE 1.2: SYSCTL & LONGHORN PREREQUISITES
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}--> [1.2/5] Preparing kernel & storage (Longhorn & Printing)...${NC}"

# Kernel params for k8s / routing
cat >/etc/sysctl.d/99-k8s.conf <<EOF
net.ipv4.ip_forward=1
vm.overcommit_memory=1
EOF
sysctl --system > /dev/null

# Ensure iscsi module loads (Storage)
modprobe iscsi_tcp 2>/dev/null || true
echo "iscsi_tcp" >/etc/modules-load.d/iscsi.conf

# Ensure printer modules load (USB Printing)
modprobe usblp 2>/dev/null || true
echo "usblp" >/etc/modules-load.d/printer.conf

systemctl enable --now iscsid 2>/dev/null || true

# ------------------------------------------------------------------------------
# PHASE 1.5: K3s INSTALL & CONFIGURATION
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}--> [K3s] Synchronizing Engine Configuration...${NC}"

if ! command -v k3s &> /dev/null; then
    echo "    - Installing K3s..."
    curl -sfL https://get.k3s.io | sh -
    mkdir -p $REAL_HOME/.kube
    cp /etc/rancher/k3s/k3s.yaml $REAL_HOME/.kube/config
    chown $REAL_USER:$REAL_USER $REAL_HOME/.kube/config
    echo "export KUBECONFIG=$REAL_HOME/.kube/config" >> $REAL_HOME/.bashrc
else
    echo "    - K3s already installed."
fi

# Ensure kubectl available
if [ ! -f /usr/local/bin/kubectl ]; then
  ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
fi

mkdir -p /etc/rancher/k3s
cat <<'EOF' > /etc/rancher/k3s/config.yaml
disable:
  - traefik
  - servicelb
EOF

if [ -f /etc/systemd/system/k3s.service ]; then
    echo "    - Verifying k3s.service integrity..."
    if grep -q "ExecStart=.*\\\\" /etc/systemd/system/k3s.service || grep -q "disable" /etc/systemd/system/k3s.service; then
        echo -e "${YELLOW}⚠️  Fixing ExecStart in k3s.service...${NC}"
        sed -i 's|^ExecStart=.*|ExecStart=/usr/local/bin/k3s server|' /etc/systemd/system/k3s.service
        systemctl daemon-reload
        systemctl restart k3s
        sleep 10
    fi
fi

if command -v kubectl &> /dev/null && [ -f /etc/rancher/k3s/k3s.yaml ]; then
    echo "    - Cleaning residual LoadBalancer pods..."
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    kubectl delete daemonset -n kube-system -l svccontroller.k3s.cattle.io/svcname=pihole-dns --ignore-not-found=true 2>/dev/null
    kubectl delete daemonset -n kube-system -l svccontroller.k3s.cattle.io/svcname=pihole-web --ignore-not-found=true 2>/dev/null
    kubectl delete daemonset -n kube-system -l svccontroller.k3s.cattle.io/svcname=traefik --ignore-not-found=true 2>/dev/null
fi

# ------------------------------------------------------------------------------
# PHASE 1.8: HELM, HELMFILE & SOPS
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}--> [1.8/5] Installing Helm, Helmfile & SOPS...${NC}"

if ! command -v helm &> /dev/null; then
  echo "    - Installing Helm..."
  curl https://raw.githubusercontent.com | bash
fi

echo "    - Checking Helm plugins for $REAL_USER..."
sudo -u "$REAL_USER" helm plugin install https://github.com --version v4.6.0 > /dev/null 2>&1 || true
sudo -u "$REAL_USER" helm plugin install https://github.com > /dev/null 2>&1 || true

if ! command -v helmfile &> /dev/null; then
  echo "    - Installing Helmfile..."
  curl -sSfL https://github.com | tar xz
  mv helmfile /usr/local/bin/
fi

if ! command -v sops &> /dev/null; then
  echo "    - Installing SOPS..."
  curl -sSfL https://github.com > sops
  chmod +x sops && mv sops /usr/local/bin/
fi

# ------------------------------------------------------------------------------
# PHASE 2: SECURITY SETUP (AGE KEY, OPTION C)
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}--> [2/5] Configuring Encryption Keys...${NC}"
mkdir -p "$REAL_HOME/.config/age"
KEY_FILE="$REAL_HOME/.config/age/key.txt"

# Option C: prefer /boot, fallback to interactive
if [ -f /boot/age/key.txt ]; then
  echo -e "${GREEN}Found AGE key at /boot/age/key.txt. Installing...${NC}"
  mv /boot/age/key.txt "$KEY_FILE"
  chown "$REAL_USER:$REAL_USER" "$KEY_FILE"
  chmod 600 "$KEY_FILE"
elif [ ! -f "$KEY_FILE" ]; then
  echo -e "${YELLOW}No AGE private key found.${NC}"
  echo -e "${BLUE}Please paste your AGE private key below.${NC}"
  echo -e "${BLUE}End input with CTRL+D when finished.${NC}"
  echo ""

  KEY_CONTENT=$(cat)

  if [[ -z "$KEY_CONTENT" ]]; then
    echo -e "${RED}❌ No key provided. Aborting.${NC}"
    exit 1
  fi

  echo "$KEY_CONTENT" > "$KEY_FILE"
  chown "$REAL_USER:$REAL_USER" "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  echo -e "${GREEN}✔ AGE key saved to $KEY_FILE${NC}"
else
  echo " - Age key found at $KEY_FILE."
  chown "$REAL_USER:$REAL_USER" "$KEY_FILE"
  chmod 600 "$KEY_FILE"
fi

if ! grep -q "SOPS_AGE_KEY_FILE" "$REAL_HOME/.bashrc"; then
  echo "export SOPS_AGE_KEY_FILE=$KEY_FILE" >> "$REAL_HOME/.bashrc"
fi
export SOPS_AGE_KEY_FILE="$KEY_FILE"

# Validate SOPS decryption
echo -e "${GREEN}Validating SOPS decryption...${NC}"
if ! sops -d secrets/app.sops.yaml >/dev/null 2>&1; then
  echo -e "${RED}❌ SOPS decryption failed. Wrong key?${NC}"
  exit 1
fi
echo -e "${GREEN}✔ SOPS decryption OK${NC}"

# ------------------------------------------------------------------------------
# PHASE 3: DEPLOYMENT MODE
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}=================================================${NC}"
echo -e "${BLUE} CHOOSE DEPLOYMENT MODE ${NC}"
echo -e "${BLUE}=================================================${NC}"
echo "1) LOCAL DEPLOY (Update apps instantly)"
echo "2) GITOPS RUNNER (Reinstall GitHub Runner)"
echo ""
read -p "Select option [1 or 2]: " MODE

if [ "$MODE" == "1" ]; then
  echo -e "\n${GREEN}--> [Local Mode] Applying Helmfile...${NC}"
  sudo -u "$REAL_USER" SOPS_AGE_KEY_FILE="$KEY_FILE" KUBECONFIG="$REAL_HOME/.kube/config" /usr/local/bin/helmfile apply
elif [ "$MODE" == "2" ]; then
  echo -e "\n${GREEN}--> [GitOps Mode] Setting up GitHub Runner...${NC}"
  read -p "🔹 GitHub Repo URL: " REPO_URL
  read -p "🔹 Runner Registration Token: " RUNNER_TOKEN

  RUNNER_DIR="$REAL_HOME/actions-runner"
  if [ -d "$RUNNER_DIR" ]; then
    cd "$RUNNER_DIR" && sudo ./svc.sh uninstall > /dev/null 2>&1
    cd "$REPO_ROOT" && rm -rf "$RUNNER_DIR"
  fi

  sudo -u "$REAL_USER" mkdir -p "$RUNNER_DIR"
  cd "$RUNNER_DIR"

  LATEST_VERSION=$(curl -s https://api.github.com | jq -r .tag_name | sed 's/v//')
  sudo -u "$REAL_USER" curl -o actions-runner.tar.gz -L "https://github.com{LATEST_VERSION}/actions-runner-linux-arm64-${LATEST_VERSION}.tar.gz"
  sudo -u "$REAL_USER" tar xzf actions-runner.tar.gz

  sudo -u "$REAL_USER" ./config.sh --url "${REPO_URL%.git}" --token "$RUNNER_TOKEN" --unattended --name "$(hostname)" --replace

  echo "KUBECONFIG=$REAL_HOME/.kube/config" | sudo -u "$REAL_USER" tee -a .env > /dev/null
  echo "SOPS_AGE_KEY_FILE=$KEY_FILE" | sudo -u "$REAL_USER" tee -a .env > /dev/null
  
  sudo ./svc.sh install "$REAL_USER" && sudo ./svc.sh start

  echo -e "\n${GREEN}✅ SUCCESS! Your Pi is now a GitOps Worker.${NC}"
fi

echo -e "\n${BLUE}=================================================${NC}"
echo -e "${BLUE} 🎉 INSTALLATION COMPLETE! ${NC}"
echo -e "${BLUE}=================================================${NC}"

read -p "Do you want to reboot now? [y/N]: " REBOOT_NOW
[[ "$REBOOT_NOW" =~ ^[Yy]$ ]] && reboot
