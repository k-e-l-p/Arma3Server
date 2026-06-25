#!/bin/bash
set -o errexit -o pipefail

error() { echo >&2 "[arma3] ERROR: $*"; exit 1; }
warn()  { echo >&2 "[arma3] WARN: $*"; }

# ---- steamcmd ---------------------------------------------------------------

steam_user="${STEAM_USER:-}"
steam_pass="${STEAM_PASSWORD:-}"

check_creds() {
    [ -n "$steam_user" ] && [ -n "$steam_pass" ] && return
    error "Set STEAM_USER and STEAM_PASSWORD"
}

steamcmd_init() {
    local d=/tmp/steamcmd
    mkdir -p "$d"
    [ -f "$d/steamcmd.sh" ] && return
    ( cd "$d" && wget -q https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
        && tar -xzf steamcmd_linux.tar.gz && rm steamcmd_linux.tar.gz )
    mkdir -p /arma3/server/steamapps
}

steam_login_args() { echo +login "$steam_user" "$steam_pass"; }

steamcmd_update() {
    steamcmd_init
    local -a a=( +force_install_dir /arma3/server $(steam_login_args) +app_update 233780 )
    [ -n "${STEAM_BRANCH:-}" ] && a+=(-beta "$STEAM_BRANCH")
    [ -n "${STEAM_BRANCH_PASSWORD:-}" ] && a+=(-betapassword "$STEAM_BRANCH_PASSWORD")
    a+=("$@")
    /tmp/steamcmd/steamcmd.sh "${a[@]}"
}

steamclient_fix() {
    for pair in "linux32:sdk32" "linux64:sdk64"; do
        local arch=${pair%:*} sdk=${pair#*:}
        local dst="/arma3/.steam/${sdk}/steamclient.so"
        [ -f "$dst" ] && continue
        mkdir -p "$(dirname "$dst")"
        cp "/tmp/steamcmd/${arch}/steamclient.so" "$dst"
    done
}

# ---- mod download -----------------------------------------------------------

workshop_download() {
    local id=$1
    steamcmd_init
    local n=0
    while (( n < 5 )); do
        (( n++ ))
        echo "[mod] $id attempt $n/5"
        /tmp/steamcmd/steamcmd.sh $(steam_login_args) \
            +workshop_download_item 107410 "$id" +quit && return 0
        echo "[mod] $id retrying..."
    done
    warn "mod $id failed after 5 attempts"
    return 1
}

install_preset_mods() {
    [ -n "${MODS_PRESET:-}" ] || return 0
    echo "=== preset mods: $MODS_PRESET ==="
    local html
    case "$MODS_PRESET" in
        http://*|https://*)
            html=/tmp/arma3_preset.html
            wget -qO "$html" "$MODS_PRESET" || { warn "failed to fetch $MODS_PRESET"; return 0; } ;;
        *)
            html="/arma3/server/presets/$MODS_PRESET"
            [ -f "$html" ] || { warn "preset not found: $html"; return 0; } ;;
    esac

    local ids
    ids=$(sed -nE 's/.*filedetails\/\?id=([0-9]+).*/\1/p' "$html" | sort -u)
    [ -n "$ids" ] || { warn "no workshop IDs in preset"; return 0; }
    echo "[preset] IDs: $ids"
    for id in $ids; do workshop_download "$id"; done
}

