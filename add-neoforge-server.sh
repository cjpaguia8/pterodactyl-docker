#!/usr/bin/env bash
# Creates a NeoForge Minecraft server in the panel. Safe to run again to add
# more servers. Usage: sudo bash add-neoforge-server.sh
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run this with sudo:  sudo bash add-neoforge-server.sh"
[ -f .env ] || die "Run sudo bash install.sh first."
docker compose ps --status running --services 2>/dev/null | grep -qx panel \
  || die "The panel isn't running. Start it with: sudo docker compose up -d"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Runs a PHP file inside the panel. Extra args (e.g. -e NAME=value) go to `docker compose exec`.
php_in_panel() {
  local file=$1; shift
  docker compose cp "$file" panel:/tmp/neoforge-step.php </dev/null >/dev/null 2>&1
  docker compose exec -T "$@" panel php artisan tinker /tmp/neoforge-step.php </dev/null 2>&1
}

# --- Egg ----------------------------------------------------------------------
say "Adding the NeoForge egg to the panel"
docker compose cp eggs/egg-pterodactyl-neo-forge.json panel:/tmp/neoforge-egg.json </dev/null >/dev/null 2>&1
cat > "$work/egg.php" <<'EOF'
<?php
use Pterodactyl\Models\{Egg, Nest};
if (Egg::where('name', 'NeoForge')->exists()) { echo "EGG_EXISTS\n"; return; }
$nest = Nest::where('name', 'Minecraft')->first() ?? Nest::firstOrFail();
$file = new Illuminate\Http\UploadedFile('/tmp/neoforge-egg.json', 'egg.json', 'application/json', null, true);
app(Pterodactyl\Services\Eggs\Sharing\EggImporterService::class)->handle($file, $nest->id);
echo "EGG_IMPORTED\n";
EOF
out=$(php_in_panel "$work/egg.php")
if   grep -q EGG_IMPORTED <<<"$out"; then echo "Imported."
elif grep -q EGG_EXISTS   <<<"$out"; then echo "Already there."
else echo "$out"; die "Couldn't add the NeoForge egg."
fi

# --- Questions ----------------------------------------------------------------
total_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
default_mem=4096
[ "$total_mb" -lt 6144 ] && default_mem=$(( total_mb / 2 ))

echo
read -rp "Server name [NeoForge]: " NF_NAME;              NF_NAME=${NF_NAME:-NeoForge}
read -rp "Minecraft version [1.21.1]: " NF_MC;             NF_MC=${NF_MC:-1.21.1}
read -rp "Memory in MB [${default_mem}]: " NF_MEM;         NF_MEM=${NF_MEM:-$default_mem}
read -rp "Disk space in MB [20000]: " NF_DISK;             NF_DISK=${NF_DISK:-20000}
[[ "$NF_MEM" =~ ^[0-9]+$ && "$NF_DISK" =~ ^[0-9]+$ ]] || die "Memory and disk must be numbers."

# NeoForge builds are numbered after the Minecraft version (MC 1.21.1 -> 21.1.x). The egg
# matches by prefix, so 1.21.1 would also match 21.11.x; pick the exact build here instead.
NF_BUILD=""
if [[ "$NF_MC" =~ ^1\.([0-9]+)(\.([0-9]+))?$ ]] && [ "$NF_MC" != "1.20.1" ]; then
  prefix="${BASH_REMATCH[1]}.${BASH_REMATCH[3]:-0}."
  builds=$(curl -fsSL https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml 2>/dev/null |
           sed -n 's:.*<version>\(.*\)</version>.*:\1:p' | awk -v p="$prefix" 'index($0, p) == 1' || true)
  # Newest stable build (the egg only accepts plain numbers, so no betas).
  NF_BUILD=$(grep -E '^[0-9.]+$' <<<"$builds" | tail -n 1 || true)
  if [ -n "$NF_BUILD" ]; then
    echo "Using NeoForge $NF_BUILD for Minecraft $NF_MC."
  else
    echo "No stable NeoForge build found for Minecraft $NF_MC; letting the egg choose."
  fi
fi

echo
echo "Minecraft servers only run if you accept Mojang's EULA: https://aka.ms/MinecraftEULA"
read -rp "Do you accept the Minecraft EULA? [y/N]: " eula

