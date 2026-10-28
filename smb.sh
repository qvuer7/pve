#!/bin/bash
# Samba on the Ubuntu VM: per-user home shares + shared /data for the Windows VM.
# Run inside Ubuntu:  curl -sL https://raw.githubusercontent.com/qvuer7/pve/master/smb.sh | sudo bash
set -eu
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq samba >/dev/null && echo "samba installed"
[ -e /etc/samba/smb.conf.orig ] || cp /etc/samba/smb.conf /etc/samba/smb.conf.orig
cat > /etc/samba/smb.conf <<'X'
[global]
   workgroup = WORKGROUP
   server string = gpu-workstation
   server role = standalone server
   security = user
   map to guest = never
   # only the VM bridge / LAN and NetBird, never guests
   hosts allow = 10.80.16. 100.89. 127.
   log file = /var/log/samba/log.%m
   max log size = 1000
   # performance over the virtual link
   server multi channel support = yes
   socket options = TCP_NODELAY IPTOS_LOWDELAY
   # Windows-friendly
   vfs objects = fruit streams_xattr
   fruit:metadata = stream
   # unix extensions off so Windows sees plain folders
   unix extensions = no
   follow symlinks = yes
   wide links = no

[homes]
   comment = Home folder of %S
   path = /home/%S
   valid users = %S
   browseable = no
   read only = no
   create mask = 0644
   directory mask = 0755

[data]
   comment = /data (Lexar)
   path = /data
   valid users = @users nexlvl maksym-m vitalii-s
   read only = no
   browseable = yes
   create mask = 0664
   directory mask = 0775
   force group = users
X
testparm -s >/dev/null 2>&1 && echo "smb.conf OK"
# allow the users to write under /data as a group
for u in nexlvl maksym-m vitalii-s; do usermod -aG users "$u"; done
systemctl enable --now smbd >/dev/null; systemctl restart smbd
command -v ufw >/dev/null && ufw status | grep -q "Status: active" && ufw allow from 10.80.16.0/24 to any app Samba >/dev/null && echo "ufw: Samba allowed from the LAN"
systemctl is-active smbd
echo
echo "DONE. Now set a Samba password for each user (can differ from the Linux password):"
echo "   sudo smbpasswd -a nexlvl"
echo "   sudo smbpasswd -a maksym-m"
echo "   sudo smbpasswd -a vitalii-s"
echo "In Windows: File Explorer -> This PC -> Map network drive ->  \\\\10.80.16.10\\<username>  (own home)  and  \\\\10.80.16.10\\data"
