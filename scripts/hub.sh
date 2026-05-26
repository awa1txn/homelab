#!/usr/bin/env bash
# hub.sh — provision the MicroK8s hub (control-plane) node
# Installs: MicroK8s ingress (Traefik), ArgoCD
# Writes:   /vagrant/join-command.sh  (consumed by spoke)
#           /vagrant/argocd-credentials.txt
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
SNAP_CHANNEL="latest/stable"

# ── 1. snapd ──────────────────────────────────────────────────────────────────
echo "==> [hub] Installing snapd"
apt-get update -qq
apt-get install -y -qq snapd
# Debian needs the /snap symlink
ln -sf /var/lib/snapd/snap /snap 2>/dev/null || true
systemctl enable --now snapd.socket snapd

echo "==> [hub] Waiting for snapd to be ready"
for i in $(seq 1 3); do
  /snap/bin/snap version 2>/dev/null && break
  echo "    ... ($i/3) waiting for snapd"
  sleep 5
done

export PATH=$PATH:/snap/bin

# ── 2. MicroK8s ───────────────────────────────────────────────────────────────
echo "==> [hub] Installing MicroK8s (${SNAP_CHANNEL})"
snap install microk8s --classic --channel="${SNAP_CHANNEL}"

echo "==> [hub] Waiting for MicroK8s to be ready"
microk8s status --wait-ready --timeout 120

usermod -aG microk8s vagrant
mkdir -p /home/vagrant/.kube
microk8s config > /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

# ── 3. Core add-ons ───────────────────────────────────────────────────────────
echo "==> [hub] Enabling add-ons: dns, storage, metrics-server, ingress"
microk8s enable dns || true
microk8s enable hostpath-storage || true
microk8s enable metrics-server || true
microk8s enable ingress || true

echo "==> [hub] Waiting for CoreDNS and Ingress Controller"
microk8s kubectl rollout status deployment/coredns -n kube-system --timeout=15s || true

# In recent MicroK8s, the ingress addon deploys Traefik in ingress namespace.
# Check rollout only when the deployment exists so re-runs stay clean.
if microk8s kubectl get deployment traefik -n ingress >/dev/null 2>&1; then
  microk8s kubectl rollout status deployment/traefik -n ingress --timeout=120s || true
fi

echo "==> [hub] Configuring Traefik service NodePorts (30080/30443)"
TRAEFIK_SVC=$(microk8s kubectl get svc -n ingress -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .spec.ports[*]}{.port}{","}{end}{"\n"}{end}' | awk -F'|' '$2 ~ /(^|,)80,/ && $2 ~ /(^|,)443,/ {print $1; exit}')

if [ -n "${TRAEFIK_SVC}" ]; then
  microk8s kubectl patch svc "${TRAEFIK_SVC}" -n ingress --type=merge -p '{"spec":{"type":"NodePort"}}'

  HTTP_PORT_INDEX=$(microk8s kubectl get svc "${TRAEFIK_SVC}" -n ingress -o jsonpath='{range $i, $p := .spec.ports}{"\n"}{$i}{"|"}{$p.port}{"|"}{$p.name}{end}' \
    | awk -F'|' '$2 == "80" {print $1; exit}' | tr -d '\n')
  HTTPS_PORT_INDEX=$(microk8s kubectl get svc "${TRAEFIK_SVC}" -n ingress -o jsonpath='{range $i, $p := .spec.ports}{"\n"}{$i}{"|"}{$p.port}{"|"}{$p.name}{end}' \
    | awk -F'|' '$2 == "443" {print $1; exit}' | tr -d '\n')

  if [ -n "${HTTP_PORT_INDEX}" ]; then
    microk8s kubectl patch svc "${TRAEFIK_SVC}" -n ingress --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/spec/ports/${HTTP_PORT_INDEX}/nodePort\",\"value\":30080}]"
  fi

  if [ -n "${HTTPS_PORT_INDEX}" ]; then
    microk8s kubectl patch svc "${TRAEFIK_SVC}" -n ingress --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/spec/ports/${HTTPS_PORT_INDEX}/nodePort\",\"value\":30443}]"
  fi
else
  echo "WARNING: Could not find Traefik service in namespace ingress"
fi

echo "    Traefik HTTP  → http://${HUB_IP}:30080"
echo "    Traefik HTTPS → https://${HUB_IP}:30443"

# ── 4. ArgoCD ─────────────────────────────────────────────────────────────────
echo "==> [hub] Installing ArgoCD"
microk8s kubectl create namespace argocd --dry-run=client -o yaml \
  | microk8s kubectl apply -f -

ARGOCD_MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

# Server-side apply avoids huge last-applied annotations on CRDs.
microk8s kubectl apply --server-side --force-conflicts -f "${ARGOCD_MANIFEST_URL}" -n argocd

echo "==> [hub] Waiting for ArgoCD server (up to 2 min)"
microk8s kubectl rollout status deployment/argocd-server -n argocd --timeout=120s

# Patch service to NodePort (idempotent)
microk8s kubectl -n argocd patch svc argocd-server \
  -p '{"spec":{"type":"NodePort"}}'

# Set deterministic NodePort without generating patch errors on re-run.
CURRENT_ARGOCD_NODEPORT=$(microk8s kubectl -n argocd get svc argocd-server \
  -o jsonpath='{.spec.ports[0].nodePort}')
if [ -z "${CURRENT_ARGOCD_NODEPORT}" ]; then
  microk8s kubectl -n argocd patch svc argocd-server --type=json \
    -p='[{"op":"add","path":"/spec/ports/0/nodePort","value":30888}]'
elif [ "${CURRENT_ARGOCD_NODEPORT}" != "30888" ]; then
  microk8s kubectl -n argocd patch svc argocd-server --type=json \
    -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":30888}]'
fi

echo "==> [hub] Waiting for ArgoCD admin secret"
for i in $(seq 1 60); do
  if microk8s kubectl -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

ARGOCD_PASS=$(microk8s kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

{
  echo "ArgoCD UI  : https://${HUB_IP}:30888"
  echo "Username   : admin"
  echo "Password   : ${ARGOCD_PASS}"
} | tee /vagrant/argocd-credentials.txt

# ── 5. Demo applications ──────────────────────────────────────────────────────
echo "==> [hub] Deploying demo applications"
microk8s kubectl apply -f /vagrant/manifests/hello-world.yaml
microk8s kubectl apply -f /vagrant/manifests/httpbin.yaml

# ── 6. Spoke join token ───────────────────────────────────────────────────────
echo "==> [hub] Generating spoke join token (TTL: 1 hour)"
ADD_OUTPUT=$(microk8s add-node --token-ttl 3600 2>&1)

# Extract the token hash; rebuild the command with the private-network IP
# so the spoke reaches hub on the right interface
TOKEN=$(echo "${ADD_OUTPUT}" | grep "microk8s join" | head -1 | sed 's|.*:25000/||' | awk '{print $1}')
echo "microk8s join ${HUB_IP}:25000/${TOKEN}" > /vagrant/join-command.sh
chmod +x /vagrant/join-command.sh

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║               Hub provisioning complete              ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Traefik HTTP   http://${HUB_IP}:30080               ║"
echo "║  Traefik HTTPS  https://${HUB_IP}:30443              ║"
echo "║  ArgoCD UI      https://${HUB_IP}:30888              ║"
echo "║  Credentials    /vagrant/argocd-credentials.txt      ║"
echo "╚══════════════════════════════════════════════════════╝"
