#!/usr/bin/env bash
#
# Installer for ProtoMap Server: asks for each choice its options do not give, writes .env with secrets and a setup
# key, starts the services, and installs the ProtoMap CLI of the same release.

set -euo pipefail

# This script's folder, and the folder above it with compose.yaml and .env, as the command that ran the script names
# them, such as ./server/scripts and ./server from the root of the clone, so the commands and files the
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

usage() {
    say "Usage: $0 [--trial | --production] [--port=PORT] [--dashboard-port=PORT] [--name=NAME]" \
        "       [--replace-login]" "" \
        "Installs ProtoMap Server, and asks for each choice that no option gives." "" \
        "  --trial                Bundled PostgreSQL, with ProtoMap CLI set up" \
        "  --production           Your own PostgreSQL (version 18+), at the URL in PROTOMAP_DATABASE_URL" \
        "                         or the one the installer asks for" \
        "  --port=PORT            The server's port [default: 3300]" \
        "  --dashboard-port=PORT  The job queue dashboard's port, on 127.0.0.1 only [default: 8801, or the" \
        "                         next free port, which the installer asks about]" \
        "  --name=NAME            The Docker Compose project name, which must be unused [default: protomap]" \
        "  --replace-login        With --trial, log ProtoMap CLI in to this server without asking, even when" \
        "                         it is logged in to another server, whose login is kept in a backup" "" \
        "PROTOMAP_DASHBOARD_PORT and COMPOSE_PROJECT_NAME give the dashboard port and the name too." \
        "Without input, such as in a script, every question takes its default answer: a CLI logged in to" \
        "another server stays logged in to it, and is left as it is, unless --replace-login is given."
}

# Whether the input ended, such as the answers that a script pipes in, so no question can be asked again.
is_input_closed=""

# Asks $1 and leaves the answer in REPLY, which is empty when there is no input. With $2 set to "secret", the answer is
# not shown as it is typed.
prompt() {
    REPLY=""
    if [ "${2:-}" = "secret" ]; then
        read -r -s -p "${color_prompt}$1${color_reset} " REPLY || is_input_closed=1
        say ""
    else
        read -r -p "${color_prompt}$1${color_reset} " REPLY || is_input_closed=1
    fi
}

# Says why an answer was rejected, so the question is asked again, or stops when the input ended.
reject_answer() {
    [ -z "$is_input_closed" ] || fail "$@"
    say "$@"
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

# Prints why ProtoMap Server cannot use the PostgreSQL URL $1, or nothing when it can.
database_url_problem() {
    case "$1" in
        *"'"*) say "Percent-encode single quotes in your URL." ;;
        postgres://* | postgresql://*)
            if is_loopback_url "$1"; then
                say "ProtoMap Server runs in containers, so localhost won't reach this computer." \
                    "Use your database server's network address instead." \
                    "A PostgreSQL on this computer must also listen on that address," \
                    "and accept connections from Docker's networks."
            fi
            ;;
        *) say "Use a URL that starts with postgres:// or postgresql://." ;;
    esac
}

# Prints why ProtoMap Server cannot use port $1, or nothing when it can. A port that a program on this computer already
# accepts connections on, such as a development server, is in use. Browsers refuse to open the ports Chrome and Firefox
# block, such as 6000.
port_problem() {
    case "$1" in
        "" | *[!0-9]* | ??????*)
            say "Use a port from 1 to 65535."
            return
            ;;
    esac
    case "$1" in
        1 | 7 | 9 | 11 | 13 | 15 | 17 | 19 | 20 | 21 | 22 | 23 | 25 | 37 | 42 | 43 | 53 | 69 | 77 | 79 | 87 | \
            95 | 101 | 102 | 103 | 104 | 109 | 110 | 111 | 113 | 115 | 117 | 119 | 123 | 135 | 137 | 139 | 143 | \
            161 | 179 | 389 | 427 | 465 | 512 | 513 | 514 | 515 | 526 | 530 | 531 | 532 | 540 | 548 | 554 | 556 | \
            563 | 587 | 601 | 636 | 989 | 990 | 993 | 995 | 1719 | 1720 | 1723 | 2049 | 3659 | 4045 | 4190 | 5060 | \
            5061 | 6000 | 6566 | 6665 | 6666 | 6667 | 6668 | 6669 | 6679 | 6697 | 10080)
            say "Browsers refuse to open port $1. Choose another port."
            return
            ;;
    esac
    if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
        say "Use a port from 1 to 65535."
    elif (exec 3<> "/dev/tcp/localhost/$1") 2> /dev/null; then
        say "Port $1 is in use. Stop the program that uses it, or choose another port."
    fi
}

