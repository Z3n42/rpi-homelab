<div align="center">

# 🍓 rpi-homelab

### Kubernetes Homelab on Raspberry Pi 5 — GitOps with GitHub Actions

<p>
  <img src="https://img.shields.io/badge/K3s-Lightweight_K8s-FFC61A?style=for-the-badge&logo=kubernetes&logoColor=white" alt="K3s"/>
  <img src="https://img.shields.io/badge/Helmfile-Declarative_GitOps-0F1689?style=for-the-badge&logo=helm&logoColor=white" alt="Helmfile"/>
  <img src="https://img.shields.io/badge/GitHub_Actions-Self--Hosted_Runner-2088FF?style=for-the-badge&logo=githubactions&logoColor=white" alt="GitHub Actions"/>
  <img src="https://img.shields.io/badge/SOPS-AGE_Secrets-FF5733?style=for-the-badge&logo=gnupg&logoColor=white" alt="SOPS"/>
  <img src="https://img.shields.io/badge/Raspberry_Pi_5-ARM64-A22846?style=for-the-badge&logo=raspberrypi&logoColor=white" alt="Raspberry Pi 5"/>
</p>

*A production-grade homelab on a single Raspberry Pi 5 — fully declarative infrastructure, encrypted secrets, self-hosted CI/CD and real network services for learning modern DevOps/GitOps.*

