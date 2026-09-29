#!/usr/bin/env bash
# Connects this machine to playit.gg so people outside the house can join
# game servers without port forwarding.
# Usage: sudo bash setup-playit.sh
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run this with sudo:  sudo bash setup-playit.sh"
[ -f .env ] || die "Run sudo bash install.sh first."

cat <<'EOF'

1. On any computer or phone, open this page and sign up or log in:

     https://playit.gg/account/setup/wizard/new-account/docker/docker-name

2. Give the agent a name (e.g. "laptop") and continue.
3. It shows a secret key. Copy it and paste it below.

EOF
read -rp "playit secret key: " key
key=$(printf '%s' "$key" | tr -d '[:space:]')
[ -n "$key" ] || die "No key entered."

# Replace any earlier playit settings in .env
sed -i '/^PLAYIT_SECRET_KEY=/d; /^COMPOSE_PROFILES=/d' .env
printf 'PLAYIT_SECRET_KEY=%s\nCOMPOSE_PROFILES=playit\n' "$key" >> .env

say "Starting the playit agent"
docker compose up -d playit
sleep 10
if docker compose logs playit 2>&1 | grep -qi "secret is not valid"; then
  docker compose stop playit >/dev/null 2>&1
  die "playit rejected that key. Copy the whole key again from the playit.gg page and re-run: sudo bash setup-playit.sh"
fi
docker compose logs --tail 15 playit

say "Almost done - finish on the playit.gg website:"
cat <<'EOF'

  1. The website should now show the agent as connected.
  2. Click "Add Tunnel" (or "Create Tunnel"):
       - Tunnel type:   Minecraft Java
       - Local address: 127.0.0.1
       - Local port:    25565
  3. playit gives you an address like  something.joinmc.link
     That's what friends type into Minecraft to join.

  For more game servers, add another tunnel with that server's port.
EOF
