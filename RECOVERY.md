# Homelab recovery and migration

How to rebuild the cluster (new SD card, SSD or another Raspberry Pi), and what
can be moved as-is and what cannot. It is written from the repo and the setup
wizard, and marks anything that has never actually been run as **[UNTESTED]**.

## 1. What you must have BEFORE something fails

| Item | Where it must live | Status |
|---|---|---|
| **age** private key (`~/.config/age/key.txt`) | Off the SD card: password manager or an encrypted USB stick | **Unconfirmed** |
| This repository (GitHub `Z3n42/rpi-homelab`, public) | GitHub | OK |
| GitHub token to register the runner | Generated on demand (Settings → Actions → Runners) | OK |
| Longhorn data backup | None yet | **Pending** |

The public key is in `.sops.yaml`. Without the private key,
`secrets/app.sops.yaml`, `secrets/cloudflare.sops.yaml` and
`secrets/peripherals.sops.json` (printer firmware) **cannot be decrypted**, and
the key cannot be recovered: you would have to generate a new one and
re-encrypt every secret with its original value (Cloudflare token, Tailscale
OAuth, etc.).

## 2. What rebuilds itself and what is lost

**Rebuilt from git** (nothing to move by hand): every release in
`helmfile.yaml`, the IngressRoutes, Pi-hole (configuration and DNS records),
MetalLB, cert-manager, issuers and the TLSStore.

**CUPS: rebuilds itself** (tested by deleting the queue and restarting the pod).
At every start, if the queue `HP_LaserJet_P1005` is missing and the printer is
on USB, the CUPS container creates it with the same driver and options
(`lpadmin`, declared in the container command in `helmfile.yaml`). The admin user
comes from the `cups-admin` Secret (values in `secrets/app.sops.yaml`). If the
printer is unplugged when the pod starts, nothing is created and the log says so;
plugging it in restarts the pod (udev rule) and the queue is created then. The
creation takes a few seconds after the pod shows as ready, because CUPS has no
readiness probe yet.

**Certificates: nothing to migrate.** cert-manager re-issues the wildcard via
DNS-01 using the Cloudflare token. It does not depend on the IP, the node or
any open port. Two precautions:
- Let's Encrypt allows only 5 identical certificates per week. If you rehearse
  the rebuild several times, point the Certificate at `letsencrypt-staging`
  during the tests (the certificate will not be trusted, but it exercises the
  whole flow).
- Issuance takes 1-2 minutes. Until then Traefik serves its self-signed
  certificate; that is not a failure.

**Names under `lab.ingonzal.dev`: rebuilt from git, with three caveats.**
Pi-hole answers `cups`, `homebridge`, `traefik` and `pihole` `.lab.ingonzal.dev`
with the Traefik IP (`custom.hosts` in `pihole-unbound-v6.yaml.gotmpl`), and the
IngressRoutes serve the Let's Encrypt certificate for them. The `.lan` names and
the plain IPs keep working as certificate-free emergency access.
- The public zone has a Cloudflare wildcard record, which also answers AAAA
  queries for these names with Cloudflare IPv6 addresses. The `local=/<name>/`
  lines in `[misc] dnsmasq_lines` stop that, per name (not for the whole zone,
  so the ACME TXT lookups keep working). `address=/<name>/<ip>` does **not**
  do it. Check with `nslookup -type=AAAA pihole.lab.ingonzal.dev 192.168.1.53`:
  it must answer "No answer".
- After changing `custom.hosts` run
  `kubectl exec -n pihole deploy/pihole-v6 -c pihole -- pihole reloaddns`;
  a restart is not needed.
- A `pihole.toml` change from git is copied to the volume by the
  `pihole-v6-init` Job at deploy time, but the running Pi-hole does not re-read
  it. Apply it live with `pihole-FTL --config <key> <value>` or restart the pod.
  The Job also deletes `/etc/pihole/dnsmasq.conf` on every deploy; the running
  resolver keeps its loaded config and the file is regenerated on the next start.
  A pod restart with nothing applied by hand was tested: it starts with the
  `local=` lines and the records from git.

**Lost without a backup** (PVCs on Longhorn, single replica):
- Pi-hole (settings changed from the web UI; the adlists are seeded from git by
  the `pihole-adlists-seed` Job, which only adds missing URLs and never removes
  lists added by hand; the PVC has `resource-policy: keep`, but that only
  protects against `helm uninstall`, not against changing disks).
- Homebridge (`/homebridge`): pairings and plugins. Accessories must be paired
  again in the Home app.
- CUPS (`/etc/cups`): only job history and any per-printer option changed by hand
  in the web UI; the queue itself is recreated from git.

## 3. Rebuild on the same Raspberry Pi (new SD card or SSD)

1. Install Raspberry Pi OS 64-bit with user `pi`, wired network and SSH.
2. Install git and clone the repo (Raspberry Pi OS Lite may not ship git):
   ```
   sudo apt-get update && sudo apt-get install -y git
   git clone https://github.com/Z3n42/rpi-homelab.git
   cd rpi-homelab
   ```
3. (Optional) Pre-place the age key at `/boot/age/key.txt`. The wizard
   **moves** it to `~/.config/age/key.txt`. If you skip this step, the wizard
   asks you to paste the key during step 4 (see below).