[Overview](#-overview) • [Architecture](#-architecture) • [Services](#-services) • [Workflows](#-gitops-workflows) • [Setup](#-setup-from-scratch) • [Secrets](#-secrets-management)

</div>

---

## 📋 Table of Contents

- [Overview](#-overview)
- [Architecture](#-architecture)
- [Services](#-services)
- [Project Structure](#-project-structure)
- [Network Layout](#-network-layout)
- [GitOps Workflows](#-gitops-workflows)
- [Secrets Management](#-secrets-management)
- [Setup from Scratch](#-setup-from-scratch)
- [Values & Configuration](#-values--configuration)
- [Technical Decisions](#-technical-decisions)
- [Resources](#-resources)

---

## 🎯 Overview

**rpi-homelab** is a fully GitOps-managed Kubernetes homelab running on a Raspberry Pi 5. Every service is declared in `helmfile.yaml`, secrets are encrypted at rest with SOPS+AGE, and deployments are triggered automatically via GitHub Actions running on a self-hosted runner directly on the Pi.

### Why This Project Matters

- **Real GitOps**: Push a tag → Actions deploys to the Pi. No manual `kubectl apply`.
- **Encrypted secrets**: `helm-secrets` + SOPS/AGE — secrets live in the repo, never in plaintext.
- **Production patterns at home scale**: MetalLB, Traefik ingress, Longhorn storage, health probes, resource limits.
- **Full automation**: From bare OS → running cluster in one script (`setup_wizard.sh`).
- **Learning-first**: Every design choice is documented and intentional.

### Stack at a Glance

| Layer | Technology |
|---|---|
| Hardware | Raspberry Pi 5 (ARM64) |
| OS | Ubuntu 24.04 LTS (64-bit) |
| Kubernetes | K3s (without Traefik/ServiceLB — custom stack) |
| Package manager | Helmfile + Helm |
| Secrets | SOPS + AGE + helm-secrets |
| CI/CD | GitHub Actions (self-hosted runner on the Pi) |
| Storage | Longhorn (distributed block storage) |
| Load Balancer | MetalLB (Layer 2) |
| Ingress | Traefik v3 |
| DNS | Pi-hole + Unbound |
| VPN | Tailscale Subnet Router |
| Home automation | Homebridge (Apple HomeKit bridge) |
| Printing | CUPS + Avahi (AirPrint) |

---

## 🏗️ Architecture

### Infrastructure Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                    HOME NETWORK (192.168.1.0/24)                  │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │               Raspberry Pi 5  (192.168.1.130)            │    │
│  │                                                          │    │
│  │  ┌──────────────  K3s Cluster ──────────────────────┐   │    │
│  │  │                                                   │   │    │
│  │  │  MetalLB (L2)  ── LoadBalancer IPs ──────────────┤   │    │
│  │  │  .50 Traefik · .51 CUPS · .52 Pi-hole web        │   │    │
│  │  │  .53 Pi-hole DNS · .54 Pi-hole DNS backup        │   │    │
│  │  │  .55 Homebridge                                  │   │    │
│  │  │                                                  │   │    │
│  │  │  ┌──────────┐  ┌────────────┐  ┌─────────────┐  │   │    │
│  │  │  │  Pi-hole │  │ Homebridge │  │  Tailscale  │  │   │    │
│  │  │  │ +Unbound │  │  (HomeKit) │  │   (Subnet)  │  │   │    │
│  │  │  └──────────┘  └────────────┘  └─────────────┘  │   │    │
│  │  │  ┌──────────┐  ┌────────────┐  ┌─────────────┐  │   │    │
│  │  │  │   CUPS   │  │   Avahi    │  │   Traefik   │  │   │    │
│  │  │  │ (HP USB) │  │  (mDNS)    │  │  (Ingress)  │  │   │    │
│  │  │  └──────────┘  └────────────┘  └─────────────┘  │   │    │
│  │  │  ┌──────────┐  ┌────────────┐                    │   │    │
│  │  │  │ Longhorn │  │cert-manager│                    │   │    │
│  │  │  │ (storage)│  │  (TLS)     │                    │   │    │
│  │  │  └──────────┘  └────────────┘                    │   │    │
│  │  │                                                   │   │    │
│  │  │  🤖 GitHub Actions Runner (self-hosted)           │   │    │
│  │  └───────────────────────────────────────────────────┘   │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                   │
│  ☁️ GitHub ──── push tag ──→ Actions ──→ Runner ──→ helmfile sync │
└──────────────────────────────────────────────────────────────────┘
```

### GitOps Flow

```
Developer                GitHub                 Raspberry Pi
    │                      │                         │
    ├─── git push tag ─────►│                         │
    │                      ├─── trigger workflow ────►│
    │                      │    (self-hosted runner)  │
    │                      │                         ├─ decrypt secrets (SOPS/AGE)
    │                      │                         ├─ helmfile sync --selector name=X
    │                      │                         ├─ health check
    │                      │                         ├─ rollback if needed
    │                      │◄── status + logs ────────┤
    │◄─── notification ────┤                         │
```

---

## 🛠️ Services

| Release | Namespace | Chart | IP | Purpose |
|---|---|---|---|---|
| `metallb` | `metallb-system` | metallb/metallb | — | Layer 2 load balancer |
| `metallb-config` | `metallb-system` | bedag/raw | — | IP pool + L2Advertisement |
| `cert-manager` | `cert-manager` | jetstack/cert-manager | — | TLS certificate automation |
| `longhorn` | `longhorn-system` | longhorn/longhorn | — | Distributed block storage |
| `traefik` | `traefik` | traefik/traefik | `192.168.1.50` | Ingress controller (HTTP→HTTPS) |
| `traefik-resources` | `traefik` | bedag/raw | — | IngressRoutes + middlewares |
| `tailscale` | `tailscale` | bedag/raw | — | VPN subnet router |
| `pihole` | `pihole` | bedag/raw | `.52/.53/.54` | DNS ad-blocker + Unbound resolver |
| `homebridge` | `homebridge` | bjw-s/app-template | `192.168.1.55` | Apple HomeKit bridge |
| `cups-config` | `printing` | dysnix/raw | — | CUPS printer configuration |
| `cups` | `printing` | bjw-s/app-template | `192.168.1.51` | CUPS print server (HP P1005) |
| `cups-avahi-service` | `printing` | dysnix/raw | — | AirPrint Avahi service definition |
| `cups-avahi` | `printing` | bjw-s/app-template | — | mDNS broadcaster (AirPrint) |

---

## 📁 Project Structure

```
rpi-homelab/
├── .github/
│   └── workflows/
│       ├── deploy.yaml          # Main deploy (tag-triggered + manual)
│       ├── redeploy.yaml        # Manual targeted redeploy
│       ├── full-reset.yaml      # Nuclear reset (requires confirmation)
│       ├── service-cleanup.yaml # PVC-preserving cleanup
│       └── cluster-cleanup.yaml # Full cluster wipe (panic button)
│
├── bootstrap/
│   └── setup_wizard.sh          # From-scratch install wizard (interactive)
│
├── helmfile.yaml                # Single source of truth for all releases
│
├── manifests/
│   ├── ingresses/               # Traefik IngressRoutes (dashboard, CUPS, Homebridge)
│   ├── pihole/                  # Pi-hole + Unbound full manifest (gotmpl)
│   └── tailscale/               # Tailscale subnet router manifest
│
├── secrets/
│   └── app.sops.yaml            # SOPS/AGE encrypted secrets (safe to commit)
│
├── values/
│   ├── network.yaml             # All IPs and domain config
│   ├── homebridge.yaml.gotmpl   # Homebridge config template
│   ├── longhorn.yaml            # Longhorn storage config
│   ├── metallb.yaml.gotmpl      # MetalLB pool template
│   ├── metallb-config.yaml.gotmpl
│   └── network.yaml
│
└── .sops.yaml                   # SOPS creation rules (AGE recipient)
```

---

## 🌐 Network Layout

All service IPs are defined in `values/network.yaml` and referenced throughout `helmfile.yaml` via Go templates.

| Service | IP | Port | Protocol |
|---|---|---|---|
| Traefik (ingress) | `192.168.1.50` | 80/443 | HTTP → HTTPS redirect |
| CUPS (printing) | `192.168.1.51` | 631 | IPP / AirPrint |
| Pi-hole (web UI) | `192.168.1.52` | 80 | HTTP |
| Pi-hole (DNS primary) | `192.168.1.53` | 53 | DNS (UDP/TCP) |
| Pi-hole (DNS backup) | `192.168.1.54` | 53 | DNS (UDP/TCP) |
| Homebridge | `192.168.1.55` | 8581 | HTTP |
| MetalLB pool | `192.168.1.60–80` | — | Reserved range |
| Node (zenpi) | `192.168.1.130` | — | Static IP |

> DNS resolution: Pi-hole → Unbound → root servers (recursive, no upstream ISP DNS)

---

## ⚙️ GitOps Workflows

### `deploy.yaml` — Main Deployment

Triggered by pushing a tag matching `deploy-*` or manually with a service selector.

```bash
git tag deploy-20250514 && git push origin deploy-20250514
```

**Flow:**
1. Detects changed files (`values/`, `manifests/`, `helmfile.yaml`)
2. Maps changes → affected releases (smart change detection)
3. Deploys in dependency order: `metallb → cert-manager → longhorn → traefik → pihole → homebridge → tailscale → cups-config → cups → cups-avahi-service → cups-avahi`
4. Verifies pod health post-deploy
5. Auto-rollback if the new revision is unhealthy

### `redeploy.yaml` — Manual Targeted Redeploy

Manually trigger a full redeploy of a specific service stack:

| Target | Releases deployed |
|---|---|
| `all` | Everything |
| `pihole` | pihole |
| `homebridge` | homebridge |
| `tailscale` | tailscale |
| `cups` | cups-config, cups, cups-avahi-service, cups-avahi |
| `ingresses` | traefik-resources |
| `networking-only` | metallb, metallb-config, cert-manager |

### `full-reset.yaml` — Complete Reset

⚠️ Destroys all releases and PVCs. Requires typing `CONFIRM-FULL-RESET` as input.

### `service-cleanup.yaml` — PVC-Preserving Cleanup

Removes Helm releases but **preserves PersistentVolumeClaims** (data survives).

### `cluster-cleanup.yaml` — Panic Button

☢️ Nukes everything including PVCs. Requires `CONFIRM` input.

---

## 🔐 Secrets Management

Secrets are encrypted with **SOPS + AGE** and stored safely in the repository.

### How It Works

```
secrets/app.sops.yaml  ←── git committed (encrypted)
        │
        ▼  (helm-secrets plugin, at deploy time)
helmfile.yaml values:  .Values.pihole.adminPassword
                       .Values.tailscale.oauth.*
                       .Values.cups.user / .cups.password
                       .Values.traefik.email
```

### Secrets Defined

| Key | Used by |
|---|---|
| `pihole.adminPassword` | Pi-hole admin panel |
| `pihole.adminPasswordHash` | Pi-hole password hash (bcrypt of adminPassword) |
| `tailscale.oauth.clientId` | Tailscale operator auth |
| `tailscale.oauth.clientSecret` | Tailscale operator auth |
| `tailscale.oauth.authKey` | Subnet router auth |
| `cups.user` | CUPS admin credentials |
| `cups.password` | CUPS admin credentials |
| `traefik.email` | cert-manager ACME |

### Creating Your Secrets File from Scratch

Before encrypting, create a plaintext template (`secrets/app.yaml`) — **never commit this file**:

```yaml
# secrets/app.yaml  ← ADD TO .gitignore, NEVER COMMIT
pihole:
  adminPassword: "your-pihole-password"
  # Generate the hash with: htpasswd -bnBC 10 "" your-pihole-password | tr -d ':\n'
  adminPasswordHash: "$2y$10$..."

tailscale:
  oauth:
    # Create an OAuth client at https://login.tailscale.com/admin/settings/oauth
    clientId: "tskey-client-..."
    clientSecret: "tskey-secret-..."
    # Create a reusable auth key at https://login.tailscale.com/admin/settings/keys
    authKey: "tskey-auth-..."

cups:
  user: "admin"
  password: "your-cups-password"

traefik:
  # Email for Let's Encrypt ACME notifications
  email: "your@email.com"
```

Then encrypt it with your AGE key and store it in the expected path:

```bash
# 1. Generate your AGE keypair (wizard does this automatically)
age-keygen -o ~/.config/age/key.txt
export SOPS_AGE_KEY_FILE=~/.config/age/key.txt

# 2. Get your public key (add it to .sops.yaml)
age-keygen -y ~/.config/age/key.txt
# → age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# 3. Update .sops.yaml with your public key
# creation_rules:
#   - path_regex: secrets/.*
#     age: "age1xxxx..."   ← replace with your public key

# 4. Encrypt
sops --encrypt secrets/app.yaml > secrets/app.sops.yaml

# 5. Delete the plaintext file
rm secrets/app.yaml
```

> ⚠️ `secrets/app.yaml` (plaintext) must be in `.gitignore`. Only `secrets/app.sops.yaml` (encrypted) is safe to commit.

### Editing Encrypted Secrets

```bash
# Opens in $EDITOR, saves re-encrypted
sops secrets/app.sops.yaml
```

### Key Location

The AGE private key must be present at:
```
~/.config/age/key.txt
```
And exported as `SOPS_AGE_KEY_FILE` in the runner's `.env` file (the wizard sets this automatically).

---

## 🚀 Setup from Scratch

The interactive wizard handles everything from bare Ubuntu to a running cluster.

### Prerequisites

- Raspberry Pi 5 with Ubuntu 24.04 LTS (64-bit)
- SSH access
- GitHub repository with a configured self-hosted runner token
- An AGE keypair (generated by the wizard)

### Quick Start

```bash
# Clone the repo
git clone https://github.com/Z3n42/rpi-homelab.git
cd rpi-homelab

# Run the wizard as root
sudo bash bootstrap/setup_wizard.sh
```

### What the Wizard Does

| Phase | Actions |
|---|---|
| **1 — System** | cgroups, swap, `arm_64bit`, `cgroup_memory` in `/boot/firmware/cmdline.txt` |
| **1.5 — K3s** | Writes `k3s config.yaml` (no traefik, no servicelb) *before* install |
| **1.8 — Tools** | Helm, Helmfile, SOPS, helm-secrets plugin (with correct `HOME`) |
| **2 — AGE Keys** | Generates AGE keypair, exports `SOPS_AGE_KEY_FILE` |
| **2.5 — Network** | Static IP via netplan with **dynamic** gateway detection |
| **3 — Runner** | Registers GitHub Actions self-hosted runner with `.env` (HOME + SOPS vars) |

> ⚠️ The k3s config **must** exist before `curl | sh` installs k3s, otherwise Traefik and ServiceLB boot automatically and need manual removal.

---

## 🔧 Values & Configuration

All environment-specific values live in `values/`:

```yaml
# values/network.yaml
network:
  domain: "lan"
  node:
    zenpi_ip: "192.168.1.130"
  metallb:
    range: "192.168.1.60-192.168.1.80"
  services:
    traefik:   { ip: "192.168.1.50" }
    pihole:    { primary_ip: "192.168.1.53", backup_ip: "192.168.1.54", web_ip: "192.168.1.52" }
    homebridge:{ ip: "192.168.1.55" }
    cups:      { ip: "192.168.1.51" }
```

To adapt this to your network, only `values/network.yaml` needs to change.

---

## 🧠 Technical Decisions

| Decision | Why |
|---|---|
| K3s without Traefik/ServiceLB | Full control over ingress and load balancer versions |
| MetalLB Layer 2 | No BGP router needed — works on any home network |
| Unbound as Pi-hole upstream | Recursive DNS — no upstream ISP DNS, full privacy |
| helm-secrets + SOPS/AGE | Secrets in git, decrypted only at deploy time on the Pi |
| Self-hosted runner on the Pi | No cloud agents needed, Pi runs its own CI/CD |
| bjw-s/app-template | Flexible Helm chart for custom workloads without writing manifests from scratch |
| cups-avahi as Deployment (not DaemonSet) | Avoids duplicate mDNS broadcasts if cluster nodes are added |
| Longhorn hook with dynamic node name | Portable across reinstalls without hardcoded hostnames |
| `deploy-*` tag convention | Explicit, traceable deploy history in git log |

---

## 🔗 Resources

- [K3s Documentation](https://docs.k3s.io/)
- [Helmfile](https://helmfile.readthedocs.io/)
- [helm-secrets](https://github.com/jkroepke/helm-secrets)
- [SOPS](https://github.com/getsops/sops)
- [AGE Encryption](https://github.com/FiloSottile/age)
- [MetalLB](https://metallb.universe.tf/)
- [Traefik v3](https://doc.traefik.io/traefik/)
- [Pi-hole](https://pi-hole.net/)
- [Longhorn](https://longhorn.io/)
- [bjw-s app-template](https://bjw-s.github.io/helm-charts/)
- [Tailscale Kubernetes operator](https://tailscale.com/kb/1236/kubernetes-operator)

---

<div align="center">

Made with ☕ and too many `kubectl get pods -A -w`

[![GitHub](https://img.shields.io/badge/Z3n42-rpi--homelab-181717?style=for-the-badge&logo=github&logoColor=white)](https://github.com/Z3n42/rpi-homelab)

</div>
