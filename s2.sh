#!/bin/bash
# Proxmox host steps for gpu-workstation -> pve. Run as root:  curl -sL https://raw.githubusercontent.com/qvuer7/pve/master/s.sh | bash
set -u
LOG=/root/pve-steps.log; exec > >(tee -a "$LOG") 2>&1
echo "=================== STEP 2: restore Ubuntu into VM 100  ($(date -Is))"
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

echo "--- vfio check"
lspci -nnk -s 01:00 | grep -E "^01|driver in use"
if ! lspci -nnk -s 01:00.0 | grep -q "driver in use: vfio-pci"; then
  echo "STOP: the GPU is not on vfio-pci. Did the reboot happen? Send a photo of this screen."; exit 1
fi
lspci -nnk | grep -A2 "Non-Volatile" | grep "driver in use" | grep -qv nvme && { echo "STOP: an NVMe controller is not on the nvme driver"; exit 1; }
echo "vfio OK, NVMe OK"

VMID=100; VMNAME=ubuntu; ROOT_SIZE_G=1450
DATA_UUID=1e2f18ee-83ce-4210-8cd9-af7bac9ce282
EFI_SERIAL=712DCCFC; BOOT_UUID=f153696e-aedb-4bcd-93d9-e6cd38e589b8
ROOT_UUID=23792789-7796-4fd4-9649-6b3c8716f995
LEXAR_PART=/dev/disk/by-id/nvme-Lexar_SSD_NQ790_4TB_QED444R000440P3100-part1
M=/mnt/restore

echo "--- Lexar"
[ -e "$LEXAR_PART" ] || { echo "STOP: Lexar partition not found"; ls /dev/disk/by-id/ | grep -i lexar; exit 1; }
[ "$(blkid -s UUID -o value "$LEXAR_PART")" = "$DATA_UUID" ] || { echo "STOP: Lexar UUID mismatch"; exit 1; }
mkdir -p /mnt/data "$M"
mountpoint -q /mnt/data || mount -o ro "$LEXAR_PART" /mnt/data
ARCHIVE=$(ls -t /mnt/data/backups/root-*.tar.zst | head -1)
echo "archive: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1)), /data mounted read-only"

if qm status $VMID >/dev/null 2>&1; then
  echo "VM $VMID already exists:"; qm config $VMID; echo "STOP: nothing done. Tell Claude."; exit 1
fi

echo "--- create VM $VMID"
qm create $VMID --name $VMNAME --machine q35 --bios ovmf --cpu host --cores 24 \
  --memory 65536 --balloon 0 --numa 1 --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-single --ostype l26 --agent 1 --onboot 0
qm set $VMID --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm set $VMID --scsi0 local-lvm:${ROOT_SIZE_G},discard=on,ssd=1,iothread=1
DISK=$(qm config $VMID | awk -F'[ ,]' '/^scsi0:/{print $2}' | sed 's#local-lvm:#/dev/pve/#')
[ -b "$DISK" ] || { echo "STOP: VM disk $DISK not found"; exit 1; }
echo "VM disk: $DISK"

echo "--- partition + format (old UUIDs kept)"
sgdisk --zap-all "$DISK" >/dev/null
sgdisk -n1:0:+1G -t1:ef00 -c1:EFI -n2:0:+2G -t2:8300 -c2:boot -n3:0:0 -t3:8300 -c3:root "$DISK" >/dev/null
LOOP=$(losetup -fP --show "$DISK"); sleep 2
mkfs.vfat -F32 -i $EFI_SERIAL "${LOOP}p1" >/dev/null
mkfs.ext4 -q -F -L boot -U $BOOT_UUID "${LOOP}p2"
mkfs.ext4 -q -F -L root -U $ROOT_UUID "${LOOP}p3"
mount "${LOOP}p3" "$M"; mkdir -p "$M/boot"; mount "${LOOP}p2" "$M/boot"
mkdir -p "$M/boot/efi"; mount "${LOOP}p1" "$M/boot/efi"

echo "--- extracting 740 GB archive: 30-60 min, progress every 2 min"
( while sleep 120; do echo "  ... $(df -h --output=used "$M" | tail -1 | tr -d ' ') restored so far ($(date +%H:%M))"; done ) & PROG=$!
zstd -dc "$ARCHIVE" | tar -C "$M" -xpf - --xattrs --xattrs-include='*' --acls --numeric-owner 2> /root/restore-tar.err
RC=("${PIPESTATUS[@]}"); kill $PROG 2>/dev/null; wait $PROG 2>/dev/null
echo "extract exit codes: zstd=${RC[0]} tar=${RC[1]} (tar warnings: $(wc -l < /root/restore-tar.err) lines in /root/restore-tar.err)"
[ "${RC[0]}" = 0 ] || { echo "STOP: zstd failed"; exit 1; }
[ "${RC[1]}" -le 1 ] || { echo "STOP: tar failed"; tail -5 /root/restore-tar.err; exit 1; }
[ -e "$M/boot/vmlinuz-7.0.0-34-generic" ] && [ -e "$M/etc/fstab" ] || { echo "STOP: kernel or fstab missing after extract"; exit 1; }

echo "--- boot chain for the new disk"
sed -i "s#^/dev/disk/by-id/dm-uuid-LVM-[^ ]* / #UUID=$ROOT_UUID / #" "$M/etc/fstab"
: > "$M/etc/crypttab"
fallocate -l 8G "$M/swap.img"; chmod 600 "$M/swap.img"; mkswap "$M/swap.img" >/dev/null
grep -E '^(UUID|/dev|/swap)' "$M/etc/fstab"
for d in dev dev/pts proc sys run; do mount --bind /$d "$M/$d"; done
chroot "$M" /bin/bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  update-initramfs -u -k all
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable --no-nvram
  update-grub
  ls /boot/efi/EFI/BOOT/'
for d in run sys proc dev/pts dev; do umount "$M/$d"; done
umount "$M/boot/efi" "$M/boot" "$M"; losetup -d "$LOOP"
umount /mnt/data

echo "--- attach /data (raw Lexar partition), the GPU, boot order"
qm set $VMID --scsi1 "$LEXAR_PART",ssd=1,discard=on
qm set $VMID --hostpci0 0000:01:00,pcie=1    # GPU for compute; the virtual VGA stays the console
qm set $VMID --boot order=scsi0
qm config $VMID
echo
echo "=================== STEP 2 DONE. Start the VM with:   qm start 100"
echo "Then watch it in the web UI console (https://10.80.16.11:8006, VM 100, Console) or on a monitor plugged into the 5090."
