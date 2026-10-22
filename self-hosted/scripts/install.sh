#!/usr/bin/env bash
#
# Interactive installer for ProtoMap Server: writes .env with secrets and a setup key, starts the services, and
# installs the ProtoMap CLI of the same release.

set -euo pipefail

# This script's folder, and the folder above it with compose.yaml and .env, as the command that ran the script names
# them, such as ./self-hosted/scripts and ./self-hosted from the root of the clone, so the commands and files the
# script names work from where it ran.
scripts="$(dirname "$0")"
folder="$(dirname "$scripts")"
[ "$scripts" != . ] || folder=..
# Run from the folder with compose.yaml and .env.
cd "$folder"

color_bold=""
color_done=""
color_error=""
color_prompt=""
color_reset=""
if { [ -t 1 ] || [ -t 2 ]; } && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
    color_bold=$'\033[1m'
    color_done=$'\033[0;32m'
    color_error=$'\033[0;31m'
    color_prompt=$'\033[1;35m'
    color_reset=$'\033[0m'
fi

# The CLI's data folder and the login in it, which trial installations write, as protomap login would.
cli_data_dir="${PROTOMAP_DATA_DIR:-${HOME}/.protomap}"
cli_login="${cli_data_dir}/login.json"

# Prints each argument as a line.
say() { printf '%s\n' "$@"; }
title() { printf '%s%s%s\n' "$color_bold" "$1" "$color_reset"; }
# Prints each argument as a line of an error, and stops.
fail() {
    printf '%sError:%s %s\n' "$color_error" "$color_reset" "$1" >&2
    shift
    [ "$#" -eq 0 ] || printf '%s\n' "$@" >&2
    exit 1
}

# Asks $1 and leaves the answer in REPLY, which is empty when there is no input. With $2 set to "secret", the answer is
# not shown as it is typed.
prompt() {
    REPLY=""
    if [ "${2:-}" = "secret" ]; then
        read -r -s -p "${color_prompt}$1${color_reset} " REPLY || true
        say ""
    else
        read -r -p "${color_prompt}$1${color_reset} " REPLY || true
    fi
}

# Says $1, runs the command after it with its output kept aside, and says done, or failed with the output.
step() {
    local log status=0
    printf '%s... ' "$1"
    shift
    log="$(mktemp)"
    "$@" > "$log" 2>&1 < /dev/null || status=$?
    if [ "$status" -eq 0 ]; then
        say "${color_done}done${color_reset}"
    else
        say "${color_error}failed${color_reset}" ""
        cat "$log"
        say ""
    fi
    rm -f "$log"
    return "$status"
}

# Succeeds when the PostgreSQL URL $1 names a loopback host, such as localhost, which in ProtoMap's containers is the
# container itself. A user name or password holds no "@", "/", or "?" unless percent-encoded.
is_loopback_url() {
    local host="${1#*://}"
    host="${host%%[/?]*}"
    host="${host##*@}"
    case "$host" in
        "["*) host="${host%%]*}]" ;;
        *) host="${host%%[:,]*}" ;;
    esac
    case "$host" in
        localhost | localhost.* | 127.* | "[::1]") return 0 ;;
        *) return 1 ;;
    esac
}

# Prints $1 random bytes, base64url-encoded without padding or newlines.
generate_secret() {
    if command -v openssl > /dev/null 2>&1; then
        openssl rand -base64 "$1" | tr -d '\n=' | tr '+/' '-_'
    else
        head -c "$1" /dev/urandom | base64 | tr -d '\n=' | tr '+/' '-_'
    fi
}

# Prints a random UUID.
generate_uuid() {
    local hex
    hex="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s-%s-4%s-a%s-%s\n' "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" "${hex:17:3}" "${hex:20:12}"
}

# Prints the SHA-256 of $1 in lowercase hexadecimal.
hash_secret() {
    if command -v openssl > /dev/null 2>&1; then
        printf '%s' "$1" | openssl dgst -sha256 -r | awk '{ print $1 }'
    elif command -v sha256sum > /dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{ print $1 }'
    elif command -v shasum > /dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | awk '{ print $1 }'
    else
        fail "openssl, sha256sum, or shasum is required."
    fi
}

