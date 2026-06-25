# Arma 3 Server

This is a Docker/Podman container image to run an ArmA3 server.
Inspired by/Forked from:
* [BrettMayson/Arma3Server](https://github.com/BrettMayson/Arma3Server)
* [IPS-Hosting/game-images](https://github.com/IPS-Hosting/game-images/tree/main/arma3)

## Running

To run, you will need a Linux machine with `podman` installed.

Clone this repository, copy `.env.example` to `.env` and fill in your Steam login:
```
STEAM_USER=your_steam_username
STEAM_PASSWORD=your_steam_password
```

Then, build the image and run it:
```sh
podman build -t arma3server .
podman run -d --name arma3 --restart always \
    --network host \
    -v ./configs:/arma3/server/configs \
    -v ./presets:/arma3/server/presets \
    -v ./mods:/arma3/server/mods \
    -v ./servermods:/arma3/server/servermods \
    -v ./server:/arma3/server \
    -v $HOME/.local/share/Steam/config:/arma3/Steam/config \
    --env-file .env \
    arma3server
```

And you're done. The image updates itself every re-start.
Stopping: `podman stop arma3`  
(re)Starting: `podman start arma3`  
Log inspection: `podman logs arma3`

## Volumes

As mentioned, this is a podman/docker container image. Containers
are built to be heavily isolated. To share files between the main host
system and the container, a volume mounting system is employed.

The above `podman run -d [...]` command is just an example
that happens to mount every volume to a folder in the root
of this repository. The actual paths of those folders can
be whatever you want.

Quick volume mount explanation: Take `-v ./configs:/arma3/server/configs`:
* `-v` specifies that a volume is being defined
* `./configs` is the path that is **On The Host** 
* `:` is the separator
* `/arma3/server/configs` is the path that is **Inside The Container**

The end result is that `./configs` on your actual computer is now effectively
mirrored to `/arma3/server/configs` inside the container.

## Volume mount guide

* `/arma3/server/configs` -- all `.cfg` files piped to Arma.
* `/arma3/server/presets` -- mod preset `.html` files.
* `/arma3/server/mods` -- client-side mods.
* `/arma3/server/servermods` -- server-side mods.
* `/arma3/server/mpmissions` -- missions.
* `/arma3/server/` -- the server install, workshop cache, keys. Auxiliary.
* `/arma3/Steam/config` -- mounted directly from your host. Handles Steam login persistence.


## Workshop mods

1. Export a preset from the Arma 3 Launcher (the `.html` file).
2. Drop it in `presets/`.
3. In `.env`: `MODS_PRESET=thatfile.html`

The container downloads them every start. All files must be **lowercase** with underscores instead of spaces. The entrypoint handles this automatically.

If your preset is hosted online: `MODS_PRESET=https://example.com/modlist.html`

Local mods (not on the Workshop) go in `mods/` or `servermods/`.

## Steam Guard

The first time the container runs, Steam asks for a verification code. Do this once on the host:

```sh
steamcmd +login YOUR_USERNAME
# enter the code, then type: quit
podman restart arma3
```

The login session is persisted in `~/.local/share/Steam/config` — already mounted into the container. After one login it won't ask again.

## Settings

Everything goes in `.env`. Common ones:

| Variable | Default | What it does |
|----------|---------|--------------|
| `PORT` | `2302` | Game port (also uses +1 through +4) |
| `ARMA_LIMITFPS` | `50` | Server FPS cap |
| `ARMA_WORLD` | `empty` | World to load |
| `ARMA_CONFIG` | `main.cfg` | Config filename inside `configs/` |
| `STEAM_BRANCH` | `public` | Branch. Set to `creatordlc` for CDLCs |
| `ARMA_CDLC` | | CDLC codes, semicolons. e.g. `ws;gm` |
| `MODS_LOCAL` | `true` | Load mods from `mods/` and `servermods/` |
| `HEADLESS_CLIENTS` | `0` | Number of headless clients |
| `SKIP_INSTALL` | `false` | Skip the auto-update on restart |

Full list: `.env.example`.

## Creator DLC

`STEAM_BRANCH=creatordlc` and `ARMA_CDLC=ws;gm;spe` or similar.

```
csla · gm · vn · ws · spe · rf · ef
```

## Ports

The container uses host networking. All 5 are required to be open on your firewall.

```
2302 ─ game
2303 ─ Steam query
2304 ─ Steam master
2305 ─ voice (VON)
2306 ─ BattlEye
```