# Prints why ProtoMap Server cannot use the Docker Compose project name $1, or nothing when it can. Containers and
# volumes are named after the project, so a name another installation uses, even a stopped one, would put this one's
# settings on its containers and its database, and its scripts would act on both.
project_problem() {
    # Bash 3.2 matches ranges such as a-z by the locale's collation, which puts capitals among them.
    local folders LC_ALL=C
    case "$1" in
        "" | [!a-z0-9]* | *[!a-z0-9_-]*)
            say "Use a name of lowercase letters, digits, hyphens, and underscores that starts with a letter or digit."
            return
            ;;
    esac
    folders="$(docker ps --all --filter "label=com.docker.compose.project=$1" \
        --format '{{ .Label "com.docker.compose.project.working_dir" }}' | sort -u | tr '\n' ' ')"
    if [ -n "$folders" ]; then
        say "Docker already has containers named after $1, of the installation in ${folders% }."
    elif [ -n "$(docker volume ls --quiet --filter "label=com.docker.compose.project=$1")" ]; then
        say "Docker already has volumes named after $1, which an earlier installation left, such as its database."
    else
        return 0
    fi
    say "Choose another name for this installation with --name=NAME, such as --name=$1-2." \
        "If you no longer need that installation, nor its data, remove both with:" \
        "  docker compose --project-name $1 down --volumes"
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

# Installs release $1 of the ProtoMap CLI, the server's, so the two speak the same API. Installing a given release
# turns the CLI's automatic updates off, so it stays at the server's release until an upgrade installs the next. It
# replaces the CLI found on PATH, or else installs to ~/.local/bin, which the CLI's installer puts on the PATH in the
# profile of the user's shell, and says where it went. Keep it in step with upgrade.sh.
install_cli() {
    local existing directory
    existing="$(command -v protomap || true)"
    directory="${existing:+$(dirname "$existing")}"
    directory="${directory:-${HOME}/.local/bin}"
    # The folders the CLI's installer creates are for everyone to read, whatever the caller's umask.
    (
        umask 022
        curl -fsSL https://protomap.ai/install.sh |
            PROTOMAP_INSTALL_DIR="$directory" PROTOMAP_INSTALL_BRIEF=1 sh -s -- --version "$1"
    ) || fail "Cannot install ProtoMap CLI $1. Install it with:" \
        "  curl -fsSL https://protomap.ai/install.sh | sh -s -- --version $1"
    "${directory}/protomap" --version > /dev/null 2>&1 ||
        fail "ProtoMap CLI was installed, but it does not run:" "  ${directory}/protomap"
    # Outside the PATH of this terminal, the CLI runs in the next one, which reads the profile it went on the PATH in.
    case ":${PATH}:" in
        *":${directory}:"*) cli_ready=1 ;;
        *) cli_ready="" ;;
    esac
}

install_type=""
port=""
dashboard_port="${PROTOMAP_DASHBOARD_PORT:-}"
name="${COMPOSE_PROJECT_NAME:-}"
is_login_replaced=""
for option in "$@"; do
    case "$option" in
        --trial) install_type=1 ;;
        --production) install_type=2 ;;
        --port=*) port="${option#--port=}" ;;
        --dashboard-port=*) dashboard_port="${option#--dashboard-port=}" ;;
        --name=*) name="${option#--name=}" ;;
        --replace-login) is_login_replaced=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) fail "Unknown option: ${option}" "$(usage)" ;;
    esac
done

env_temp=""
trap '[ -z "$env_temp" ] || rm -f "$env_temp"' EXIT

title "Installing ProtoMap Server..."
command -v docker > /dev/null 2>&1 ||
    fail "Docker is required, and it was not found." "Install Docker first: https://docs.docker.com/get-docker/"
docker compose version > /dev/null 2>&1 ||
    fail "Docker Compose v2 is required, and it was not found." "Update Docker, or install Docker Compose."
command -v curl > /dev/null 2>&1 || fail "curl is required to install ProtoMap CLI."
docker ps > /dev/null 2>&1 ||
    fail "Docker is not running, or this user cannot use it." "Start Docker, then run ${scripts}/install.sh again."