# Prints the release of ProtoMap Server that compose.yaml runs, from its image's label. Run after the image is pulled.
server_release() {
    local images image
    images="$(docker compose config --images)"
    image="$(grep -m 1 'hounddogai/protomap' <<< "$images")" || fail "compose.yaml does not run hounddogai/protomap."
    docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$image"
}

# Installs release $1 of the ProtoMap CLI, the server's, so the two speak the same API. It replaces the CLI found on
# PATH, or else installs to ~/.local/bin, which the CLI's installer puts on the PATH in the profile of the user's shell,
# and says where it went. Keep it in step with upgrade.sh.
install_cli() {
    local existing directory
    existing="$(command -v protomap || true)"
    directory="${existing:+$(dirname "$existing")}"
    directory="${directory:-${HOME}/.local/bin}"
    # The folders the CLI's installer creates are for everyone to read, whatever the caller's umask.
    (
        umask 022
        curl -fsSL https://protomap.ai/install.sh |
            PROTOMAP_INSTALL_DIR="$directory" PROTOMAP_INSTALL_BRIEF=1 sh -s -- "$1"
    ) || fail "Cannot install ProtoMap CLI $1. Install it with:" \
        "  curl -fsSL https://protomap.ai/install.sh | sh -s -- $1"
    "${directory}/protomap" --version > /dev/null 2>&1 ||
        fail "ProtoMap CLI was installed, but it does not run:" "  ${directory}/protomap"
    # Outside the PATH of this terminal, the CLI runs in the next one, which reads the profile it went on the PATH in.
    case ":${PATH}:" in
        *":${directory}:"*) cli_ready=1 ;;
        *) cli_ready="" ;;
    esac
}

env_temp=""
trap '[ -z "$env_temp" ] || rm -f "$env_temp"' EXIT

title "Installing ProtoMap Server..."
command -v docker > /dev/null 2>&1 ||
    fail "Docker is required, and it was not found." "Install Docker first: https://docs.docker.com/get-docker/"
docker compose version > /dev/null 2>&1 ||
    fail "Docker Compose v2 is required, and it was not found." "Update Docker, or install Docker Compose."
command -v curl > /dev/null 2>&1 || fail "curl is required to install ProtoMap CLI."
if [ -e .env ] || [ -L .env ]; then
    fail "ProtoMap Server is already installed." "To upgrade, run ${scripts}/upgrade.sh." \
        "To start over, run ${scripts}/uninstall.sh," "then ${scripts}/install.sh."
fi

say "" "Choose an installation:" \
    "  1) Trial       Bundled PostgreSQL, with ProtoMap CLI set up" \
    "  2) Production  Your own PostgreSQL (version 18+)" ""
while :; do
    prompt "Choose 1 or 2 [default: 1]:"
    install_type="${REPLY:-1}"
    case "$install_type" in
        1 | 2) break ;;
        *) say "Enter 1 or 2." ;;
    esac
done
while :; do
    prompt "Server port [default: 3300]:"
    port="${REPLY:-3300}"
    case "$port" in
        *[!0-9]* | "") say "Enter a port from 1 to 65535." ;;
        *)
            if [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                break
            fi
            say "Enter a port from 1 to 65535."
            ;;
    esac
done
database_url=""
if [ "$install_type" = "2" ]; then
    say "" "Enter your PostgreSQL URL, in this form:" "  postgres://USER:PASSWORD@HOST:PORT/DATABASE" ""
    while :; do
        prompt "PostgreSQL URL:" secret
        database_url="$REPLY"
        case "$database_url" in
            *"'"*) say "Percent-encode single quotes in your URL." ;;
            postgres://* | postgresql://*)
                is_loopback_url "$database_url" || break
                say "ProtoMap Server runs in containers, so localhost won't reach this computer." \
                    "Enter your database server's network address instead." \
                    "A PostgreSQL on this computer must also listen on that address," \
                    "and accept connections from Docker's networks."
                ;;
            *) say "Enter a URL that starts with postgres:// or postgresql://." ;;
        esac
    done
fi
url="http://localhost:${port}"

