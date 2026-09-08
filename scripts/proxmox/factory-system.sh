#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run as root inside the factory guest.' >&2; exit 1; }
[[ -f /var/lib/cloud/instance/user-data.txt ]] || { echo 'Not a cloud guest.' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
# Report a network/allowlist blocker before apt's partial-index fallback can
# misleadingly turn it into dozens of "package not found" errors.
curl --fail --silent --show-error --head --connect-timeout 10 --max-time 20 \
  https://deb.debian.org/debian/ > /dev/null || {
    echo 'Factory internet preflight failed. Check DHCP, DNS and upstream MAC allowlists.' >&2
    exit 1
  }
apt-get -o APT::Update::Error-Mode=any update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg git sudo openssh-server qemu-guest-agent \
  build-essential autoconf m4 pkg-config libncurses-dev libssl-dev \
  libwxgtk3.2-dev libgl1-mesa-dev libglu1-mesa-dev libpng-dev \
  libssh-dev unixodbc-dev xsltproc fop libxml2-utils unzip zip \
  sqlite3 libsqlite3-dev libasound2-dev portaudio19-dev libopus-dev \
  podman uidmap slirp4netns fuse-overlayfs dbus-user-session bubblewrap \
  nftables jq ripgrep shellcheck python3 python3-venv rsync

install -d -m 0755 /etc/apt/keyrings
curl --fail --location --proto '=https' --proto-redir '=https' \
  https://mise.jdx.dev/gpg-key.pub -o /etc/apt/keyrings/mise-archive-keyring.asc
printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/mise-archive-keyring.asc] https://mise.jdx.dev/deb stable main' \
  > /etc/apt/sources.list.d/mise.list
apt-get -o APT::Update::Error-Mode=any update
apt-get install -y mise

# The factory operator is trusted. ACP workers never inherit this OS account's
# SSH key or sudo access through this script; Arbor owns their containment.
install -d -o arbor -g arbor -m 0700 /home/arbor/.arbor /home/arbor/.arbor/tmp
grep -q '^arbor:' /etc/subuid
grep -q '^arbor:' /etc/subgid
loginctl enable-linger arbor
runuser -u arbor -- env XDG_RUNTIME_DIR="/run/user/$(id -u arbor)" systemctl --user daemon-reload
runuser -u arbor -- env XDG_RUNTIME_DIR="/run/user/$(id -u arbor)" systemctl --user start dbus.socket
printf '%s\n' 'PermitRootLogin no' 'PasswordAuthentication no' \
  'KbdInteractiveAuthentication no' 'AllowUsers arbor' > /etc/ssh/sshd_config.d/00-arbor.conf
sshd -t
systemctl restart ssh

# Keep dev-only HTTP, database, EPMD, and BEAM distribution off the LAN.
# Access HTTP using operator-owned SSH local forwards. Do not alter PVE networking.
printf '%s\n' '#!/usr/sbin/nft -f' 'flush ruleset' \
  'table inet arbor_factory {' \
  ' chain input { type filter hook input priority 0; policy drop;' \
  '  iifname "lo" accept' '  ct state established,related accept' \
  '  tcp dport 22 accept' '  udp sport 67 udp dport 68 accept' \
  '  ip protocol icmp accept' '  meta l4proto ipv6-icmp accept' ' }' \
  ' chain forward { type filter hook forward priority 0; policy drop; }' \
  ' chain output { type filter hook output priority 0; policy accept; }' '}' \
  > /etc/nftables.conf
nft -c -f /etc/nftables.conf
systemctl enable --now nftables qemu-guest-agent
dpkg-query -W > /var/log/arbor-factory-packages.txt
touch /var/lib/arbor-factory-system-ready
