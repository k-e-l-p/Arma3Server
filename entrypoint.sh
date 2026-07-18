#!/bin/bash
set -o errexit -o pipefail

set -x

server="${HOME:-/arma3}/server"
STEAMCMD_DIR="$HOME/steamcmd"
STATE_FILE="$server/.mods_state.json"
STATE_LOCK="$server/.mods_state.lock"
STEAMCMD_TIMEOUT="${STEAMCMD_TIMEOUT:-3600}"

error() { echo >&2 "[arma3] ERROR: $*"; exit 1; }
warn()  { echo >&2 "[arma3] WARN: $*"; }

# ---- steamcmd ----------------------------------------------------------------

steam_user="${STEAM_USER:-}"
steam_pass="${STEAM_PASSWORD:-}"

check_creds() {
    [ -n "$steam_user" ] && [ -n "$steam_pass" ] && return
    error "Set STEAM_USER and STEAM_PASSWORD"
}

steamcmd_ensure() {
    [ -x "$STEAMCMD_DIR/steamcmd.sh" ] && return 0
    mkdir -p "$STEAMCMD_DIR"
    local tmp="$STEAMCMD_DIR/steamcmd.tar.gz"
    local url="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"
    wget -4 --tries=5 --timeout=30 -qO "$tmp" "$url" \
        || { rm -f "$tmp"; error "failed to download steamcmd from $url (check DNS/internet)"; }
    ( cd "$STEAMCMD_DIR" && tar -xzf "$tmp" && rm "$tmp" ) \
        || { rm -rf "$STEAMCMD_DIR"; error "failed to extract steamcmd"; }
    mkdir -p "$server/steamapps"
}

steamcmd_run() {
    timeout --signal=TERM --kill-after=30 "$STEAMCMD_TIMEOUT" \
        "$STEAMCMD_DIR/steamcmd.sh" "$@"
}

# Workshop downloads run without timeout — SteamCMD resumes partial
# downloads on retry, and large mods (e.g. CUP at 14 GB) need
# unbounded time on slow connections.
steamcmd_run_ws() {
    "$STEAMCMD_DIR/steamcmd.sh" "$@"
}

steamcmd_update() {
    steamcmd_ensure
    local validate=0
    [ "${1:-}" = validate ] && { validate=1; shift; }
    local -a args=( +force_install_dir "$server" +login "$steam_user" "$steam_pass" )
    [ -n "${STEAM_BRANCH:-}" ] && args+=(-beta "$STEAM_BRANCH")
    [ -n "${STEAM_BRANCH_PASSWORD:-}" ] && args+=(-betapassword "$STEAM_BRANCH_PASSWORD")
    args+=( +app_update 233780 )
    [ "$validate" = 1 ] && args+=(validate)
    args+=( +quit )
    steamcmd_run "${args[@]}"
}

steamclient_setup() {
    for arch in 32 64; do
        local src="$STEAMCMD_DIR/linux${arch}/steamclient.so"
        [ -f "$src" ] || { rm -rf "$STEAMCMD_DIR"; steamcmd_ensure; }
        local dst="$HOME/.steam/sdk${arch}/steamclient.so"
        mkdir -p "$(dirname "$dst")"
        cp -f "$src" "$dst"
    done
}

# ---- workshop mod download ---------------------------------------------------