setup_key="$(generate_secret 32)"
api_key=""
api_key_id=""
if [ "$install_type" = "1" ]; then
    # The CLI on this computer acts as the owner with this key once setup creates the owner. The server keeps only its
    # hash.
    api_key="hd_$(generate_secret 32)"
    api_key_id="$(generate_uuid)"
fi
umask 077
env_temp="$(mktemp "$(pwd)/.env.tmp.XXXXXX")"
{
    printf '# Generated by install.sh. Keep this file private: it contains secrets.\n\n'
    printf 'PROTOMAP_SETUP_KEY=%s\n' "$setup_key"
    printf 'PROTOMAP_ADMIN_PASSWORD=%s\n' "$(generate_secret 32)"
    printf 'PROTOMAP_SECRET_KEY=%s\n' "$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
    printf 'PROTOMAP_PORT=%s\n\n' "$port"
    if [ "$install_type" = "1" ]; then
        printf 'COMPOSE_PROFILES=postgres\n'
        printf 'POSTGRES_USER=protomap\n'
        printf 'POSTGRES_PASSWORD=%s\n' "$(generate_secret 32)"
        printf 'POSTGRES_DB=protomap\n'
        # Compose expands these references when it reads the file.
        # shellcheck disable=SC2016
        printf 'PROTOMAP_DATABASE_URL=%s\n\n' \
            'postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}'
        printf 'PROTOMAP_INITIAL_API_KEY_ID=%s\n' "$api_key_id"
        printf 'PROTOMAP_INITIAL_API_KEY_HASH=%s\n' "$(hash_secret "$api_key")"
    else
        printf "PROTOMAP_DATABASE_URL='%s'\n" "$database_url"
    fi
} > "$env_temp"
mv "$env_temp" .env
env_temp=""

say "" "Created ${folder}/.env with secrets and a one-time setup key (keep it safe)."

say ""
step "Pulling images" docker compose pull --quiet ||
    fail "Cannot pull images." "Fix that error, then run ${scripts}/uninstall.sh," \
        "and ${scripts}/install.sh."
if ! step "Starting ProtoMap Server" docker compose up --detach --wait; then
    # The services' states and the server's last log lines, which say why it did not start, such as a database it
    # cannot reach.
    docker compose ps --all || true
    say "" "Last server log lines:"
    docker compose logs --no-log-prefix --tail 15 server || true
    say ""
    fail "ProtoMap Server did not start." "Fix that error, such as in your PostgreSQL URL." \
        "Then run ${scripts}/uninstall.sh, and ${scripts}/install.sh."
fi
release="$(server_release)"
say "ProtoMap Server ${release} is now running at ${url}."
install_cli "$release"
if [ "$install_type" = "1" ]; then
    mkdir -p "$cli_data_dir"
    chmod 700 "$cli_data_dir"
    # The CLI acts as the owner that setup creates next, in place of any login it has.
    printf '{"url":"%s","api_key":"%s","key_id":"%s"}\n' "$url" "$api_key" "$api_key_id" > "$cli_login"
    say "Logged ProtoMap CLI in to ${url}."
fi

say "" "ProtoMap Server is installed. Next:" ""
if [ -t 1 ]; then
    say "  1. Open ${url} and enter this one-time setup key:" "" "     ${color_bold}${setup_key}${color_reset}" ""
else
    say "  1. Open ${url} and enter the one-time setup key," "     PROTOMAP_SETUP_KEY in ${folder}/.env." ""
fi
say "     Then create your organization and its owner." ""
if [ "$install_type" = "1" ]; then
    if [ -n "$cli_ready" ]; then
        say "  2. Scan a repository:"
    else
        say "  2. Open a new terminal and scan a repository:"
    fi
    say "" "     ${color_bold}protomap scan /path/to/repository${color_reset}"
else
    if [ -n "$cli_ready" ]; then
        say "  2. Log in to ProtoMap Server, and scan a repository:"
    else
        say "  2. Open a new terminal, log in to ProtoMap Server, and scan a repository:"
    fi
    say "" "     ${color_bold}protomap login --server=${url}${color_reset}" \
        "     ${color_bold}protomap scan /path/to/repository${color_reset}"
fi