# --- Server -------------------------------------------------------------------
say "Creating the server"
cat > "$work/create.php" <<'EOF'
<?php
use Pterodactyl\Models\{Egg, Allocation, User};
$egg = Egg::where('name', 'NeoForge')->with('variables')->firstOrFail();
$alloc = Allocation::whereNull('server_id')->orderBy('port')->first();
if (!$alloc) { echo "NO_FREE_PORT\n"; return; }
$env = [];
foreach ($egg->variables as $v) { $env[$v->env_variable] = $v->default_value ?? ''; }
$env['MC_VERSION'] = getenv('NF_MC');
$env['NEOFORGE_VERSION'] = (string) getenv('NF_BUILD');
$images = $egg->docker_images;
$image = collect($images)->first(fn ($i) => str_contains($i, 'java_21')) ?? array_values($images)[0];
$server = app(Pterodactyl\Services\Servers\ServerCreationService::class)->handle([
    'name' => getenv('NF_NAME'),
    'owner_id' => User::where('root_admin', true)->orderBy('id')->firstOrFail()->id,
    'egg_id' => $egg->id,
    'nest_id' => $egg->nest_id,
    'allocation_id' => $alloc->id,
    'memory' => (int) getenv('NF_MEM'), 'swap' => 0, 'disk' => (int) getenv('NF_DISK'),
    'io' => 500, 'cpu' => 0,
    'startup' => $egg->startup,
    'image' => $image,
    'environment' => $env,
    'start_on_completion' => false,
    'database_limit' => 0, 'allocation_limit' => 0, 'backup_limit' => 1,
]);
echo "SERVER_UUID=" . $server->uuid . "\n";
echo "SERVER_PORT=" . $alloc->port . "\n";
EOF
out=$(php_in_panel "$work/create.php" -e NF_NAME="$NF_NAME" -e NF_MC="$NF_MC" -e NF_MEM="$NF_MEM" -e NF_DISK="$NF_DISK" -e NF_BUILD="$NF_BUILD")
grep -q NO_FREE_PORT <<<"$out" && die "No free game ports left. Add more under Admin > Nodes > Allocation."
uuid=$(sed -n 's/.*SERVER_UUID=\([0-9a-f-]*\).*/\1/p' <<<"$out")
port=$(sed -n 's/.*SERVER_PORT=\([0-9]*\).*/\1/p' <<<"$out")
[ -n "$uuid" ] || { echo "$out"; die "Couldn't create the server."; }
echo "Created \"$NF_NAME\" on port $port."

# --- Install, EULA, start -------------------------------------------------------
if [[ "$eula" =~ ^[Yy] ]]; then
  say "Installing NeoForge $NF_MC (downloads Minecraft, takes a few minutes)"
  cat > "$work/status.php" <<'EOF'
<?php
$s = Pterodactyl\Models\Server::where('uuid', getenv('NF_UUID'))->firstOrFail();
echo "STATUS=" . ($s->status ?? 'ok') . "|" . ($s->installed_at ? 'installed' : 'pending') . "\n";
EOF
  state=""
  for _ in $(seq 1 120); do
    state=$(php_in_panel "$work/status.php" -e NF_UUID="$uuid" | sed -n 's/.*STATUS=\([^ ]*\).*/\1/p')
    case "$state" in
      ok\|installed) break ;;
      install_failed*) die "The NeoForge install failed. Check the server's console in the panel." ;;
    esac
    sleep 5
  done
  [ "$state" = "ok|installed" ] || die "Install is taking unusually long. Check the server in the panel."

  dir=/var/lib/pterodactyl/volumes/$uuid
  echo "eula=true" > "$dir/eula.txt"
  chown 988:988 "$dir/eula.txt"

  say "Starting the server (first start takes a minute or two)"
  cat > "$work/start.php" <<'EOF'
<?php
$s = Pterodactyl\Models\Server::where('uuid', getenv('NF_UUID'))->firstOrFail();
app(Pterodactyl\Repositories\Wings\DaemonPowerRepository::class)->setServer($s)->send('start');
echo "STARTED\n";
EOF
  out=$(php_in_panel "$work/start.php" -e NF_UUID="$uuid")
  grep -q STARTED <<<"$out" || die "Couldn't start the server. Start it from the panel."
else
  echo
  echo "Not starting it. The server installs in the background; when you press Start in the"
  echo "panel it will ask you to accept the EULA."
fi

addr=$(sed -n 's/^PANEL_ADDRESS=//p' .env)
say "NeoForge server ready"
cat <<EOF

  Manage it at:        http://${addr}
  Join on home Wi-Fi:  ${addr}:${port}
  Add mods:            put .jar files in the server's "mods" folder (panel > Files), then restart.
EOF
if [ "$port" != "25565" ]; then
  echo "  playit.gg:           add a Minecraft Java tunnel for local port ${port} to join from outside."
fi