symlink_workshop_mods() {
    local ws=/arma3/server/Steam/steamapps/workshop/content/107410
    local mods=/arma3/server/mods
    [ -d "$ws" ] || return 0
    mkdir -p "$mods"
    for d in "$ws"/*/; do
        [ -d "$d" ] || continue
        local id
        id=$(basename "$d")
        [ -e "$mods/$id" ] && continue
        ln -s "../Steam/steamapps/workshop/content/107410/$id" "$mods/$id"
    done
}

# ---- mod patching / keys ----------------------------------------------------

patch_mods() {
    local d=/arma3/server/mods
    [ -d "$d" ] || return 0

    find -L "$d" -depth -print0 2>/dev/null | while IFS= read -r -d '' f; do
        local base lower
        base=$(basename "$f")
        lower=$(echo "$base" | tr '[:upper:]' '[:lower:]')
        [ "$base" = "$lower" ] && continue
        mv "$f" "$(dirname "$f")/$lower" 2>/dev/null || true
    done

    for m in "$d"/*/; do
        [ -d "$m" ] || continue
        local base fixed
        base=$(basename "$m")
        fixed=${base// /_}
        [ "$base" = "$fixed" ] && continue
        mv "$m" "$(dirname "$m")/$fixed" 2>/dev/null || true
    done
}

extract_keys() {
    [ "${EXTRACT_MOD_KEYS:-}" = true ] || return 0
    mkdir -p /arma3/server/keys
    for src in /arma3/server/mods /arma3/server/servermods; do
        [ -d "$src" ] || continue
        find -L "$src" -name '*.bikey' -exec cp -t /arma3/server/keys {} + 2>/dev/null || true
    done
}

keys_init() {
    [ "${CLEAR_KEYS:-true}" = true ] && [ -d /arma3/server/keys ] && rm -rf /arma3/server/keys/*
    mkdir -p /arma3/server/keys
}

# ---- mod list builder -------------------------------------------------------

collect_mods() {
    local dir=$1 prefix=$2 outvar=$3 result=""
    if [ -d "$dir" ]; then
        for d in "$dir"/*/; do
            [ -d "$d" ] || continue
            local name
            name=$(basename "$d")
            result="${result:+$result;}$prefix/$name"
        done
    fi
    printf -v "$outvar" '%s' "$result"
}

# ---- headless clients -------------------------------------------------------

hc_config_amend() {
    local src=/arma3/server/configs/$1 tmp=/tmp/arma3.cfg
    cat "$src" > "$tmp"
    grep -qi 'headlessclients\[\]' "$tmp" 2>/dev/null || \
        echo 'headlessclients[] = {"127.0.0.1"};' >> "$tmp"
    grep -qi 'localclient\[\]' "$tmp" 2>/dev/null || \
        echo 'localclient[] = {"127.0.0.1"};' >> "$tmp"
}

launch_hcs() {
    local count=$1
    local template="${HEADLESS_CLIENTS_PROFILE:-\$profile-hc-\$i}"
    mkdir -p /arma3/server/configs/profiles
    for (( i = 0; i < count; i++ )); do
        local name="$template"
        name=${name//\$profile/${ARMA_PROFILE:-main}}
        name=${name//\$i/$i}
        name=${name//\$ii/$((i+1))}
        local -a hc=( ./arma3server_x64 -client -connect=127.0.0.1 -port="${PORT:-2302}"
                      -name="$name" -profiles=/arma3/server/configs/profiles )
        [ -n "${MODLIST:-}" ] && hc+=(-mod="$MODLIST")
        [ -n "${SERVER_MODLIST:-}" ] && hc+=(-serverMod="$SERVER_MODLIST")
        echo "HC $i: ${hc[*]}"
        "${hc[@]}" &
        sleep 2
    done
}

# ---- update / start ---------------------------------------------------------

do_update() {
    check_creds
    steamcmd_update "$@"
    install_preset_mods
    symlink_workshop_mods
    steamclient_fix
}

do_start() {
    patch_mods
    keys_init
    extract_keys

    local port="${PORT:-2302}"
    local config="${ARMA_CONFIG:-main.cfg}"
    local profile="${ARMA_PROFILE:-main}"
    local world="${ARMA_WORLD:-empty}"
    local limitfps="${ARMA_LIMITFPS:-50}"
    local hcs="${HEADLESS_CLIENTS:-0}"

    collect_mods /arma3/server/mods mods MODLIST
    collect_mods /arma3/server/servermods servermods SERVER_MODLIST

    if [ "${MODS_LOCAL:-true}" != true ]; then
        MODLIST=""
        SERVER_MODLIST=""
    fi

    local -a cmd=( "${ARMA_BINARY:-./arma3server_x64}"
                   -ip=0.0.0.0 -port="$port" -name="$profile" )

    if [ -f "/arma3/server/configs/${ARMA_BASIC_CONFIG:-basic.cfg}" ]; then
        cmd+=(-cfg="/arma3/server/configs/${ARMA_BASIC_CONFIG:-basic.cfg}")
    fi

    if [ "$hcs" != 0 ] && [ -n "$hcs" ]; then
        hc_config_amend "$config"
        cmd+=(-config=/tmp/arma3.cfg)
    else
        cmd+=(-config="/arma3/server/configs/$config")
    fi

    cmd+=(-profiles=/arma3/server/configs/profiles -world="$world" -limitFPS="$limitfps")
    [ -n "$MODLIST" ] && cmd+=(-mod="$MODLIST")
    [ -n "$SERVER_MODLIST" ] && cmd+=(-serverMod="$SERVER_MODLIST")

    if [ -n "${ARMA_PARAMS:-}" ]; then
        for p in ${ARMA_PARAMS}; do
            [ -n "$p" ] && cmd+=("$p")
        done
    fi

    cd /arma3/server
    echo "SERVER: ${cmd[*]}"
    "${cmd[@]}" &
    local pid=$!

    [ "$hcs" != 0 ] && launch_hcs "$hcs"
    wait "$pid"
}

# ---- entry point ------------------------------------------------------------

case "${1:-}" in
    update)
        do_update +quit ;;
    update_validate)
        do_update validate +quit ;;
    start)
        do_start ;;
    *)
        if [ "${SKIP_INSTALL:-false}" != true ]; then
            do_update validate +quit
        fi
        do_start ;;
esac
