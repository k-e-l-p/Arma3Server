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

The Arma 3 dedicated server (App ID 233780) is free but must be on the account. If you've never downloaded it
before, run this once on the host to claim the license:

```
steamcmd +login your_steam_username your_steam_password +app_license_request 233780 +quit
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
    -v ./mpmissions:/arma3/server/mpmissions \
    -v ./server:/arma3/server \
    -v $HOME/.local/share/Steam/config:/arma3/Steam/config \
    --env-file .env \
    arma3server
```

And you're done. The image updates itself every re-start.
Stopping: `podman stop arma3`  
(re)Starting: `podman start arma3`  
Log inspection: `podman logs arma3`

NOTE: The above commands assume a fully local, default-location
      Steam installation. The config folder will likely be located
      elsewhere is installed via Flatpak

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

## Steam Guard

The first time the container runs, Steam asks for a verification code. Do this once on the host:

```sh
steamcmd +login YOUR_USERNAME
# enter the code, then type: quit
podman restart arma3
```

This lets `steamcmd` create a persistent login session in `~/.local/share/Steam/config`.
Subsequent correct logins with `STEAM_USERNAME` and `STEAM_PASSWORD` will not ask for a
Steam Guard code again.

## Settings

Reference `.env.example` for a full list of settings available
through this image.

## Workshop mods

You can use an exported `.html` preset by dropping it into the
mounted `presets` folder (`./presets` by default) and setting
`MODS_PRESET=path_to_modpack.html` in `.env`.

Otherwise, http(s) links are also supported: `MODS_PRESET=https://example.com/path_to_modpack.html`

Local mods (not on the Workshop) go in `mods/` for client-side and `servermods/` for server-side.

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
