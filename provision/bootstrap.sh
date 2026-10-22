#!/usr/bin/env bash
set -euo pipefail
exec > >(tee -a /var/log/tws-bootstrap.log) 2>&1
umask 022
export DEBIAN_FRONTEND=noninteractive
cd /opt/tws-provision
run_hooks() { local stage="$1"; while IFS= read -r script; do bash "$script"; done < <(find "hooks/$stage" -maxdepth 1 -type f -name '*.sh' | sort); }
# A root-owned boot updater applies the latest deployed user-data configuration.
install -o root -g root -m 0755 files/tws-apply-user-data /usr/local/sbin/tws-apply-user-data
install -o root -g root -m 0644 files/tws-config-update.service /etc/systemd/system/tws-config-update.service
systemctl daemon-reload
systemctl enable tws-config-update.service
run_hooks pre-install
mapfile -t packages < <(sed 's/#.*//; /^[[:space:]]*$/d' packages.txt)
apt-get -o DPkg::Lock::Timeout=600 update
apt-get -o DPkg::Lock::Timeout=600 install -y "${packages[@]}"
# Start at boot, without enrolling or changing an existing tailnet identity.
systemctl enable --now tailscaled.service
systemctl stop xrdp xrdp-sesman || true
# Match the Nitro NVMe serial to the configured volume ID. Never guess /dev/nvme1n1.
serial="${DATA_VOLUME_ID//-/}"
disk=""
for attempt in $(seq 1 120); do
  disk=$(lsblk -dn -o PATH,SERIAL | awk -v serial="$serial" '$2==serial {print $1}')
  [ -n "$disk" ] && break
  sleep 2
done
[ -n "$disk" ] && [ -b "$disk" ] || { echo 'Data disk not found'; exit 1; }
fs=$(blkid -s TYPE -o value "$disk" || true)
if [ -z "$fs" ]; then
  # Only initialize a completely blank disk, never a partitioned or unknown disk.
  [ -z "$(wipefs -n --noheadings "$disk")" ] || { echo 'Unexpected disk signatures'; exit 1; }
  [ "$(lsblk -nr "$disk" | wc -l)" -eq 1 ] || { echo 'Unexpected partitions'; exit 1; }
  mkfs.ext4 -L tws-data "$disk"
elif [ "$fs" != ext4 ]; then
  echo "Unsupported data filesystem: $fs"; exit 1
fi
mkdir -p /srv/tws
uuid=$(blkid -s UUID -o value "$disk")
add_fstab() { grep -qxF "$1" /etc/fstab || printf '%s\n' "$1" >> /etc/fstab; }
add_fstab "UUID=$uuid /srv/tws ext4 defaults 0 2"
mountpoint -q /srv/tws || mount /srv/tws
# Grow the filesystem after dataGiB is increased; a no-op when sizes already match.
resize2fs "$disk"
id trader &>/dev/null || useradd --uid 1100 --create-home --shell /bin/bash trader
[ "$(id -u trader)" = 1100 ] || { echo 'Unexpected trader UID'; exit 1; }
# Administrator access for the SSH-key-authenticated workstation owner.
usermod -aG sudo trader
visudo -cf files/tws-trader-sudoers
install -o root -g root -m 0440 files/tws-trader-sudoers /etc/sudoers.d/90-trader-admin
visudo -c
install -o root -g root -m 0755 files/tws-shutdown-checks /usr/local/sbin/tws-shutdown-checks

if [ ! -d /srv/tws/home ]; then
  mkdir /srv/tws/home
  cp -a /home/trader/. /srv/tws/home/
  chown -R trader:trader /srv/tws/home
fi
add_fstab '/srv/tws/home /home/trader none bind 0 0'
mountpoint -q /home/trader || mount /home/trader
# Public-key authentication only, independent of the password used for RDP.
install -d -o root -g root -m 0755 /etc/ssh/authorized_keys /run/sshd
if [ -n "$SSH_AUTHORIZED_KEYS_B64" ]; then
  printf '%s' "$SSH_AUTHORIZED_KEYS_B64" | base64 --decode > /etc/ssh/authorized_keys/trader
  printf '\n' >> /etc/ssh/authorized_keys/trader
  chmod 0644 /etc/ssh/authorized_keys/trader
  ssh-keygen -l -f /etc/ssh/authorized_keys/trader >/dev/null
