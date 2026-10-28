#!/bin/bash
# Proxmox host steps for gpu-workstation -> pve. Run as root:  curl -sL https://raw.githubusercontent.com/qvuer7/pve/master/s.sh | bash
set -u
LOG=/root/pve-steps.log; exec > >(tee -a "$LOG") 2>&1
echo "=================== STEP 1: vfio for the RTX 5090  ($(date -Is))"
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

echo "--- which GPU drives the monitor?"
stop=0
for s in /sys/class/drm/card*-*/status; do
  [ "$(cat "$s" 2>/dev/null)" = connected ] || continue
  c=$(dirname "$s"); card=${c%%-*}; dev=$(basename "$(readlink -f "$card/device")")
  echo "monitor on $(basename "$c") -> PCI $dev"
  [ "$dev" = 0000:01:00.0 ] && stop=1
done
if [ $stop = 1 ]; then
  echo "STOP: the monitor is plugged into the RTX 5090. Move the cable to the motherboard's HDMI/DP port, then run this again."
  exit 1
fi

echo "--- vfio config (GPU ids only; NVMe stays on the host)"
printf 'options vfio-pci ids=10de:2b85,10de:22e8\nsoftdep nouveau pre: vfio-pci\nsoftdep nova_core pre: vfio-pci\nsoftdep nvidiafb pre: vfio-pci\n' > /etc/modprobe.d/vfio.conf
printf 'blacklist nouveau\nblacklist nova_core\nblacklist nvidiafb\n' > /etc/modprobe.d/blacklist-nvidia.conf
grep -q '^vfio_pci$' /etc/modules || printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' >> /etc/modules
cat /etc/modprobe.d/vfio.conf

echo "--- apt: disable enterprise repos, enable no-subscription"
mkdir -p /root/disabled-repos
mv /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources /root/disabled-repos/ 2>/dev/null || true
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<'X'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
X
apt-get update -qq && apt-get install -y -qq zstd gdisk >/dev/null && echo "zstd + gdisk installed"

echo "--- initramfs"
update-initramfs -u -k all
echo
echo "=================== STEP 1 DONE. Now type:  reboot"
echo "After the reboot, log in as root and run the same curl line again (it becomes step 2)."
