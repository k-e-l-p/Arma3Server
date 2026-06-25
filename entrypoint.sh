#!/bin/bash

set -o errexit
set -o pipefail

function error() {
    echo >&2 "[arma3-error] $1"
    exit 1
}

# ─── SteamCMD helpers ──────────────────────────────────────────────────────────

function check_steam_credentials() {
    if [ -z "$STEAM_USER" ] || [ -z "$STEAM_PASSWORD" ]; then
        error "Missing steam login info. Set STEAM_USER and STEAM_PASSWORD."
    fi
}

function ensure_steamcmd() {
    mkdir -vp /tmp/steamcmd
    if [ ! -f "/tmp/steamcmd/steamcmd.sh" ]; then
        cd /tmp/steamcmd
        wget -q "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"
        tar -xzf steamcmd_linux.tar.gz
        rm steamcmd_linux.tar.gz
    fi
    mkdir -vp /arma3/server/steamapps
}

function post_update() {
    local s32="/arma3/.steam/sdk32/steamclient.so"
    local s64="/arma3/.steam/sdk64/steamclient.so"

    if [ ! -f "$s32" ]; then
        mkdir -vp "$(dirname "$s32")"
        cp -v /tmp/steamcmd/linux32/steamclient.so "$s32"
    fi
    if [ ! -f "$s64" ]; then
        mkdir -vp "$(dirname "$s64")"
        cp -v /tmp/steamcmd/linux64/steamclient.so "$s64"
    fi
}

# Run a steamcmd line safely.
# All arguments after +force_install_dir ... +app_update 233780 are passed through.
function run_steamcmd_update() {
    local args=(
        +force_install_dir /arma3/server
        +login "$STEAM_USER" "$STEAM_PASSWORD"
        +app_update 233780
    )
    if [ -n "$STEAM_BRANCH" ]; then
        args+=(-beta "$STEAM_BRANCH")
        if [ -n "$STEAM_BRANCH_PASSWORD" ]; then
            args+=(-betapassword "$STEAM_BRANCH_PASSWORD")
        fi
    fi
    args+=("$@")

    /tmp/steamcmd/steamcmd.sh "${args[@]}"
}

# ─── Server install / update ───────────────────────────────────────────────────

function update_validate() {
    check_steam_credentials
    ensure_steamcmd
    run_steamcmd_update validate +quit
    install_managed_mods
    install_preset_mods
    symlink_workshop_mods
    post_update
}

function update() {
    check_steam_credentials
    ensure_steamcmd
    run_steamcmd_update +quit
    install_managed_mods
    install_preset_mods
    symlink_workshop_mods
    post_update
}

# ─── Mod management ────────────────────────────────────────────────────────────

function download_workshop_mod() {
    local modid="$1"
    ensure_steamcmd
    local attempt=1
    while true; do
        echo "[mod] Downloading $modid (attempt $attempt)..."
        /tmp/steamcmd/steamcmd.sh \
            +login "$STEAM_USER" "$STEAM_PASSWORD" \
            +workshop_download_item 107410 "$modid" \
            +quit && break
        attempt=$((attempt + 1))
        if [ "$attempt" -le 5 ]; then
            echo "[mod] Download of $modid failed, retrying..."
        else
            echo "[mod] Download of $modid failed 5 times, skipping."
            return 1
        fi
    done
    echo "[mod] $modid downloaded."
}

