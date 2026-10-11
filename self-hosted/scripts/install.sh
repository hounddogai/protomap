#!/usr/bin/env bash
#
# Interactive installer for ProtoMap self-hosted: writes .env with secrets and a setup key, starts the services, and
# installs the ProtoMap CLI of the same release.

set -euo pipefail

# Run from the folder with compose.yaml and .env, the parent of this script's folder.
cd "$(dirname "$0")/.."

color_heading=""
color_error=""
color_prompt=""
color_reset=""
if { [ -t 1 ] || [ -t 2 ]; } && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
    color_heading=$'\033[1;36m'
    color_error=$'\033[0;31m'
    color_prompt=$'\033[1;35m'
    color_reset=$'\033[0m'
fi

# The CLI's data folder and the login in it, which trial installations write, as protomap login would.
cli_data_dir="${PROTOMAP_DATA_DIR:-${HOME}/.protomap}"
cli_login="${cli_data_dir}/login.json"

say() { printf '%s\n' "$*"; }
heading() { printf '\n%s%s%s\n' "$color_heading" "$*" "$color_reset"; }
fail() {
    printf '%sERROR:%s %s\n' "$color_error" "$color_reset" "$*" >&2
    exit 1
}

# Asks $1 and leaves the answer in REPLY, which is empty when there is no input. With $2 set to "secret", the answer is
# not shown as it is typed.
prompt() {
    say ""
    REPLY=""
    if [ "${2:-}" = "secret" ]; then
        read -r -s -p "${color_prompt}$1${color_reset} " REPLY || true
        say ""
    else
        read -r -p "${color_prompt}$1${color_reset} " REPLY || true
    fi
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

# Prints the release of ProtoMap that compose.yaml runs, from its image's label. Run after the image is pulled.
server_release() {
    local images image
    images="$(docker compose config --images)"
    image="$(grep -m 1 'hounddogai/protomap' <<< "$images")" || fail "compose.yaml does not run hounddogai/protomap."
    docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$image"
}

# Installs release $1 of the ProtoMap CLI, the server's, so the two speak the same API. It replaces the CLI found on
# PATH, or else installs to ~/.local/bin, and checks that the installed CLI runs. Keep it in step with upgrade.sh.
install_cli() {
    heading "INSTALL THE PROTOMAP CLI"
    local existing directory profile
    existing="$(command -v protomap || true)"
    directory="${existing:+$(dirname "$existing")}"
    directory="${directory:-${HOME}/.local/bin}"
    # The folders the CLI's installer creates are for everyone to read, whatever the caller's umask.
    (
        umask 022
        curl -fsSL https://install.protomap.ai | PROTOMAP_INSTALL_DIR="$directory" sh -s -- "$1" > /dev/null
    ) ||
        fail "Cannot install ProtoMap CLI $1. Install it with: curl -fsSL https://install.protomap.ai | sh -s -- $1"
    cli="${directory}/protomap"
    cli_version="$("$cli" --version)" || fail "The ProtoMap CLI was installed at ${cli} but does not run."
    say "Installed ${cli_version} at ${cli}."
    case ":${PATH}:" in
        *":${directory}:"*) cli="protomap" ;;
        *)
            # The profile of the user's shell, as the CLI's installer picks it: zsh and fish do not read ~/.profile,
            # and bash reads ~/.bashrc in Linux terminals and ~/.bash_profile in macOS's.
            case "${SHELL:-}" in
                */zsh) profile=.zshrc ;;
                */bash) if [ "$(uname -s)" = Darwin ]; then profile=.bash_profile; else profile=.bashrc; fi ;;
                */fish) profile="" ;;
                *) profile=.profile ;;
            esac
            if [ -n "$profile" ]; then
                say "${directory} is not on your PATH. Add it to your shell's profile, such as with:"
                say "  echo 'export PATH=\"${directory}:\$PATH\"' >> ~/${profile}"
            else
                say "${directory} is not on your PATH. Add it in fish with:"
                say "  fish_add_path '${directory}'"
            fi
            ;;
    esac
}

env_temp=""
trap '[ -z "$env_temp" ] || rm -f "$env_temp"' EXIT

