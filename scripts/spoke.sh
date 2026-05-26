#!/usr/bin/env bash
# spoke.sh — provision the MicroK8s spoke (worker) node
# Joins the hub cluster using the token written by hub.sh
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
SNAP_CHANNEL="latest/stable"

# ── 1. snapd ──────────────────────────────────────────────────────────────────
echo "==> [spoke] Installing snapd"
apt-get update -qq
apt-get install -y -qq snapd || true
ln -sf /var/lib/snapd/snap /snap 2>/dev/null || true
systemctl enable --now snapd.socket snapd || true

echo "==> [spoke] Waiting for snapd to be ready"
for i in $(seq 1 3); do
  /snap/bin/snap version 2>/dev/null && break
  echo "    ... ($i/3) waiting for snapd"
  sleep 5
done

export PATH=$PATH:/snap/bin

# ── 2. MicroK8s ───────────────────────────────────────────────────────────────
echo "==> [spoke] Installing MicroK8s (${SNAP_CHANNEL})"
snap install microk8s --classic --channel="${SNAP_CHANNEL}" || true

echo "==> [spoke] Waiting for MicroK8s to be ready"
microk8s status --wait-ready --timeout 120

usermod -aG microk8s vagrant || true

# ── 3. Wait for hub join token ────────────────────────────────────────────────
echo "==> [spoke] Waiting for hub to write /vagrant/join-command.sh"
WAITED=0
until [ -s /vagrant/join-command.sh ]; do
  echo "    ... ${WAITED}s elapsed, retrying in 10s"
  sleep 10
  WAITED=$((WAITED + 10))
  if [ "${WAITED}" -gt 600 ]; then
    echo "ERROR: Timed out (10 min) waiting for hub join token" >&2
    exit 1
  fi
done

# ── 4. Join the hub cluster ───────────────────────────────────────────────────
echo "==> [spoke] Checking if already joined..."
if microk8s kubectl get nodes 2>/dev/null | grep -q "hub\|control-plane"; then
  echo "    Already joined to cluster!"
else
  echo "==> [spoke] Joining hub cluster at ${HUB_IP}"
  bash /vagrant/join-command.sh || {
    echo "WARNING: Join command failed. Checking cluster status..."
    microk8s kubectl get nodes || true
  }
fi

echo "==> [spoke] Waiting for node to appear in cluster"
sleep 15

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║             Spoke provisioning complete              ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Node joined hub at ${HUB_IP}                   ║"
echo "║  Verify:  vagrant ssh hub                            ║"
echo "║           microk8s kubectl get nodes                 ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Demo apps (deployed by hub, scheduled on cluster)   ║"
echo "║  hello-world  →  curl http://${HUB_IP}:30100    ║"
echo "║  go-httpbin   →  curl http://${HUB_IP}:30200    ║"
echo "╚══════════════════════════════════════════════════════╝"
