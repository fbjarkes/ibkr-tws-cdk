#!/usr/bin/env bash
set -euo pipefail
exec > >(tee -a /var/log/tws-bootstrap.log) 2>&1
export DEBIAN_FRONTEND=noninteractive
cd /opt/tws-provision
run_hooks() { local stage="$1"; while IFS= read -r script; do bash "$script"; done < <(find "hooks/$stage" -maxdepth 1 -type f -name '*.sh' | sort); }
run_hooks pre-install
mapfile -t packages < <(sed 's/#.*//; /^[[:space:]]*$/d' packages.txt)
apt-get update
apt-get install -y "${packages[@]}"
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
printf 'UUID=%s /srv/tws ext4 defaults 0 2\n' "$uuid" >> /etc/fstab
mount /srv/tws
id trader &>/dev/null || useradd --uid 1100 --create-home --shell /bin/bash trader
[ "$(id -u trader)" = 1100 ] || { echo 'Unexpected trader UID'; exit 1; }
if [ ! -d /srv/tws/home ]; then
  mkdir /srv/tws/home
  cp -a /home/trader/. /srv/tws/home/
  chown -R trader:trader /srv/tws/home
fi
printf '/srv/tws/home /home/trader none bind 0 0\n' >> /etc/fstab
mount /home/trader
# Persist the Tailscale identity across exclusive desktop replacements.
curl --fail --location --retry 3 https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl --fail --location --retry 3 https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list
apt-get update
apt-get install -y tailscale
systemctl stop tailscaled
install -d -m 0700 /srv/tws/tailscale /var/lib/tailscale
printf '/srv/tws/tailscale /var/lib/tailscale none bind 0 0\n' >> /etc/fstab
mount /var/lib/tailscale
systemctl enable --now tailscaled
# RDP listens only on the Tailscale IPv4 address, never the public interface.
install -m 0755 files/tws-start-rdp /usr/local/sbin/tws-start-rdp
install -m 0644 files/tws-rdp.service /etc/systemd/system/tws-rdp.service
systemctl disable xrdp xrdp-sesman
adduser xrdp ssl-cert
if [ ! -f /home/trader/.xsession ]; then
  printf 'exec startxfce4\n' > /home/trader/.xsession
  chown trader:trader /home/trader/.xsession
fi
mkdir -p /home/trader/.config/autostart /home/trader/.config/rclone /home/trader/S3 /home/trader/.cache/rclone
if [ -n "$S3_BUCKET" ]; then
  cat > /home/trader/.config/rclone/tws.conf <<EOF
[tws]
type = s3
provider = AWS
env_auth = true
region = $AWS_DEFAULT_REGION
EOF
  if [ ! -f /home/trader/.config/rclone/rc-password ]; then
    head -c 32 /dev/urandom | base64 > /home/trader/.config/rclone/rc-password
  fi
  chmod 0600 /home/trader/.config/rclone/rc-password
  remote="tws:$S3_BUCKET"
  [ -z "$S3_PREFIX" ] || remote="$remote/${S3_PREFIX%/}"
  readonly_flag=--read-only
  [ "$S3_WRITABLE" != true ] || readonly_flag=''
  cat > /home/trader/.config/rclone/mount-s3.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
export RCLONE_RC_USER=tws
export RCLONE_RC_PASS=\$(cat /home/trader/.config/rclone/rc-password)
exec rclone mount $remote /home/trader/S3 --config /home/trader/.config/rclone/tws.conf --vfs-cache-mode full --cache-dir /home/trader/.cache/rclone --vfs-cache-max-size 20G --rc --rc-addr 127.0.0.1:5572 $readonly_flag
EOF
  chmod 0700 /home/trader/.config/rclone/mount-s3.sh
  cat > /home/trader/.config/autostart/tws-s3.desktop <<EOF
[Desktop Entry]
Type=Application
Name=TWS S3 mount
Exec=/home/trader/.config/rclone/mount-s3.sh
Terminal=false
EOF
fi
# Managed root overlay: provision/files/rootfs/etc/... becomes /etc/...
cp -a files/rootfs/. /
chown -R trader:trader /home/trader/.config
chmod 0700 /home/trader/.config/rclone
run_hooks post-install
if [ ! -e /srv/tws/.first-use-complete ]; then
  run_hooks first-use
  touch /srv/tws/.first-use-complete
fi
install -m 0644 files/tws-custom-boot.service /etc/systemd/system/tws-custom-boot.service
systemctl daemon-reload
systemctl enable --now tws-custom-boot.service
systemctl enable --now tws-rdp.service
touch /var/lib/tws-bootstrap-complete
echo 'Bootstrap complete. Enroll Tailscale and set trader password using SSM.'
