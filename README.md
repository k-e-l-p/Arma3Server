# Arma 3 Dedicated Server

An Arma 3 Dedicated Server. Updates to the latest version on every restart.

Uses **steamcmd** to download and update the server and workshop mods.

## Usage

### docker-compose (recommended)

1. Copy the `.env.example` file to `.env` and fill in your `STEAM_USER` and `STEAM_PASSWORD`.
2. Place your missions in `./mpmissions/`, configs in `./configs/`, and mods in `./mods/` and `./servermods/`.
3. Run: `docker compose up -d`

### Docker CLI

```sh
docker create \
    --name=arma-server \
    -p 2302:2302/udp \
    -p 2303:2303/udp \
    -p 2304:2304/udp \
    -p 2305:2305/udp \
    -p 2306:2306/udp \
    -v ./configs:/arma3/server/configs \
    -v ./mods:/arma3/server/mods \
    -v ./servermods:/arma3/server/servermods \
    -v ./server:/arma3/server \
    -e STEAM_USER=myusername \
    -e STEAM_PASSWORD=mypassword \
    ghcr.io/brettmayson/arma3server/arma3server:v3
```

## Commands

The container supports three entrypoint commands:

| Command            | Behaviour                                                    |
| ------------------ | ------------------------------------------------------------ |
| *(default)*        | Update & validate the server, then start it.                 |
| `update`           | Only update the server and mods. Does not start.             |
| `update_validate`  | Update & validate server files. Does not start.              |
| `start`            | Only start the server. No update.                            |

## Environment Variables

### Steam credentials (required for update)

| Variable               | Default    | Description                              |
| ---------------------- | ---------- | ---------------------------------------- |
| `STEAM_USER`           | (required) | Steam account username.                  |
| `STEAM_PASSWORD`       | (required) | Steam account password.                  |
| `STEAM_BRANCH`         | `public`   | Steam beta branch to use.                |
| `STEAM_BRANCH_PASSWORD`|            | Password for the beta branch.            |

The Steam account does **not** need to own Arma 3, but must have Steam Guard disabled.

### Server settings

| Variable               | Default              | Description                                    |
| ---------------------- | -------------------- | ---------------------------------------------- |
| `ARMA_BINARY`          | `./arma3server_x64`  | Server binary to launch.                       |
| `ARMA_CONFIG`          | `main.cfg`           | Server config file (from `configs/` dir).      |
| `ARMA_BASIC_CONFIG`    | `basic.cfg`          | Basic network config file (from `configs/` dir). |
| `ARMA_PROFILE`         | `main`               | Profile name (stored in `configs/profiles`).   |
| `ARMA_WORLD`           | `empty`              | World to load on startup.                      |
| `ARMA_LIMITFPS`        | `50`                 | Maximum server FPS (5-1000).                   |
| `ARMA_PARAMS`          |                      | Additional Arma CLI parameters.                |
| `ARMA_CDLC`            |                      | CDLCs to load, semicolon-separated (e.g. `csla;gm`). |
| `PORT`                 | `2302`               | Game port.                                     |
| `SKIP_INSTALL`         | `false`              | Set to `true` to skip server update on start.  |

### Mods

| Variable               | Default              | Description                                    |
| ---------------------- | -------------------- | ---------------------------------------------- |
| `MODS_LOCAL`           | `true`               | Load mods from `mods/` and `servermods/` dirs. |
| `MODS_PRESET`          |                      | Path or URL to an Arma 3 Launcher HTML preset. |
| `MANAGED_MODS`         |                      | Space-separated workshop mod IDs to auto-download. |
| `EXTRACT_MOD_KEYS`     | `false`              | Copy `*.bikey` files from mods to `keys/`.     |
| `CLEAR_KEYS`           | `true`               | Clear `keys/` directory before every start.    |

### Headless clients

| Variable                   | Default            | Description                                 |
| -------------------------- | ------------------ | ------------------------------------------- |
| `HEADLESS_CLIENTS`         | `0`                | Number of headless clients to launch.       |
| `HEADLESS_CLIENTS_PROFILE` | `$profile-hc-$i`   | Profile name pattern. Supports `$profile`, `$i`, `$ii`. |

## Mods

### Local mods

Place mod folders in `./mods/` (client-side) and `./servermods/` (server-side only).
Mod folders and all their files **must be lowercase** and spaces replaced with underscores.

### Workshop mods (MODS_PRESET)

Export an HTML preset from the Arma 3 Launcher and reference it:

```sh
-e MODS_PRESET="my_mods.html"
-e MODS_PRESET="https://example.com/my_mods.html"
```

### MANAGED_MODS

For simpler setups, provide a space-separated list of workshop IDs:

```sh
-e MANAGED_MODS="463939057 450814997"
```

These mods are automatically downloaded via steamcmd and loaded.

## Creator DLC

Set `STEAM_BRANCH` to `creatordlc` and list CDLC codes in `ARMA_CDLC`:

| Name                        | Code  |
| --------------------------- | ----- |
| CSLA Iron Curtain           | csla  |
| Global Mobilization         | gm    |
| S.O.G. Prairie Fire         | vn    |
| Western Sahara              | ws    |
| Spearhead 1944              | spe   |
| Reaction Forces             | rf    |
| Expeditionary Forces        | ef    |

## Ports

| Port   | Protocol | Purpose           |
| ------ | -------- | ----------------- |
| 2302   | UDP      | Game              |
| 2303   | UDP      | Query (+1)        |
| 2304   | UDP      | Steam (+2)        |
| 2305   | UDP      | VON (+3)          |
| 2306   | UDP      | BattlEye (+4)     |

## Data Persistence

All server data lives in `/arma3/server`. The following volumes are available:

| Volume mount                          | Purpose              |
| ------------------------------------- | -------------------- |
| `./server:/arma3/server`              | Server files & steamapps |
| `./configs:/arma3/server/configs`     | Config files         |
| `./mods:/arma3/server/mods`           | Client-side mods     |
| `./servermods:/arma3/server/servermods` | Server-side mods    |

## Profiles

Profiles are stored in `/arma3/server/configs/profiles`.

## Steam Branches

[List of Arma 3 Steam branches](https://community.bistudio.com/wiki/Arma_3:_Steam_Branches) on the Bohemia Community Wiki.
