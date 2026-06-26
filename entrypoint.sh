#!/bin/bash
set -o errexit -o pipefail

server="${HOME:-/arma3}/server"

error() { echo >&2 "[arma3] ERROR: $@"; exit 1; }
warn()  { echo >&2 "[arma3] WARN: $@"; }

# ---- steamcmd ----------------------------------------------------------------

steam_user="${STEAM_USER:-}"
steam_pass="${STEAM_PASSWORD:-}"

check_creds() {
    [ -n "$steam_user" ] && [ -n "$steam_pass" ] && return
    error "Set STEAM_USER and STEAM_PASSWORD"
}

steamcmd_init() {
    local d=/tmp/steamcmd
    mkdir -p "$d"
    if [ ! -f "$d/steamcmd.sh" ]; then
        local tmp="$d/steamcmd.tar.gz"
        wget -qO "$tmp" https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
            || { rm -f "$tmp"; error "failed to download steamcmd"; }
        ( cd "$d" && tar -xzf "$tmp" && rm "$tmp" ) \
            || { rm -rf "$d"; error "failed to extract steamcmd"; }
    fi
    mkdir -p "$server/steamapps"
}

steamcmd_update() {
    steamcmd_init
    local validate=""
    [ "${1:-}" = validate ] && { validate=validate; shift; }
    local -a a=( +force_install_dir "$server" +login "$steam_user" "$steam_pass" )
    [ -n "${STEAM_BRANCH:-}" ] && a+=(-beta "$STEAM_BRANCH")
    [ -n "${STEAM_BRANCH_PASSWORD:-}" ] && a+=(-betapassword "$STEAM_BRANCH_PASSWORD")
    # 1391110 must install first — 233780 declares a depot dependency on it.
    /tmp/steamcmd/steamcmd.sh "${a[@]}" +app_update 1391110 $validate +quit
    /tmp/steamcmd/steamcmd.sh "${a[@]}" +app_update 233780 $validate +quit
}

steamclient_setup() {
    local arch
    for arch in 32 64; do
        local dst="$HOME/.steam/sdk${arch}/steamclient.so"
        [ -f "$dst" ] && continue
        mkdir -p "$(dirname "$dst")"
        cp -f "/tmp/steamcmd/linux${arch}/steamclient.so" "$dst"
    done
}

# ---- mod download ------------------------------------------------------------

workshop_download() {
    local id=$1
    steamcmd_init
    local n=0
    while (( n < 5 )); do
        (( n++ ))
        echo "[mod] $id attempt $n/5"
        /tmp/steamcmd/steamcmd.sh +login "$steam_user" "$steam_pass" \
            +workshop_download_item 107410 "$id" +quit && return 0
        echo "[mod] $id retrying..."
    done
    warn "mod $id failed after 5 attempts"
    return 1
}

install_preset_mods() {
    [ -n "${MODS_PRESET:-}" ] || return 0
    echo "=== preset mods: $MODS_PRESET ==="
    local html=""
    case "$MODS_PRESET" in
        http://*|https://*)
            html=/tmp/arma3_preset.html
            wget -qO "$html" "$MODS_PRESET" || { warn "failed to fetch $MODS_PRESET"; return 0; } ;;
        *)
            html="$server/presets/$MODS_PRESET"
            [ -f "$html" ] || { warn "preset not found: $html"; return 0; } ;;
    esac

    local ids
    ids=$(sed -nE 's,.*filedetails/\?id=([0-9]+).*,\1,p' "$html" | sort -u)
    [ -n "$ids" ] || { warn "no workshop IDs in preset"; return 0; }
    echo "[preset] IDs: $ids"
    for id in $ids; do workshop_download "$id" || true; done
}