workshop_download_batch() {
    local -a ids=("$@")
    [ ${#ids[@]} -eq 0 ] && return 0

    local -a remaining=("${ids[@]}")
    local attempt=0
    while (( attempt < 5 )) && [ ${#remaining[@]} -gt 0 ]; do
        (( attempt++ ))

        local -a cmd=( +force_install_dir "$server" +login "$steam_user" "$steam_pass" )
        for id in "${remaining[@]}"; do
            cmd+=( +workshop_download_item 107410 "$id" )
        done
        cmd+=( +quit )

        echo "[mod] batch download attempt $attempt/5 (${#remaining[@]} mods)"
        if steamcmd_run_ws "${cmd[@]}"; then
            return 0
        fi

        local -a next=()
        for id in "${remaining[@]}"; do
            if [ -d "$server/steamapps/workshop/content/107410/$id" ]; then
                echo "[mod:$id] download OK (retry $attempt)"
            else
                next+=("$id")
            fi
        done
        remaining=("${next[@]}")
    done

    [ ${#remaining[@]} -eq 0 ] && return 0
    warn "[mod] ${#remaining[@]} mod(s) failed after 5 attempts"
    return 1
}

# ---- state file --------------------------------------------------------------

state_init() {
    [ -f "$STATE_FILE" ] || state_reset
}

state_reset() {
    local tmp="${STATE_FILE}.tmp.$$"
    echo '{"version":1,"preset_hash":"","mods":{}}' > "$tmp" \
        && mv "$tmp" "$STATE_FILE"
}

state_get_hash() {
    jq -r '.preset_hash // ""' "$STATE_FILE" 2>/dev/null || echo ""
}

state_validate() {
    local ver
    ver=$(jq -r '.version // 0' "$STATE_FILE" 2>/dev/null || echo 0)
    [ "$ver" = "1" ]
}

# Lock is held until process exit (fd 9 closed by kernel on termination).
state_lock() {
    exec 9>"$STATE_LOCK"
    flock 9
}

state_save() {
    local hash="$1"
    local mods_json="$2"
    local tmp="${STATE_FILE}.tmp.$$"
    jq -n --arg h "$hash" --argjson m "$mods_json" '{version:1,preset_hash:$h,mods:$m}' > "$tmp" \
        && mv "$tmp" "$STATE_FILE"
}

# ---- preset parsing ----------------------------------------------------------

get_preset_ids() {
    printf '%s' "$1" | sed -nE 's,.*filedetails/\?id=([0-9]+).*,\1,p' | sort -u
}

compute_preset_hash() {
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

read_preset_content() {
    local content=""
    case "$MODS_PRESET" in
        http://*|https://*)
            content=$(wget -4 --tries=3 --timeout=30 -qO- "$MODS_PRESET" 2>/dev/null) || { warn "failed to fetch $MODS_PRESET"; return 1; } ;;
        *)
            local f="$server/presets/${MODS_PRESET##*/}"
            [ -f "$f" ] || { warn "preset not found: $f"; return 1; }
            content=$(cat "$f") ;;
    esac
    printf '%s' "$content"
}

# ---- mod installation --------------------------------------------------------

install_mod() {
    local id="$1"
    local src="$server/steamapps/workshop/content/107410/$id"
    local dst="$server/mods/$id"

    [ -d "$src" ] || return 1
    [ -d "$dst" ] && rm -rf "$dst"
    mkdir -p "$server/mods"

    echo "[mod:$id] installing..."
    local size=$(du -sh "$src" 2>/dev/null | cut -f1)
    [ -n "$size" ] && echo "[mod:$id] size: $size"
    cp -r "$src" "$dst" || { warn "[mod:$id] copy failed"; rm -rf "$dst"; return 1; }
    return 0
}

# ---- mod patching / keys -----------------------------------------------------

patch_mods() {
    local d="$server/mods"
    [ -d "$d" ] || return 0

    find "$d" -depth -print0 2>/dev/null | while IFS= read -r -d '' f; do
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
        find "$src" -name '*.bikey' -exec cp -t "$server/keys" {} + 2>/dev/null || true
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
    local src="$server/configs/$1"
    [ -f "$src" ] || { warn "config not found: $src"; return 1; }
    local tmp="$server/configs/.hc_amend.cfg"
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
        local name="$template"
        name=${name//\$profile/${ARMA_PROFILE:-main}}
        name=${name//\$ii/$((i+1))}
        name=${name//\$i/$i}
        local -a hc=( "$hc_binary" -client -connect=127.0.0.1 -port="${PORT:-2302}"
                      -name="$name" -profiles="$server/configs/profiles" )
        [ -n "${MODLIST:-}" ] && hc+=(-mod="$MODLIST")
        [ -n "${SERVER_MODLIST:-}" ] && hc+=(-serverMod="$SERVER_MODLIST")
        echo "HC $i: ${hc[*]}"
        "${hc[@]}" &
        sleep 2
    done
}

# ---- mod orchestration -------------------------------------------------------

process_mods() {
    [ -n "${MODS_PRESET:-}" ] || return 0
    steamcmd_ensure

    local preset_content
    preset_content=$(read_preset_content) || {
        warn "failed to read preset '$MODS_PRESET', server will start without workshop mods"
        return 0
    }

    local new_hash
    new_hash=$(compute_preset_hash "$preset_content")

    local new_ids
    new_ids=$(get_preset_ids "$preset_content")
    [ -n "$new_ids" ] || { warn "no workshop IDs in preset"; return 0; }

    state_init
    state_lock

    local old_hash
    old_hash=$(state_get_hash)

    if ! jq empty "$STATE_FILE" 2>/dev/null || ! state_validate; then
        warn "state file corrupt or wrong version, resetting"
        state_reset
        old_hash=""
    fi

    # Reset failed mods to pending so they retry on restart
    local has_failed
    has_failed=$(jq '[.mods[] | select(.status == "failed")] | length > 0' "$STATE_FILE" 2>/dev/null || echo false)
    if [ "$has_failed" = true ]; then
        echo "[mod] retrying previously failed mods..."
        local retry_json
        retry_json=$(jq '.mods | with_entries(if .value.status == "failed" then .value.status = "pending" else . end)' "$STATE_FILE")
        state_save "$old_hash" "$retry_json"
    fi

    echo "=== preset: $MODS_PRESET ==="

    if [ "$new_hash" != "$old_hash" ]; then
        echo "[mod] preset changed, updating..."

        local new_mods
        new_mods=$(printf '%s' "$new_ids" | jq -R '
            [., inputs | select(length > 0)] as $ids |
            reduce $ids[] as $id ({};
                .[$id] = {status: "pending", error: null}
            )
        ')

        jq -r --argjson keep "$new_mods" '.mods | keys[] | select($keep[.] == null)' "$STATE_FILE" 2>/dev/null | \
        while IFS= read -r id; do
            [ -n "$id" ] && { echo "[mod:$id] removing..."; rm -rf "$server/mods/$id" 2>/dev/null || true; }
        done

        state_save "$new_hash" "$new_mods"
    fi

    local pending_json
    pending_json=$(jq '.mods | to_entries | map(select(.value.status == "pending")) | map(.key)' "$STATE_FILE")
    local pending_count
    pending_count=$(echo "$pending_json" | jq 'length')

    if [ "$pending_count" -eq 0 ] 2>/dev/null; then
        return 0
    fi

    local -a pending_arr
    while IFS= read -r id; do
        [ -n "$id" ] && pending_arr+=("$id")
    done < <(echo "$pending_json" | jq -r '.[]')

    echo "[mod] processing $pending_count pending mods..."

    workshop_download_batch "${pending_arr[@]}" || true

    local current_mods
    current_mods=$(jq '.mods' "$STATE_FILE")

    for id in "${pending_arr[@]}"; do
        if [ -d "$server/steamapps/workshop/content/107410/$id" ]; then
            if install_mod "$id"; then
                current_mods=$(echo "$current_mods" | jq --arg id "$id" '.[$id] = {status:"installed",error:null}')
            else
                current_mods=$(echo "$current_mods" | jq --arg id "$id" '.[$id] = {status:"failed",error:"copy failed"}')
            fi
        else
            current_mods=$(echo "$current_mods" | jq --arg id "$id" '.[$id] = {status:"failed",error:"download failed"}')
        fi
    done

    patch_mods

    state_save "$new_hash" "$current_mods"

    local failed_count
    failed_count=$(echo "$current_mods" | jq '[.[] | select(.status == "failed")] | length')
    if [ "$failed_count" -gt 0 ] 2>/dev/null; then
        warn "$failed_count mod(s) failed to install, server will start without them"
    fi
}

# ---- update / start ----------------------------------------------------------

do_update() {
    check_creds
    steamcmd_update "$@"
    process_mods
    steamclient_setup
}

do_start() {
    steamcmd_ensure
    steamclient_setup
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
        cmd+=(-config="$server/configs/.hc_amend.cfg")
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

echo "sanity_test"

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