heading "CHECK REQUIREMENTS"
say "Checking Docker, Docker Compose, and curl..."
command -v docker > /dev/null 2>&1 ||
    fail "Docker is required but was not found. Install it first: https://docs.docker.com/get-docker/"
docker compose version > /dev/null 2>&1 ||
    fail "Docker Compose v2 is required but was not found. Update Docker or install the Compose plugin."
command -v curl > /dev/null 2>&1 || fail "curl is required to install the ProtoMap CLI."
if [ -e .env ] || [ -L .env ]; then
    fail "ProtoMap is already installed. Run ./scripts/upgrade.sh to upgrade it, or ./scripts/uninstall.sh and then" \
        "./scripts/install.sh to start over."
fi

heading "CHOOSE INSTALLATION"
say "1) Trial: uses the bundled PostgreSQL and sets up the CLI on this computer."
say "2) Production: uses your PostgreSQL 18 or newer."
while :; do
    prompt "Choose 1 or 2 [default: 1]:"
    install_type="${REPLY:-1}"
    case "$install_type" in
        1 | 2) break ;;
        *) say "Enter 1 or 2." ;;
    esac
done
while :; do
    prompt "Port [default: 3300]:"
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
    say ""
    say "Enter your PostgreSQL URL in the form postgres://USER:PASSWORD@HOST:PORT/DATABASE"
    while :; do
        prompt "PostgreSQL URL:" secret
        database_url="$REPLY"
        case "$database_url" in
            *"'"*) say "Percent-encode single quotes in the URL." ;;
            postgres://* | postgresql://*)
                is_loopback_url "$database_url" || break
                say "ProtoMap runs in containers, where localhost is the container itself, not this computer."
                say "Enter the address of the database's server on the network instead. A PostgreSQL on this computer"
                say "must also listen on that address and accept connections from Docker's networks."
                ;;
            *) say "Enter a URL that starts with postgres:// or postgresql://." ;;
        esac
    done
fi
url="http://localhost:${port}"

heading "GENERATE CONFIGURATION"
say "Creating $(pwd)/.env with new secrets and a one-time setup key..."
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

heading "START PROTOMAP"
say "Pulling the images and waiting for ProtoMap to start..."
docker compose pull --quiet ||
    fail "Cannot pull the images. Fix the reported error, run ./scripts/uninstall.sh, then ./scripts/install.sh."
if ! docker compose up --detach --wait; then
    # The services' states and the server's last log lines, which say why it did not start, such as a database it
    # cannot reach.
    docker compose ps --all || true
    heading "SERVER LOG"
    docker compose logs --no-log-prefix --tail 15 server || true
    fail "ProtoMap did not start. Fix the error above, such as in the PostgreSQL URL, run ./scripts/uninstall.sh," \
        "then ./scripts/install.sh."
fi
release="$(server_release)"
say "ProtoMap ${release} is running at ${url}."

install_cli "$release"
if [ "$install_type" = "1" ]; then
    mkdir -p "$cli_data_dir"
    chmod 700 "$cli_data_dir"
    if [ -e "$cli_login" ]; then
        backup="${cli_login}.backup.$(date +%Y%m%d-%H%M%S)"
        mv "$cli_login" "$backup"
        say "Moved the CLI's previous login to ${backup}."
    fi
    printf '{"url":"%s","api_key":"%s","key_id":"%s"}\n' "$url" "$api_key" "$api_key_id" > "$cli_login"
    say "Logged the CLI in to ${url}. It acts as the owner you create next."
fi

heading "NEXT STEPS"
say "1. Open ${url}, or this computer's address from another computer, and create your organization and owner."
if [ -t 1 ]; then
    say "2. Enter the one-time setup key: ${setup_key}"
else
    say "2. Enter the one-time setup key PROTOMAP_SETUP_KEY from .env."
fi
if [ "$install_type" = "1" ]; then
    say "3. Scan a repository: ${cli} scan /path/to/repository"
else
    say "3. Log in to the CLI, then scan a repository:"
    say "   ${cli} login --server=<this server's address>"
    say "   ${cli} scan /path/to/repository"
fi
