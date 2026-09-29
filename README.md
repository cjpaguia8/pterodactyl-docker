# Pterodactyl (Docker) for the Ubuntu laptop

## First-time setup

1. Download this onto the laptop:

       sudo git clone https://github.com/cjpaguia8/pterodactyl-docker.git /opt/pterodactyl
       cd /opt/pterodactyl

2. If Pterodactyl was installed on the laptop before (the normal way, not Docker), remove it first:

       sudo bash remove-old-native-install.sh

   Old worlds and settings are moved to `/root/pterodactyl-old-<date>`, not deleted.
3. Install:

       sudo bash install.sh

   Press Enter to accept the defaults. At the end it prints the panel address and admin password,
   and saves them in `admin-credentials.txt`.

Everything starts automatically when the laptop boots. There's nothing to run day to day.

## Handy commands (run inside this folder)

| Task | Command |
|---|---|
| See if it's running | `sudo docker compose ps` |
| Restart everything | `sudo docker compose restart` |
| Update Pterodactyl | `sudo docker compose pull && sudo docker compose up -d` |
| Get the latest version of these scripts | `sudo git pull` |
| Look at Wings logs | `sudo docker compose logs -f wings` |
| Look at panel logs | `sudo docker compose logs -f panel` |

## Keep the laptop's IP address fixed

The panel address is the laptop's IP. If the router hands the laptop a different IP later, the panel
stops working. In the router's settings, give the laptop a **DHCP reservation** (also called a static
lease) so its IP never changes.

## Playing from outside the house (playit.gg)

Friends on the same Wi-Fi can connect straight away using the laptop's IP.

For people outside the house, use playit.gg. Many internet providers share one public IP between
customers (CGNAT), so router port forwarding doesn't work. playit gets around that for free.

    cd /opt/pterodactyl
    sudo git pull
    sudo bash setup-playit.sh

The script tells you what to do on the playit.gg website. At the end you get an address like
`something.joinmc.link` that friends type into Minecraft. It keeps working after reboots.

| Task | Command |
|---|---|
| Check playit is connected | `sudo docker compose logs --tail 30 playit` |
| Use a different playit key | `sudo bash setup-playit.sh` again |

## Where things live

| What | Where |
|---|---|
| Game server files | `/var/lib/pterodactyl/volumes` |
| Wings config | `/etc/pterodactyl/config.yml` |
| Panel database and settings | Docker volumes named `pterodactyl_*` |
| Database passwords | `.env` in this folder. **Don't delete it.** |

## Remove everything (including all game servers)

    sudo docker compose down -v
    sudo docker rm -f $(sudo docker ps -aq --filter label=Service=Pterodactyl)
    sudo docker network rm pterodactyl_nw
    sudo rm -rf /var/lib/pterodactyl /etc/pterodactyl /var/log/pterodactyl