fi
install -m 0644 files/tws-sshd.conf /etc/ssh/sshd_config.d/00-tws.conf
install -d /etc/systemd/system/ssh.service.d
printf '[Unit]\nRequiresMountsFor=/home/trader\n' > /etc/systemd/system/ssh.service.d/persistent-home.conf
/usr/sbin/sshd -t
bash files/install-herdr.sh
# Standard RDP listener; the EC2 security group allows one configured client IPv4.
sed -i '0,/^port=/{s|^port=.*|port=tcp://0.0.0.0:3389|;}' /etc/xrdp/xrdp.ini
# Require TLS for the direct RDP connection.
sed -i 's/^security_layer=.*/security_layer=tls/' /etc/xrdp/xrdp.ini
# Preserve the remote desktop session when the client disconnects.
sed -i 's/^KillDisconnected=.*/KillDisconnected=false/; s/^DisconnectedTimeLimit=.*/DisconnectedTimeLimit=0/' /etc/xrdp/sesman.ini
# Larger send buffer for smoother screen updates; net.core.wmem_max is raised in the overlay sysctl file.
if grep -Eq '^#?tcp_send_buffer_bytes=' /etc/xrdp/xrdp.ini; then
  sed -i 's/^#\?tcp_send_buffer_bytes=.*/tcp_send_buffer_bytes=4194304/' /etc/xrdp/xrdp.ini
else
  sed -i '0,/^\[Globals\]/{s/^\[Globals\]/[Globals]\ntcp_send_buffer_bytes=4194304/;}' /etc/xrdp/xrdp.ini
fi
mkdir -p /etc/systemd/system/xrdp.service.d /etc/systemd/system/xrdp-sesman.service.d
for service in xrdp xrdp-sesman; do
  printf '[Unit]\nRequiresMountsFor=/home/trader\n' > "/etc/systemd/system/$service.service.d/persistent-home.conf"
done
adduser xrdp ssl-cert
if [ ! -f /home/trader/.xsession ]; then
  printf 'exec startxfce4\n' > /home/trader/.xsession
  chown trader:trader /home/trader/.xsession
fi
mkdir -p /home/trader/.config/autostart
# Remove the obsolete desktop autostart entry when reusing a persistent home.
rm -f /home/trader/.config/autostart/tws-s3.desktop
# Reconcile an existing mount before changing its configuration, without forced unmounts.
if mountpoint -q /mnt/watchlists; then
  sync -f /mnt/watchlists
  umount /mnt/watchlists
fi
if systemctl is-active --quiet tws-s3fs.service; then systemctl stop tws-s3fs.service; fi
if [ -z "$S3_BUCKET" ] && [ -f /etc/systemd/system/tws-s3fs.service ]; then
  systemctl disable tws-s3fs.service
fi
if [ -n "$S3_BUCKET" ]; then
  install -d -o trader -g trader -m 0755 /mnt/watchlists
  install -m 0755 files/tws-fetch-s3-credentials /usr/local/sbin/tws-fetch-s3-credentials
  install -m 0755 files/tws-mount-s3 /usr/local/sbin/tws-mount-s3
  install -m 0755 files/tws-wait-s3 /usr/local/sbin/tws-wait-s3
  install -m 0644 files/tws-s3fs.service /etc/systemd/system/tws-s3fs.service
  umask 077
  cat > /etc/tws-s3.env <<EOF
S3_BUCKET=$S3_BUCKET
S3_PREFIX=$S3_PREFIX
S3_REGION=$S3_REGION
S3_WRITABLE=$S3_WRITABLE
AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION
PARAM_STORE_KEY_S3_PASSWD=$PARAM_STORE_KEY_S3_PASSWD
EOF
  chmod 0600 /etc/tws-s3.env
  umask 022
fi
# Managed root overlay: provision/files/rootfs/etc/... becomes /etc/...
# Preserve existing system-directory permissions when merging the overlay.
tar -C files/rootfs -cf - . | tar -C / --no-same-owner --no-same-permissions --no-overwrite-dir -xf -
chown -R trader:trader /home/trader/.config
sysctl --system >/dev/null
run_hooks post-install
if [ ! -e /srv/tws/.first-use-complete ]; then
  run_hooks first-use
  touch /srv/tws/.first-use-complete
fi
install -m 0644 files/tws-custom-boot.service /etc/systemd/system/tws-custom-boot.service
systemctl daemon-reload
if [ -n "$S3_BUCKET" ]; then systemctl enable --now tws-s3fs.service; fi
systemctl enable tws-custom-boot.service
# Avoid waiting for a service ordered after the updater that is running us.
systemctl --no-block start tws-custom-boot.service
systemctl enable --now ssh.service
systemctl restart ssh.service
# Ubuntu package installation can leave an older sshd listener outside the
# service's MainPID. Reload every master listener so none keeps pre-bootstrap
# authentication settings; established SSH sessions remain connected.
while read -r listener; do
  kill -HUP "$listener"
done < <(ps -eo pid=,ppid=,args= | awk '$2 == 1 && /sshd:.*\[listener\]/ {print $1}')
runuser -u trader -- sudo -n true
systemctl enable --now xrdp-sesman.service xrdp.service
# Record the exact successful configuration; failures are retried next boot.
/usr/local/sbin/tws-apply-user-data --record
touch /var/lib/tws-bootstrap-complete
echo 'Bootstrap complete. SSH as trader for passwordless sudo; run sudo passwd trader if you want to log in through RDP.'