4. Run the wizard as root from the repo directory:
   ```
   sudo ./bootstrap/setup_wizard.sh
   ```
   When it reaches its security phase, it uses `/boot/age/key.txt` if present;
   otherwise it prompts you to paste the key (it is not written to any log).
   In order, it: fixes cgroups (**it may reboot the Pi; run it again
   afterwards**), installs dependencies and network config, prepares
   Longhorn/USB prerequisites, installs k3s pinned to `v1.33.6+k3s1`, sets up
   graceful kubelet shutdown, installs helm/helmfile/sops at pinned versions,
   validates sops decryption, restores the printer firmware, and finally
   deploys.
5. At "Deployment mode" choose:
   - `1` to run `helmfile apply` locally, or
   - `2` to install the GitHub runner (it asks for the repo URL and a
     registration token) and deploy from Actions afterwards.
6. Accept the final reboot.

**[UNTESTED]**: the wizard has never been run on a clean Pi. See section 6.

### Verification after rebuilding
```
kubectl get nodes
kubectl get pods -A | grep -v -E "Running|Completed"
kubectl get svc -A --field-selector spec.type=LoadBalancer
kubectl get certificate -A          # READY=True after 1-3 minutes
sops -d secrets/app.sops.yaml > /dev/null && echo "sops OK"
```
Then, with the data restored or recreated:
- Pi-hole: `https://192.168.1.52`, and check `nslookup traefik.lan 192.168.1.53`
  and `nslookup pihole.lab.ingonzal.dev 192.168.1.53` (must be `192.168.1.50`,
  with no IPv6 address).
- Homebridge: `https://homebridge.lan` and the Home app.
- Printing: print a test page from the iPhone.
- Certificate served by Traefik:
  `echo | openssl s_client -connect 192.168.1.50:443 -servername cups.lab.ingonzal.dev 2>/dev/null | openssl x509 -noout -issuer -dates`

## 4. Going back after a failed change (without rebuilding)

Restore points are `backup-YYYYMMDD[-N]` tags on validated commits. Use the
**⏪ Rollback to Backup Tag** workflow (dry_run first; the diff must make
sense). Important limit: the rollback applies the helmfile at that tag, so it
**does not uninstall releases the tag does not know about**. Remove them by
hand. Example for the Traefik certificates:
```
helm uninstall traefik-tls -n traefik-system
kubectl delete secret ingonzal-dev-tls -n traefik-system --ignore-not-found
```
The original Certificate (`cert-manager/ingonzal-dev-wildcard`) is never
touched.

## 5. Moving to another Raspberry Pi, or going from one to two

**A new Pi replacing the current one** (same role, same hostname `zenpi`):
follow section 3. To keep data, copy the PVCs first (section 7).

**Adding a second Pi as an extra node** is not supported yet. What would have
to be solved first:
- `NODE_NAME="zenpi"` in the wizard and a Longhorn hook that annotates node
  `zenpi`: both assume a single node with that name.
- CUPS depends on the printer's USB port (`hostPath: /dev/bus/usb`): it needs a
  `nodeSelector` for the node the printer is plugged into.
- Homebridge and the avahi publisher use `hostNetwork`: they are tied to the
  node and its network.
- Longhorn runs with replica 1; with two nodes, replicas and disks need a
  decision.
- Traefik's `persistence` block is ignored; Traefik has no data of its own to
  move, but the block should be cleaned up.
- MetalLB (L2) and the certificates work the same with several nodes.

**Network change** (different range or router): the IPs are centralized in
`values/network.yaml` (MetalLB, Traefik, Pi-hole, Homebridge, CUPS) and in the
IP inside `AirPrint-V2.mobileconfig` (the iPhone profile points at
`192.168.1.51`: regenerate it if that changes). The MetalLB range (`.60-.80`)
and the fixed IPs must stay outside the router's DHCP range.

## 6. Concrete to-dos to make this trustworthy

1. **Store the age key off the SD card** and check that it decrypts:
   `SOPS_AGE_KEY_FILE=<copy> sops -d secrets/app.sops.yaml > /dev/null`.
2. **Longhorn backup** (NFS/S3 target or an SSD) for Pi-hole and Homebridge
   (CUPS no longer needs it); or at least export those PVCs before every disk
   change.
3. **Rebuild rehearsal** of the wizard in an arm64 VM (for example UTM), and
   record here whatever fails. Until then this document is a reasoned
   hypothesis, not a verified procedure.
4. Clean up Traefik's ignored `persistence` block and pin the `latest` images
   in CUPS (`mwatz/cups`, `busybox`, `alpine`): a rebuild a year from now could
   pull different images than today's.
5. Remove the hardcoded `zenpi` references from `helmfile.yaml` and the wizard
   when a second node is planned.

## 7. Manual PVC copy (quick reference)

With the pod stopped (`kubectl scale deploy/<x> -n <ns> --replicas=0`), mount
the PVC in a temporary pod and copy with `kubectl cp` or `tar` over
`kubectl exec`. Restoring is the reverse path in the new cluster, before
starting the application deployment. Not automated.
