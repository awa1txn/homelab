# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# MicroK8s Hub-and-Spoke Homelab
# ─────────────────────────────────────────────────────────
#  hub   192.168.56.10  4 GB / 2 CPU  → MicroK8s control plane
#                                        Traefik (NodePort 30080/30443)
#                                        ArgoCD  (NodePort 30888)
#
#  spoke 192.168.56.11  2 GB / 2 CPU  → MicroK8s worker
#                                        hello-world  (NodePort 30100)
#                                        go-httpbin   (NodePort 30200)
#
# Usage
#   vagrant up           # boots hub first, then spoke
#   vagrant up hub       # hub only
#   vagrant up spoke     # spoke only (hub must already be running)
#   vagrant ssh hub
#   vagrant ssh spoke
# ─────────────────────────────────────────────────────────

VAGRANTFILE_API_VERSION = "2"

HUB_IP   = "192.168.56.10"
SPOKE_IP = "192.168.56.11"

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  config.vm.box             = "debian/bookworm64"
  config.vm.box_check_update = false

  # ── Hub ─────────────────────────────────────────────────────────────────────
  config.vm.define "hub", primary: true do |hub|
    hub.vm.hostname = "hub"
    hub.vm.network  "private_network", ip: HUB_IP

    hub.vm.provider "virtualbox" do |vb|
      vb.name   = "microk8s-hub"
      vb.memory = 4096
      vb.cpus   = 1
      vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    end

    hub.vm.provision "shell" do |s|
      s.path = "scripts/hub.sh"
      s.env  = { "HUB_IP" => HUB_IP, "SPOKE_IP" => SPOKE_IP }
    end
  end

  # ── Spoke ────────────────────────────────────────────────────────────────────
  config.vm.define "spoke" do |spoke|
    spoke.vm.hostname = "spoke"
    spoke.vm.network  "private_network", ip: SPOKE_IP

    spoke.vm.provider "virtualbox" do |vb|
      vb.name   = "microk8s-spoke"
      vb.memory = 2048
      vb.cpus   = 1
      vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    end

    spoke.vm.provision "shell" do |s|
      s.path = "scripts/spoke.sh"
      s.env  = { "HUB_IP" => HUB_IP }
    end
  end
end