function install_managed_mods() {
    [ -n "$MANAGED_MODS" ] || return 0

    echo "=== Installing managed mods ==="
    check_steam_credentials
    ensure_steamcmd

    readarray -d ' ' -t MOD_ARRAY < <(printf '%s' "$MANAGED_MODS")
    local WS="/arma3/server/Steam/steamapps/workshop/content/107410"

    # Remove workshop mods no longer in MANAGED_MODS
    if [ -d "$WS" ]; then
        for d in "$WS"/*/; do
            [ -d "$d" ] || continue
            local wid
            wid=$(basename "$d")
            if [[ ! " ${MOD_ARRAY[*]} " =~ " ${wid} " ]]; then
                echo "[mod] Removing unmanaged mod $wid"
                rm -rf "$d"
            fi
        done
    fi

    for modid in "${MOD_ARRAY[@]}"; do
        [ -z "$modid" ] && continue
        download_workshop_mod "$modid"
    done
}

function install_preset_mods() {
    [ -n "$MODS_PRESET" ] || return 0

    echo "=== Processing mod preset: $MODS_PRESET ==="
    check_steam_credentials

    local html="/tmp/arma3_preset.html"
    if [[ "$MODS_PRESET" == http://* ]] || [[ "$MODS_PRESET" == https://* ]]; then
        wget -q -O "$html" "$MODS_PRESET" || {
            echo "[preset] Warning: failed to download $MODS_PRESET"
            return 0
        }
    else
        html="$MODS_PRESET"
    fi

    [ -f "$html" ] || { echo "[preset] File not found: $MODS_PRESET"; return 0; }

    local ids
    ids=$(grep -oP 'filedetails/\?id=\K\d+' "$html" | sort -u)
    [ -n "$ids" ] || { echo "[preset] No workshop IDs found."; return 0; }

    echo "[preset] Workshop IDs: $ids"
    for modid in $ids; do
        download_workshop_mod "$modid"
    done
}

function symlink_workshop_mods() {
    local WS="/arma3/server/Steam/steamapps/workshop/content/107410"
    local MODS="/arma3/server/mods"
    [ -d "$WS" ] || return 0

    mkdir -vp "$MODS"
    for d in "$WS"/*/; do
        [ -d "$d" ] || continue
        local wid
        wid=$(basename "$d")
        local link="$MODS/$wid"
        if [ ! -L "$link" ] && [ ! -e "$link" ]; then
            ln -sv "../Steam/steamapps/workshop/content/107410/$wid" "$link"
        fi
    done

    # Clear broken symlinks (e.g. to removed workshop mods)
    find "$MODS" -xtype l -delete -print 2>/dev/null || true
}

# ─── Utility functions ─────────────────────────────────────────────────────────

function patch_mods() {
    local d="/arma3/server/mods"
    [ -d "$d" ] || return 0

    echo "Patching mods (lowercase + underscores)..."

    # Recursively lowercase files
    find -L "$d" -depth -print0 2>/dev/null | while IFS= read -r -d '' f; do
        local dir base lower
        dir=$(dirname "$f")
        base=$(basename "$f")
        lower=$(echo "$base" | tr '[:upper:]' '[:lower:]')
        if [ "$base" != "$lower" ]; then
            mv -v "$f" "$dir/$lower" 2>/dev/null || true
        fi
    done

    # Replace spaces with underscores in top-level mod directories
    find "$d" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null | while IFS= read -r -d '' m; do
        local dir base fixed
        dir=$(dirname "$m")
        base=$(basename "$m")
        fixed=$(echo "$base" | tr ' ' '_')
        if [ "$base" != "$fixed" ]; then
            mv -v "$m" "$dir/$fixed" 2>/dev/null || true
        fi
    done
}

function extract_mod_keys() {
    [ "${EXTRACT_MOD_KEYS:-false}" == "true" ] || return 0

    echo "Extracting mod signature keys..."
    mkdir -vp /arma3/server/keys

    for src in "/arma3/server/mods" "/arma3/server/servermods"; do
        [ -d "$src" ] || continue
        find -L "$src" -type f -name "*.bikey" -print0 2>/dev/null | \
            xargs -0 -I{} cp -vf "{}" /arma3/server/keys/ || true
    done
}

function manage_keys() {
    if [ "${CLEAR_KEYS:-true}" == "true" ] && [ -d "/arma3/server/keys" ]; then
        echo "Clearing keys directory..."
        rm -rf /arma3/server/keys/*
    fi
    mkdir -vp /arma3/server/keys
}

# ─── Mod list builders (set global MODLIST / SERVER_MODLIST) ───────────────────

function build_modlist() {
    MODLIST=""
    local d="/arma3/server/mods"
    [ -d "$d" ] || return 0

    for m in "$d"/*/; do
        [ -d "$m" ] || continue
        local name
        name=$(basename "$m")
        if [ -z "$MODLIST" ]; then
            MODLIST="mods/$name"
        else
            MODLIST="$MODLIST;mods/$name"
        fi
    done
}