if [ -e .env ] || [ -L .env ]; then
    fail "ProtoMap Server is already installed." "To upgrade, run ${scripts}/upgrade.sh." \
        "To start over, run ${scripts}/uninstall.sh," "then ${scripts}/install.sh."
fi
name="${name:-protomap}"
problem="$(project_problem "$name")"
[ -z "$problem" ] || fail "$problem"

if [ -z "$install_type" ]; then
    say "" "Choose an installation:" \
        "  1) Trial       Bundled PostgreSQL, with ProtoMap CLI set up" \
        "  2) Production  Your own PostgreSQL (version 18+)" ""
    while :; do
        prompt "Choose 1 or 2 [default: 1]:"
        install_type="${REPLY:-1}"
        case "$install_type" in
            1 | 2) break ;;
            *) reject_answer "Enter 1 or 2." ;;
        esac
    done
fi
if [ -n "$port" ]; then
    problem="$(port_problem "$port")"
    [ -z "$problem" ] || fail "$problem"
else
    while :; do
        prompt "Server port [default: 3300]:"
        port="${REPLY:-3300}"
        problem="$(port_problem "$port")"
        [ -n "$problem" ] || break
        reject_answer "$problem"
    done
fi
# The dashboard is secondary, so when its default port is taken, the question offers the next free one.
if [ -n "$dashboard_port" ]; then
    problem="$(port_problem "$dashboard_port")"
    [ "$dashboard_port" != "$port" ] || problem="The server uses port ${port}. Choose another port."
    [ -z "$problem" ] || fail "$problem"
else
    dashboard_port=8801
    problem="$(port_problem "$dashboard_port")"
    [ "$dashboard_port" != "$port" ] || problem="The server uses port ${port}."
    if [ -n "$problem" ]; then
        free=8802
        while [ -n "$(port_problem "$free")" ] || [ "$free" = "$port" ]; do
            free=$((free + 1))
        done
        say "$problem"
        while :; do
            prompt "Job queue dashboard port [default: ${free}]:"
            dashboard_port="${REPLY:-$free}"
            problem="$(port_problem "$dashboard_port")"
            [ "$dashboard_port" != "$port" ] || problem="The server uses port ${port}. Choose another port."
            [ -n "$problem" ] || break
            reject_answer "$problem"
        done
    fi
fi
database_url=""
if [ "$install_type" = "2" ] && [ -n "${PROTOMAP_DATABASE_URL:-}" ]; then
    database_url="$PROTOMAP_DATABASE_URL"
    problem="$(database_url_problem "$database_url")"
    [ -z "$problem" ] || fail "ProtoMap Server cannot use PROTOMAP_DATABASE_URL." "$problem"
elif [ "$install_type" = "2" ]; then
    say "" "Enter your PostgreSQL URL, in this form:" "  postgres://USER:PASSWORD@HOST:PORT/DATABASE" ""
    while :; do
        prompt "PostgreSQL URL:" secret
        database_url="$REPLY"
        problem="$(database_url_problem "$database_url")"
        [ -n "$problem" ] || break
        reject_answer "$problem"
    done
fi
url="http://localhost:${port}"

# A trial logs the CLI in to this server. A login to another server, such as ProtoMap's cloud, is replaced only when
# the user agrees, and is then kept in a backup, which uninstall.sh puts back.
previous_url=""
[ ! -e "$cli_login" ] || previous_url="$(sed -n 's/.*"url":"\([^"]*\)".*/\1/p' "$cli_login")"
has_other_login=""
if [ -e "$cli_login" ] && [ "$previous_url" != "$url" ]; then
    has_other_login=1
fi
if [ "$install_type" = "1" ] && [ -n "$has_other_login" ] && [ -z "$is_login_replaced" ]; then
    say "" "ProtoMap CLI is logged in to ${previous_url:-another server}."
    while :; do
        prompt "Log it in to this server instead, and keep that login in a backup? [y/N]:"
        case "${REPLY:-n}" in
            y | Y | yes | YES) is_login_replaced=1 && break ;;
            n | N | no | NO) break ;;
            *) reject_answer "Enter y or n." ;;
        esac
    done
fi
if [ "$install_type" != "1" ]; then
    is_login_replaced=""
