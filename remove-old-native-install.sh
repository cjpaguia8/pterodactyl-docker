#!/usr/bin/env bash
# Removes a Pterodactyl Panel + Wings that was installed the normal (non-Docker)
# way, following the official docs. Docker itself is kept.
# Old game server files, the panel's .env and a database dump are moved to a
# backup folder instead of being deleted.
# Usage: sudo bash remove-old-native-install.sh
set -uo pipefail

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "Run this with sudo:  sudo bash remove-old-native-install.sh"; exit 1; }

BACKUP=/root/pterodactyl-old-$(date +%Y%m%d-%H%M%S)

cat <<EOF
This removes the old Pterodactyl install from this machine:
  - Wings and the panel queue worker (systemd services)
  - Old game server containers made by Wings
  - The panel website files (/var/www/pterodactyl) and its nginx config
  - The panel database and its cron job

These are MOVED to ${BACKUP} rather than deleted:
  - Game server files (/var/lib/pterodactyl), including worlds
  - Wings config (/etc/pterodactyl)
  - The panel's .env file and a dump of its database

Docker is kept.
EOF
read -rp "Type 'yes' to continue: " answer
[ "$answer" = "yes" ] || { echo "Cancelled."; exit 0; }
mkdir -p "$BACKUP"

say "Stopping old services"
for svc in wings pteroq; do
  systemctl disable --now "$svc" 2>/dev/null
  rm -f "/etc/systemd/system/$svc.service"
done
systemctl daemon-reload

if command -v docker >/dev/null; then
  say "Removing old game server containers"
  ids=$(docker ps -aq --filter label=Service=Pterodactyl)
  [ -n "$ids" ] && docker rm -f $ids >/dev/null
  docker network rm pterodactyl_nw >/dev/null 2>&1
fi

say "Backing up the panel"
[ -f /var/www/pterodactyl/.env ] && cp /var/www/pterodactyl/.env "$BACKUP/panel.env"
if command -v mysql >/dev/null && { systemctl is-active --quiet mariadb || systemctl is-active --quiet mysql; }; then
  mysqldump --databases panel > "$BACKUP/panel.sql" 2>/dev/null || rm -f "$BACKUP/panel.sql"
  mysql -e "DROP DATABASE IF EXISTS panel;" 2>/dev/null
  mysql -N -e "SELECT CONCAT('\'',User,'\'@\'',Host,'\'') FROM mysql.user WHERE User='pterodactyl';" 2>/dev/null |
    while read -r u; do mysql -e "DROP USER $u;"; done
fi

say "Removing panel files and nginx config"
rm -rf /var/www/pterodactyl
rm -f /etc/nginx/sites-enabled/pterodactyl.conf /etc/nginx/sites-available/pterodactyl.conf \
      /etc/nginx/conf.d/pterodactyl.conf
for user in root www-data; do
  if crontab -u "$user" -l 2>/dev/null | grep -q pterodactyl; then
    crontab -u "$user" -l | grep -v pterodactyl | crontab -u "$user" -
  fi
done

say "Moving Wings data and config to the backup folder"
[ -d /var/lib/pterodactyl ] && mv /var/lib/pterodactyl "$BACKUP/wings-data"
[ -d /etc/pterodactyl ]     && mv /etc/pterodactyl "$BACKUP/wings-config"
rm -rf /var/log/pterodactyl /tmp/pterodactyl
rm -f /usr/local/bin/wings
id pterodactyl >/dev/null 2>&1 && userdel pterodactyl 2>/dev/null

echo
echo "The old panel also needed nginx, MariaDB, Redis and PHP. The Docker version"
echo "doesn't use them, and nginx blocks port 80 which the new panel needs."
read -rp "Uninstall nginx, MariaDB, Redis, PHP and Composer too? [Y/n]: " purge
if [[ ! "$purge" =~ ^[Nn] ]]; then
  say "Uninstalling old panel software"
  systemctl disable --now nginx mariadb mysql redis-server redis 2>/dev/null
  pkgs=$(dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null |
         awk '/ installed$/ && $1 ~ /^(nginx|mariadb-|mysql-|redis|php)/ {print $1}')
  if [ -n "$pkgs" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y $pkgs >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null
  fi
  rm -f /usr/local/bin/composer
  # Extra apt repos the Pterodactyl docs have you add
  rm -f /etc/apt/sources.list.d/redis.list /etc/apt/sources.list.d/mariadb.list \
        /etc/apt/sources.list.d/ondrej-*.list /etc/apt/sources.list.d/ondrej-*.sources
  apt-get update -qq >/dev/null 2>&1
else
  say "Stopping nginx so port 80 is free"
  systemctl disable --now nginx 2>/dev/null
fi

say "Done"
echo "Backup is in ${BACKUP}  (delete it once you're sure you don't need it)."
echo "Now run:  sudo bash install.sh"
