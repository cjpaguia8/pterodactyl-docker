#!/usr/bin/env bash
# First-time setup of Pterodactyl Panel + Wings in Docker.
# Usage: sudo bash install.sh
set -euo pipefail
cd "$(dirname "$0")"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
trap 'if [ -f .env ] && [ ! -f admin-credentials.txt ]; then printf "\nSetup did not finish. To start over: sudo docker compose down -v && sudo rm .env && sudo bash install.sh\n" >&2; fi' EXIT

[ "$(id -u)" -eq 0 ] || die "Run this with sudo:  sudo bash install.sh"
[ -f .env ] && die "Already installed (.env exists). To start it: sudo docker compose up -d"

# --- Docker -----------------------------------------------------------------
if command -v snap >/dev/null && snap list docker >/dev/null 2>&1; then
  die "Docker is installed as a snap, which can't run Wings. Remove it (sudo snap remove docker) and re-run."
fi
if ! command -v docker >/dev/null; then
  say "Installing Docker"
  curl -fsSL https://get.docker.com | sh
fi
command -v systemctl >/dev/null && systemctl enable --now docker >/dev/null 2>&1 || true
docker compose version >/dev/null 2>&1 || die "Docker is installed but 'docker compose' is missing. Install the docker-compose-plugin package."

# --- Ports ------------------------------------------------------------------
for p in 80 8080 2022; do
  if ss -ltnH "sport = :$p" | grep -q .; then
    die "Port $p is already in use (probably the old native install). Run sudo bash remove-old-native-install.sh first."
  fi
done

# --- Questions --------------------------------------------------------------
default_ip=$(hostname -I | awk '{print $1}')
echo
echo "What address will people type in their browser to reach the panel?"
echo "Use this laptop's IP (${default_ip}) for your home network, or a domain name if you have one."
read -rp "Panel address [${default_ip}]: " PANEL_ADDRESS
PANEL_ADDRESS=${PANEL_ADDRESS:-$default_ip}
PANEL_ADDRESS=${PANEL_ADDRESS#http://}; PANEL_ADDRESS=${PANEL_ADDRESS#https://}; PANEL_ADDRESS=${PANEL_ADDRESS%/}

read -rp "Admin username [admin]: " ADMIN_USER;          ADMIN_USER=${ADMIN_USER:-admin}
read -rp "Admin email [admin@example.com]: " ADMIN_EMAIL; ADMIN_EMAIL=${ADMIN_EMAIL:-admin@example.com}
read -rp "Game server ports [25565-25575]: " PORTS;       PORTS=${PORTS:-25565-25575}

TZ_NAME=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)
secret() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$1" || true; }
ADMIN_PASS=$(secret 20)

umask 077
cat > .env <<EOF
PANEL_ADDRESS=${PANEL_ADDRESS}
TZ=${TZ_NAME}
DB_PASSWORD=$(secret 32)
DB_ROOT_PASSWORD=$(secret 32)
EOF
umask 022

# --- Panel ------------------------------------------------------------------
say "Downloading and starting the panel (first run takes a few minutes)"
docker compose pull -q
docker compose up -d database cache panel

say "Waiting for the panel to finish setting up its database"
for i in $(seq 1 100); do
  curl -fs -o /dev/null http://localhost/auth/login && break
  [ "$i" -eq 100 ] && die "Panel didn't come up. Check: sudo docker compose logs panel"
  sleep 3
done

artisan() { docker compose exec -T panel php artisan "$@" </dev/null; }

say "Creating admin account, location and node"
artisan p:user:make --email="$ADMIN_EMAIL" --username="$ADMIN_USER" \
  --name-first=Admin --name-last=User --password="$ADMIN_PASS" --admin=1 -n >/dev/null
artisan p:location:make --short=home --long="Home" -n >/dev/null

mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
mkdir -p /var/lib/pterodactyl
disk_mb=$(df -Pm /var/lib/pterodactyl | awk 'NR==2 {print $4}')
artisan p:node:make --name="$(hostname)" --description="This laptop" --locationId=1 \
  --fqdn="$PANEL_ADDRESS" --public=1 --scheme=http --proxy=0 --maintenance=0 \
  --maxMemory="$mem_mb" --overallocateMemory=0 --maxDisk="$disk_mb" --overallocateDisk=0 \
  --uploadSize=100 --daemonListeningPort=8080 --daemonSFTPPort=2022 \
  --daemonBase=/var/lib/pterodactyl/volumes -n >/dev/null

artisan tinker --execute="app(Pterodactyl\Services\Allocations\AssignmentService::class)->handle(Pterodactyl\Models\Node::find(1), ['allocation_ip' => '0.0.0.0', 'allocation_alias' => '${PANEL_ADDRESS}', 'allocation_ports' => ['${PORTS}']]);" >/dev/null

# --- Wings ------------------------------------------------------------------
say "Configuring Wings"
mkdir -p /etc/pterodactyl /var/log/pterodactyl /tmp/pterodactyl
artisan p:node:configuration 1 --format=yaml > /etc/pterodactyl/config.yml
# Wings' default game network (172.18.0.0/16) often clashes with the compose network.
cat >> /etc/pterodactyl/config.yml <<'EOF'
docker:
  network:
    interface: 172.30.0.1
    name: pterodactyl_nw
    network_mode: pterodactyl_nw
    interfaces:
      v4:
        subnet: 172.30.0.0/16
        gateway: 172.30.0.1
EOF
chmod 600 /etc/pterodactyl/config.yml

docker compose up -d wings

say "Checking the panel can talk to Wings"
ok=0
for i in $(seq 1 20); do
  if artisan tinker --execute="app(Pterodactyl\Repositories\Wings\DaemonConfigurationRepository::class)->setNode(Pterodactyl\Models\Node::find(1))->getSystemInformation(); echo 'WINGS_OK';" 2>/dev/null | grep -q WINGS_OK; then
    ok=1; break
  fi
  sleep 3
done
[ "$ok" -eq 1 ] || die "Wings didn't respond. Check: sudo docker compose logs wings"

cat > admin-credentials.txt <<EOF
Panel:    http://${PANEL_ADDRESS}
Username: ${ADMIN_USER}
Email:    ${ADMIN_EMAIL}
Password: ${ADMIN_PASS}
EOF
chmod 600 admin-credentials.txt

say "Done!"
cat <<EOF

  Panel:     http://${PANEL_ADDRESS}
  Username:  ${ADMIN_USER}
  Password:  ${ADMIN_PASS}

  (Also saved in $(pwd)/admin-credentials.txt - change the password after logging in.)

  Everything starts by itself when the laptop boots.
EOF

say "Setting up the NeoForge Minecraft server"
bash ./add-neoforge-server.sh || echo "NeoForge setup didn't finish. Retry with: sudo bash add-neoforge-server.sh"
