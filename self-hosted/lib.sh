# shellcheck shell=bash
# Helpers that install.sh, upgrade.sh, reset.sh, and uninstall.sh share. Each script changes to this folder first, then
# sources this file.

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

# The CLI's data folder and the login in it, which install.sh writes for trial installations, as protomap login would.
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

# Asks the yes or no question $1, with $2, y or n, as the answer for no input, and succeeds for yes.
confirm() {
    prompt "$1 [y/n, default: $2]:"
    case "${REPLY:-$2}" in
        y | Y | yes | YES) return 0 ;;
        *) return 1 ;;
    esac
}

require_docker() {
    heading "CHECK REQUIREMENTS"
    say "Checking Docker, Docker Compose, and curl..."
    command -v docker > /dev/null 2>&1 ||
        fail "Docker is required but was not found. Install it first: https://docs.docker.com/get-docker/"
    docker compose version > /dev/null 2>&1 ||
        fail "Docker Compose v2 is required but was not found. Update Docker or install the Compose plugin."
    command -v curl > /dev/null 2>&1 || fail "curl is required to install the ProtoMap CLI."
}

is_installed() {
    [ -e .env ] || [ -L .env ]
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

# Shows the services' states and the server's last log lines, which say why it did not start, such as a database it
# cannot reach.
show_server_log() {
    docker compose ps --all || true
    heading "SERVER LOG"
    docker compose logs --no-log-prefix --tail 15 server || true
}

# Whether the installation runs the bundled PostgreSQL, whose data lives in a Docker volume.
uses_bundled_postgres() {
    grep -Eq '^COMPOSE_PROFILES=.*postgres' .env
}

# Prints the value of $1 in .env, or nothing.
read_setting() {
    sed -n "s/^$1=//p" .env | tail -n 1
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

# Prints the release the running server container runs, or nothing when there is none.
running_release() {
    local containers
    containers="$(docker compose ps --all --quiet server)"
    [ -n "$containers" ] || return 0
    docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "${containers%%$'\n'*}"
}

# Succeeds when release $1 is older than release $2. A release is a version such as 1.2.3, or 1.2.3-beta.1 for a
# pre-release, which is older than 1.2.3. Anything else, such as no release, is older than none, and so is one of two
# pre-releases of the same version. Only shell arithmetic compares them, since sort -V is not on every system.
is_older_release() {
    local older="$1" newer="$2" a b
    is_release "$older" && is_release "$newer" || return 1
    a="${older%%-*}." b="${newer%%-*}."
    while [ -n "$a" ]; do
        if [ "${a%%.*}" -ne "${b%%.*}" ]; then
            [ "${a%%.*}" -lt "${b%%.*}" ]
            return
        fi
        a="${a#*.}" b="${b#*.}"
    done
    [ "$older" != "${older%%-*}" ] && [ "$newer" = "${newer%%-*}" ]
}

# Succeeds when $1 is a release: three numbers separated by dots, and maybe a pre-release after a hyphen.
is_release() {
    case "${1%%-*}" in
        *[!0-9.]* | .* | *. | *..* | *.*.*.*) return 1 ;;
        *.*.*) return 0 ;;
        *) return 1 ;;
    esac
}

# Installs release $1 of the ProtoMap CLI, the server's, so the two speak the same API. It replaces the CLI found on
# PATH, or else installs to ~/.local/bin, and checks that the installed CLI runs.
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

# Moves .env, and the CLI's login when it is for this installation, to backups, which keep the secrets of the removed
# installation, such as the key its stored API keys are encrypted with.
backup_configuration() {
    local stamp url
    stamp="$(date +%Y%m%d-%H%M%S)"
    url="http://localhost:$(read_setting PROTOMAP_PORT)"
    if [ -e "$cli_login" ] && grep -Fq "\"url\":\"${url}\"" "$cli_login"; then
        mv "$cli_login" "${cli_login}.backup.${stamp}"
        say "Moved the CLI's login to ${cli_login}.backup.${stamp}."
    fi
    mv .env ".env.backup.${stamp}"
    say "Moved .env to $(pwd)/.env.backup.${stamp}."
}