function build_server_modlist() {
    SERVER_MODLIST=""
    local d="/arma3/server/servermods"
    [ -d "$d" ] || return 0

    for m in "$d"/*/; do
        [ -d "$m" ] || continue
        local name
        name=$(basename "$m")
        if [ -z "$SERVER_MODLIST" ]; then
            SERVER_MODLIST="servermods/$name"
        else
            SERVER_MODLIST="$SERVER_MODLIST;servermods/$name"
        fi
    done
}

# ─── Headless client helpers ───────────────────────────────────────────────────

function configure_headless_clients() {
    local src="/arma3/server/configs/$1"
    local tmp="/tmp/arma3.cfg"

    cat "$src" > "$tmp"
    if ! grep -qi 'headlessclients\[\]' "$tmp" 2>/dev/null; then
        echo 'headlessclients[] = {"127.0.0.1"};' >> "$tmp"
    fi
    if ! grep -qi 'localclient\[\]' "$tmp" 2>/dev/null; then
        echo 'localclient[] = {"127.0.0.1"};' >> "$tmp"
    fi
}

function launch_headless_clients() {
    local count="$1"
    local template="${HEADLESS_CLIENTS_PROFILE:-\$profile-hc-\$i}"

    mkdir -vp /arma3/server/configs/profiles

    for ((i = 0; i < count; i++)); do
        local ii=$((i + 1))
        local hc="$template"
        hc="${hc//\$profile/${ARMA_PROFILE:-main}}"
        hc="${hc//\$i/$i}"
        hc="${hc//\$ii/$ii}"

        local hc_cmd="${ARMA_BINARY:-./arma3server_x64}"
        hc_cmd="$hc_cmd -client -connect=127.0.0.1 -port=${PORT:-2302}"
        hc_cmd="$hc_cmd -name='$hc'"
        hc_cmd="$hc_cmd -profiles='/arma3/server/configs/profiles'"

        echo "LAUNCHING HEADLESS CLIENT $i: $hc_cmd"
        eval "$hc_cmd" &
        sleep 2
    done
}

# ─── Start the server ──────────────────────────────────────────────────────────

function start() {
    patch_mods
    manage_keys
    extract_mod_keys

    local binary="${ARMA_BINARY:-./arma3server_x64}"
    local port="${PORT:-2302}"
    local config="${ARMA_CONFIG:-main.cfg}"
    local basic_cfg="${ARMA_BASIC_CONFIG:-basic.cfg}"
    local profile="${ARMA_PROFILE:-main}"
    local world="${ARMA_WORLD:-empty}"
    local limitfps="${ARMA_LIMITFPS:-50}"
    local params="${ARMA_PARAMS:-}"
    local headless="${HEADLESS_CLIENTS:-0}"

    build_modlist
    build_server_modlist

    # Build command
    local cmd="$binary"
    cmd="$cmd -ip=0.0.0.0 -port=$port"
    cmd="$cmd -name='$profile'"

    if [ -f "/arma3/server/configs/$basic_cfg" ]; then
        cmd="$cmd -cfg='/arma3/server/configs/$basic_cfg'"
    fi

    if [ "$headless" != "0" ] && [ -n "$headless" ]; then
        configure_headless_clients "$config"
        cmd="$cmd -config='/tmp/arma3.cfg'"
    else
        cmd="$cmd -config='/arma3/server/configs/$config'"
    fi

    cmd="$cmd -profiles='/arma3/server/configs/profiles'"
    cmd="$cmd -world=$world -limitFPS=$limitfps"

    if [ -n "$MODLIST" ]; then
        cmd="$cmd -mod='$MODLIST'"
    fi
    if [ -n "$SERVER_MODLIST" ]; then
        cmd="$cmd -serverMod='$SERVER_MODLIST'"
    fi
    if [ -n "$params" ]; then
        cmd="$cmd $params"
    fi

    cd /arma3/server
    echo "LAUNCHING ARMA SERVER: $cmd"
    eval "$cmd" &
    local server_pid=$!

    if [ "$headless" != "0" ] && [ -n "$headless" ]; then
        launch_headless_clients "$headless"
    fi

    wait "$server_pid"
}

# ─── Entry point ───────────────────────────────────────────────────────────────

case "${1:-}" in
    update)
        update
        ;;
    update_validate)
        update_validate
        ;;
    start)
        start
        ;;
    *)
        update_validate
        start
        ;;
esac