elif [ -z "$has_other_login" ]; then
    is_login_replaced=1
fi
# A CLI that stays logged in to another server keeps its release and update settings, which suit that server.
is_cli_kept=""
if [ -n "$has_other_login" ] && [ -z "$is_login_replaced" ] && command -v protomap > /dev/null 2>&1; then
    is_cli_kept=1
fi
login_backup=""
if [ -n "$is_login_replaced" ] && [ -e "$cli_login" ]; then
    login_backup="${cli_login}.backup.$(date +%Y%m%d-%H%M%S)"
fi

setup_key="$(generate_secret 32)"
api_key=""
api_key_id=""
if [ -n "$is_login_replaced" ]; then
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
    printf 'PROTOMAP_PORT=%s\n' "$port"
    printf 'PROTOMAP_DASHBOARD_PORT=%s\n' "$dashboard_port"
    printf '# The Docker Compose project, which names the containers and volumes.\n'
    printf 'COMPOSE_PROJECT_NAME=%s\n\n' "$name"
    if [ "$install_type" = "1" ]; then
        printf 'COMPOSE_PROFILES=postgres\n'
        printf 'POSTGRES_USER=protomap\n'
        printf 'POSTGRES_PASSWORD=%s\n' "$(generate_secret 32)"
        printf 'POSTGRES_DB=protomap\n'
        # Compose expands these references when it reads the file.
        # shellcheck disable=SC2016
        printf 'PROTOMAP_DATABASE_URL=%s\n' \
            'postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}'
    else
        printf "PROTOMAP_DATABASE_URL='%s'\n" "$database_url"
    fi
    if [ -n "$api_key" ]; then
        printf '\nPROTOMAP_INITIAL_API_KEY_ID=%s\n' "$api_key_id"
        printf 'PROTOMAP_INITIAL_API_KEY_HASH=%s\n' "$(hash_secret "$api_key")"
    fi
    if [ -n "$is_cli_kept" ]; then
        printf '\n# The CLI stayed as it was, logged in to another server, so upgrade.sh leaves it as it is too.\n'
        printf 'PROTOMAP_CLI_KEPT=1\n'
    fi
    if [ -n "$login_backup" ] && [ -n "$has_other_login" ]; then
        printf '\n# The CLI login that this installation replaced, which uninstall.sh puts back.\n'
        printf "PROTOMAP_CLI_LOGIN_BACKUP='%s'\n" "$login_backup"
    fi
} > "$env_temp"
mv "$env_temp" .env
env_temp=""

say "" "Created ${folder}/.env with secrets and a one-time setup key (keep it safe)."
# Docker Compose takes these from the environment before .env, so the commands below use this installation's.
export COMPOSE_PROJECT_NAME="$name" PROTOMAP_PORT="$port" PROTOMAP_DASHBOARD_PORT="$dashboard_port"

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
    hint="Fix that error."
    [ "$install_type" = "1" ] || hint="Fix that error, such as in your PostgreSQL URL."
    fail "ProtoMap Server did not start." "$hint" "Then run ${scripts}/uninstall.sh, and ${scripts}/install.sh."
fi
release="$(server_release)"
say "ProtoMap Server ${release} is now running at ${url}."
if [ -n "$is_cli_kept" ]; then
    cli_ready=1
    say "Left ProtoMap CLI as it is, since it is logged in to ${previous_url:-another server}." \
        "To install the CLI of this server's release instead, run:" \
        "  curl -fsSL https://protomap.ai/install.sh | sh -s -- --version ${release}"
else
    install_cli "$release"
fi
if [ -n "$is_login_replaced" ]; then
    mkdir -p "$cli_data_dir"
    chmod 700 "$cli_data_dir"
    # The CLI acts as the owner that setup creates next, in place of any login it has, which is kept in a backup.
    if [ -n "$login_backup" ]; then
        mv "$cli_login" "$login_backup"
        say "Moved the CLI's previous login, to ${previous_url:-another server}, to ${login_backup}."
    fi
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
if [ -n "$is_login_replaced" ]; then
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
    [ -z "$has_other_login" ] || say "     (Logging in replaces the CLI's login to ${previous_url:-another server}.)"
    say "" "     ${color_bold}protomap login --server=${url}${color_reset}" \
        "     ${color_bold}protomap scan /path/to/repository${color_reset}"
fi