symlink_workshop_mods() {
    local ws="$server/Steam/steamapps/workshop/content/107410"
    local mods="$server/mods"
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

# ---- mod patching / keys -----------------------------------------------------

patch_mods() {
    local d="$server/mods"
    [ -d "$d" ] || return 0

    # lowercase all files, depth-first so parent dirs resolve after children
    find -L "$d" -depth -print0 2>/dev/null | while IFS= read -r -d '' f; do
        base=$(basename "$f")
        lower=$(echo "$base" | tr '[:upper:]' '[:lower:]')
        [ "$base" = "$lower" ] && continue
        mv "$f" "$(dirname "$f")/$lower" 2>/dev/null || true
    done

    for m in "$d"/*/; do
        [ -d "$m" ] || continue
        base=$(basename "$m")
        fixed=${base// /_}
        [ "$base" = "$fixed" ] && continue
        mv "$m" "$(dirname "$m")/$fixed" 2>/dev/null || true
    done
}

extract_keys() {
    [ "${EXTRACT_MOD_KEYS:-}" = true ] || return 0
    mkdir -p "$server/keys"
    for src in "$server/mods" "$server/servermods"; do
        [ -d "$src" ] || continue
        find -L "$src" -name '*.bikey' -exec cp -t "$server/keys" {} + 2>/dev/null || true
    done
}

keys_init() {
    [ "${CLEAR_KEYS:-true}" = true ] && [ -d "$server/keys" ] && rm -rf "$server/keys"/*
    mkdir -p "$server/keys"
}

# ---- mod list builder --------------------------------------------------------

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

# ---- headless clients --------------------------------------------------------

hc_config_amend() {
    local src="$server/configs/$1" tmp=/tmp/arma3.cfg
    [ -f "$src" ] || { warn "config not found: $src"; return 1; }
    cat "$src" > "$tmp"
    grep -qi 'headlessclients\[\]' "$tmp" 2>/dev/null || \
        echo 'headlessclients[] = {"127.0.0.1"};' >> "$tmp"
    grep -qi 'localclient\[\]' "$tmp" 2>/dev/null || \
        echo 'localclient[] = {"127.0.0.1"};' >> "$tmp"
}

launch_hcs() {
    local count=$1 hc_binary="${ARMA_BINARY:-./arma3server_x64}"
    local template="${HEADLESS_CLIENTS_PROFILE:-\$profile-hc-\$i}"
    mkdir -p "$server/configs/profiles"
    for (( i = 0; i < count; i++ )); do
        # expand $profile, $i, $ii placeholders in the HC profile template
        local name="$template"
        name=${name//\$profile/${ARMA_PROFILE:-main}}
        name=${name//\$i/$i}
        name=${name//\$ii/$((i+1))}
        local -a hc=( "$hc_binary" -client -connect=127.0.0.1 -port="${PORT:-2302}"
                      -name="$name" -profiles="$server/configs/profiles" )
        [ -n "${MODLIST:-}" ] && hc+=(-mod="$MODLIST")
        [ -n "${SERVER_MODLIST:-}" ] && hc+=(-serverMod="$SERVER_MODLIST")
        echo "HC $i: ${hc[*]}"
        "${hc[@]}" &
        sleep 2
    done
}

# ---- update / start ----------------------------------------------------------

do_update() {
    check_creds
    steamcmd_update "$@"
    install_preset_mods
    symlink_workshop_mods
    steamclient_setup
}

do_start() {
    patch_mods
    keys_init
    extract_keys

    local port="${PORT:-2302}"
    local config="${ARMA_CONFIG:-main.cfg}"
    local basic_cfg="${ARMA_BASIC_CONFIG:-basic.cfg}"
    local profile="${ARMA_PROFILE:-main}"
    local world="${ARMA_WORLD:-empty}"
    local limitfps="${ARMA_LIMITFPS:-50}"
    local hcs="${HEADLESS_CLIENTS:-0}"

    if [ "${MODS_LOCAL:-true}" = true ]; then
        collect_mods "$server/mods" mods MODLIST
        collect_mods "$server/servermods" servermods SERVER_MODLIST
    else
        MODLIST=""
        SERVER_MODLIST=""
    fi

    local -a cmd=( "${ARMA_BINARY:-./arma3server_x64}"
                   -ip=0.0.0.0 -port="$port" -name="$profile" )

    if [ -f "$server/configs/$basic_cfg" ]; then
        cmd+=(-cfg="$server/configs/$basic_cfg")
    fi

    if [ "$hcs" -gt 0 ] 2>/dev/null; then
        hc_config_amend "$config"
        cmd+=(-config=/tmp/arma3.cfg)
    else
        cmd+=(-config="$server/configs/$config")
    fi

    cmd+=(-profiles="$server/configs/profiles" -world="$world" -limitFPS="$limitfps")
    [ -n "$MODLIST" ] && cmd+=(-mod="$MODLIST")
    [ -n "$SERVER_MODLIST" ] && cmd+=(-serverMod="$SERVER_MODLIST")

    # ARMA_PARAMS is space-split by design. Quoted values (e.g. -password "x y")
    # are not supported through this variable.
    if [ -n "${ARMA_PARAMS:-}" ]; then
        for p in ${ARMA_PARAMS}; do
            [ -n "$p" ] && cmd+=("$p")
        done
    fi

    # kill all child processes (server + HCs) when this script exits
    trap 'kill 0' EXIT

    cd "$server"
    echo "SERVER: ${cmd[*]}"
    "${cmd[@]}" &
    local pid=$!

    if [ "$hcs" -gt 0 ] 2>/dev/null; then
        launch_hcs "$hcs"
    fi

    wait "$pid"
}

# ---- entry point -------------------------------------------------------------

case "${1:-}" in
    update)
        do_update ;;
    update_validate)
        do_update validate ;;
    start)
        do_start ;;
    *)
        if [ "${SKIP_INSTALL:-false}" != true ]; then
            do_update validate
        fi
        do_start ;;
esac
