#!/usr/bin/env bash
set -euo pipefail

CONTAINER_HOME="${CONTAINER_HOME:-/home/container}"
WINEPREFIX="${WINEPREFIX:-/home/container/.wine}"
BAKED_WINEPREFIX="${SBOX_BAKED_WINEPREFIX:-/opt/sbox-wine-prefix}"
BAKED_SERVER_TEMPLATE="${SBOX_BAKED_SERVER_TEMPLATE:-/opt/sbox-server-template}"

SBOX_INSTALL_DIR="${SBOX_INSTALL_DIR:-/home/container/sbox}"
SBOX_SERVER_EXE="${SBOX_SERVER_EXE:-${SBOX_INSTALL_DIR}/sbox-server.exe}"
SBOX_APP_ID="${SBOX_APP_ID:-1892930}"
SBOX_AUTO_UPDATE="${SBOX_AUTO_UPDATE:-1}"
SBOX_BRANCH="${SBOX_BRANCH:-}"
STEAM_PLATFORM="${STEAM_PLATFORM:-windows}"

GAME="${GAME:-}"
MAP="${MAP:-}"
SERVER_NAME="${SERVER_NAME:-}"
TOKEN="${TOKEN:-}"
SBOX_PROJECT="${SBOX_PROJECT:-}"
SBOX_EXTRA_ARGS="${SBOX_EXTRA_ARGS:-}"

seed_runtime_files() {
    mkdir -p "${CONTAINER_HOME}" "${WINEPREFIX}" "${SBOX_INSTALL_DIR}" "${CONTAINER_HOME}/logs" "${CONTAINER_HOME}/data"

    if [ ! -f "${WINEPREFIX}/system.reg" ] && [ -d "${BAKED_WINEPREFIX}/drive_c" ]; then
        echo "info: seeding Wine prefix from ${BAKED_WINEPREFIX}" >&2
        cp -a "${BAKED_WINEPREFIX}/." "${WINEPREFIX}/"
    fi

    if [ ! -f "${SBOX_SERVER_EXE}" ] && [ -d "${BAKED_SERVER_TEMPLATE}" ]; then
        echo "info: seeding S&Box files from ${BAKED_SERVER_TEMPLATE}" >&2
        cp -a "${BAKED_SERVER_TEMPLATE}/." "${SBOX_INSTALL_DIR}/"
    fi
}

update_sbox() {
    local steamcmd_home="${CONTAINER_HOME}/.steamcmd"
    local steamcmd_bin="${STEAMCMD_BIN:-${steamcmd_home}/steamcmd.sh}"
    local bootstrap_tar="${steamcmd_home}/steamcmd_linux.tar.gz"
    local -a steam_args

    mkdir -p "${steamcmd_home}" "${SBOX_INSTALL_DIR}"

    if [ ! -r "${steamcmd_bin}" ]; then
        wget -qO "${bootstrap_tar}" https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
        tar -xzf "${bootstrap_tar}" -C "${steamcmd_home}"
        rm -f "${bootstrap_tar}"
        chmod 0755 "${steamcmd_home}/steamcmd.sh" || true
        steamcmd_bin="${steamcmd_home}/steamcmd.sh"
    fi

    steam_args=(
        +@sSteamCmdForcePlatformType "${STEAM_PLATFORM}"
        +force_install_dir "${SBOX_INSTALL_DIR}"
        +login anonymous
        +app_update "${SBOX_APP_ID}"
    )

    if [ -n "${SBOX_BRANCH}" ]; then
        steam_args+=( -beta "${SBOX_BRANCH}" )
    fi

    steam_args+=( validate +quit )
    bash "${steamcmd_bin}" "${steam_args[@]}"
}

rotate_logs() {
    local log_dir="${CONTAINER_HOME}/logs"
    mkdir -p "${log_dir}"
    # Keep only the 10 most recent logs, delete older ones
    find "${log_dir}" -maxdepth 1 -name 'sbox-*.log' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | tail -n +11 | awk '{print $2}' \
        | xargs -r rm -f
}

validate_startup() {
    if [ -z "${GAME}" ] && [ -z "${SBOX_PROJECT}" ]; then
        echo "error: both GAME and SBOX_PROJECT are empty; set at least one startup target" >&2
        exit 1
    fi
}

healthcheck() {
    local failed=0

    if ! command -v wine >/dev/null 2>&1; then
        echo "healthcheck: wine not found in PATH" >&2
        failed=1
    fi

    if [ ! -d "${WINEPREFIX}" ]; then
        echo "healthcheck: missing WINEPREFIX at ${WINEPREFIX}" >&2
        failed=1
    fi

    if [ ! -f "${SBOX_SERVER_EXE}" ]; then
        echo "healthcheck: missing server executable at ${SBOX_SERVER_EXE}" >&2
        failed=1
    fi

    if [ ! -w "${CONTAINER_HOME}/logs" ]; then
        echo "healthcheck: logs directory is not writable at ${CONTAINER_HOME}/logs" >&2
        failed=1
    fi

    if [ ! -w "${CONTAINER_HOME}/data" ]; then
        echo "healthcheck: data directory is not writable at ${CONTAINER_HOME}/data" >&2
        failed=1
    fi

    if [ "${failed}" -ne 0 ]; then
        exit 1
    fi

    echo "healthcheck: ok"
}

run_sbox() {
    local -a args
    local -a extra
    local -a launch_env
    local log_file="${CONTAINER_HOME}/logs/sbox-$(date -u '+%Y%m%d-%H%M%S').log"

    rotate_logs
    echo "info: logging to ${log_file}" >&2

    if [ -n "${SBOX_PROJECT}" ]; then
        args+=( "${SBOX_PROJECT}" )
    elif [ -n "${GAME}" ]; then
        args+=( +game "${GAME}" )
        if [ -n "${MAP}" ]; then
            args+=( "${MAP}" )
        fi
    fi

    if [ -n "${SERVER_NAME}" ]; then
        args+=( +hostname "${SERVER_NAME}" )
    fi

    if [ -n "${TOKEN}" ]; then
        args+=( +net_game_server_token "${TOKEN}" )
    fi

    if [ -n "${SBOX_EXTRA_ARGS}" ]; then
        read -r -a extra <<< "${SBOX_EXTRA_ARGS}"
        args+=( "${extra[@]}" )
    fi

    unset DOTNET_ROOT DOTNET_ROOT_X86 DOTNET_ROOT_X64

    launch_env=(
        DOTNET_EnableWriteXorExecute=0
        COMPlus_TieredCompilation=0
        COMPlus_ReadyToRun=0
        COMPlus_ZapDisable=1
    )

    cd "${SBOX_INSTALL_DIR}"
    env "${launch_env[@]}" wine "${SBOX_SERVER_EXE}" "${args[@]}" 2>&1 \
        | tee "${log_file}"
    exit "${PIPESTATUS[0]}"
}

if [ "${1:-}" = "start-sbox" ]; then
    shift
fi

seed_runtime_files

if [ "${1:-}" = "healthcheck" ]; then
    healthcheck
    exit 0
fi

if [ "${1:-}" = "" ]; then
    validate_startup
    if [ "${SBOX_AUTO_UPDATE}" = "1" ] || [ ! -f "${SBOX_SERVER_EXE}" ]; then
        update_sbox
    fi
    run_sbox
fi

exec "$@"