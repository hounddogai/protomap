#!/bin/sh
#
# Installs the ProtoMap CLI from its GitHub releases. The latest release:
#
#   curl -fsSL https://protomap.ai/install.sh | sh
#
# Or a version, such as the one a ProtoMap server runs:
#
#   curl -fsSL https://protomap.ai/install.sh | sh -s -- 0.1.0
#
# The CLI installs to ~/.local/bin, or to PROTOMAP_INSTALL_DIR, which goes on the PATH in the profile of the user's
# shell, zsh, bash, or fish, unless it is already there. Releases have builds for Linux and macOS on x86_64 and
# aarch64, named protomap-<os>-<arch>, and a SHA256SUMS file that each download must match before it replaces the
# installed CLI. Windows installs with install.ps1 instead.
#
# PROTOMAP_INSTALL_BRIEF=1 says only where the CLI went, and how it reaches the PATH, for an installer that runs this
# one as a step of its own, such as ProtoMap Server's.
#
# PROTOMAP_RELEASES_URL replaces https://github.com/hounddogai/protomap/releases, such as with a mirror or a test's
# server, which serves the same paths: <url>/latest/download/<file> and <url>/download/<version>/<file>.

set -eu

# Prints each argument as a line of an error, and stops.
fail() {
    printf 'Error: %s\n' "$1" >&2
    shift
    [ "$#" -eq 0 ] || printf '%s\n' "$@" >&2
    exit 1
}

say() {
    [ -n "${brief}" ] || printf '%s\n' "$@"
}

# $1 with the home folder written as ~, which reads shorter.
# The ~ is printed as is, for the reader.
# shellcheck disable=SC2088
shorten() {
    case "$1" in
        "${HOME:-}"/*) printf '~/%s' "${1#"${HOME}/"}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Whether $1 is a version, which is a release's tag, such as 1.2.3 or 1.2.3-beta.1. The character check also refuses
# line breaks, which grep would read as separate lines.
is_version() {
    case "$1" in
        *[!0-9A-Za-z.-]*) return 1 ;;
    esac
    printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
}

brief=''
[ "${PROTOMAP_INSTALL_BRIEF:-}" != 1 ] || brief=1
# Bold marks the title and the commands to copy, in a terminal that shows it.
bold='' reset=''
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR:-}" ]; then
    bold="$(printf '\033[1m')" reset="$(printf '\033[0m')"
fi
scripts='https://protomap.ai'
[ "$#" -le 1 ] || fail 'Pass one version at most:' "  curl -fsSL ${scripts}/install.sh | sh -s -- <version>"
version="${1:-}"
[ -z "${version}" ] || is_version "${version}" ||
    fail "${version} is not a version of ProtoMap CLI." 'A version looks like 1.2.3 or 1.2.3-beta.1.'

case "$(uname -s)" in
    Linux) os=linux os_name=Linux ;;
    Darwin) os=macos os_name=macOS ;;
    # Git Bash, MSYS2, and Cygwin on Windows.
    MINGW* | MSYS* | CYGWIN*)
        if [ -n "${version}" ]; then
            fail 'On Windows, install ProtoMap CLI in PowerShell:' \
                "  & ([scriptblock]::Create((irm ${scripts}/install.ps1))) ${version}"
        fi
        fail 'On Windows, install ProtoMap CLI in PowerShell:' "  irm ${scripts}/install.ps1 | iex"
        ;;
    *) fail 'ProtoMap CLI runs on Linux, macOS, and Windows.' "This computer runs $(uname -s)." ;;
esac
case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) fail 'ProtoMap CLI runs on x86_64 and aarch64.' "This computer is $(uname -m)." ;;
esac
# The Linux builds need the GNU C library, which Alpine and other Linux distributions built on musl lack, from version
# 2.28 on, which older distributions, such as CentOS 7 and Ubuntu 18.04, lack too.
if [ "${os}" = linux ]; then
    if ldd --version 2>&1 | grep -qi musl; then
        fail 'ProtoMap CLI for Linux needs glibc.' \
            'This computer has musl instead, as Alpine Linux does.' \
            'Use a Linux with glibc, such as Debian, Ubuntu, or RHEL,' \
            'or in a container of one.'
    fi
    glibc="$(getconf GNU_LIBC_VERSION 2> /dev/null | awk '{ print $2 }')"
    if [ -n "${glibc}" ] && ! printf '%s\n' "${glibc}" | awk -F. '{ exit !($1 > 2 || $1 == 2 && $2 >= 28) }'; then
        fail 'ProtoMap CLI for Linux needs glibc 2.28 or later.' \
            "This computer has ${glibc}." \
            'Use a newer Linux, such as RHEL 8, Debian 10, or Ubuntu 20.04,' \
            'or in a container of one.'
    fi
fi
command -v curl > /dev/null 2>&1 || fail 'Install curl, then run this again.'
# Both print the checksum of standard input first: sha256sum on Linux, and shasum on macOS.
if command -v sha256sum > /dev/null 2>&1; then
    hash_file() { sha256sum < "$1"; }
elif command -v shasum > /dev/null 2>&1; then
    hash_file() { shasum -a 256 < "$1"; }
else
    fail 'Install sha256sum or shasum to verify downloads,' 'then run this again.'
fi

releases="${PROTOMAP_RELEASES_URL:-https://github.com/hounddogai/protomap/releases}"
releases="${releases%/}"
if [ -n "${version}" ]; then
    files="${releases}/download/${version}"
    release="ProtoMap CLI ${version}"
else
    files="${releases}/latest/download"
    release='the latest ProtoMap CLI release'
fi
asset="protomap-${os}-${arch}"

# Downloads the release's file named $1 to $2, or fails with the lines after them when the release does not have it.
download_file() {
    url="${files}/$1"
    status="$(curl -sSL -o "$2" -w '%{http_code}' "${url}")" ||
        fail 'Cannot download:' "  ${url}" 'Check your connection, then run this again.'
    case "${status}" in
        2??) ;;
        404)
            shift 2
            fail "$@"
            ;;
        *) fail 'Cannot download:' "  ${url}" "Server answered HTTP ${status}." ;;
    esac
}

say "${bold}Installing ProtoMap CLI...${reset}" ''
directory="${PROTOMAP_INSTALL_DIR:-${HOME}/.local/bin}"
mkdir -p "${directory}"
# Download beside the destination and rename, so a failed download never replaces a working CLI.
download="$(mktemp "${directory}/.protomap.XXXXXX")"
sums="$(mktemp "${directory}/.protomap.XXXXXX")"
trap 'rm -f "${download}" "${sums}"' EXIT
download_file SHA256SUMS "${sums}" "Cannot find ${release}, or its SHA256SUMS." 'See releases at:' "  ${releases}"
download_file "${asset}" "${download}" "There is no build for ${os_name} on ${arch} in ${release}." \
    'See releases at:' "  ${releases}"

# SHA256SUMS lists each file as <checksum>  <name>, or <checksum> *<name> in binary mode.
expected="$(awk -v name="${asset}" '$2 == name || $2 == "*" name { print tolower($1); exit }' "${sums}")"
case "${expected}" in
    '' | *[!0-9a-f]*) fail "SHA256SUMS of ${release} has no checksum for ${asset}." ;;
esac
actual="$(hash_file "${download}" | awk '{ print tolower($1) }')"
[ "${actual}" = "${expected}" ] ||
    fail "Download of ${asset} does not match SHA256SUMS." \
        'Installed CLI is unchanged.' \
        'Run this again. A repeated failure means downloads get damaged in transit.'
chmod 755 "${download}"
# The release a download of the latest one is, as the CLI tells it, such as `protomap 0.1.0`.
if [ -z "${version}" ]; then
    version="$("${download}" --version 2> /dev/null | awk '$1 == "protomap" { print $2 }')" || version=''
fi
cli="${version:+ProtoMap CLI ${version}}"
cli="${cli:-the latest ProtoMap CLI}"
mv -f "${download}" "${directory}/protomap"
rm -f "${sums}"
trap - EXIT
shown="$(shorten "${directory}")"
binary="$(shorten "${directory}/protomap")"
say "Downloaded and verified ${cli} for ${os_name} (${arch})." "Installed binary at ${binary}."
[ -z "${brief}" ] || printf '%s\n' "Installed ${cli} at ${binary}."

# Puts the folder on the PATH in the profile of the user's shell, and says how: zsh and fish do not read ~/.profile, and
# bash reads ~/.bashrc in Linux terminals, which start shells that are not login shells, and ~/.bash_profile in macOS's,
# which start them. Another shell's user adds the folder by hand.
case ":${PATH}:" in
    *":${directory}:"*) next='ProtoMap CLI is installed. Next:' ;;
    *)
        # The folder as the profile names it, under $HOME when it is there, so the line reads the same for every user.
        case "${directory}" in
            "${HOME:-}"/*) entry="\$HOME/${directory#"${HOME}/"}" ;;
            *) entry="${directory}" ;;
        esac
        profile=''
        # A folder whose name the profile's quotes cannot hold goes on the PATH by hand.
        case "${directory}" in
            *[\"\`\\$]*) ;;
            *)
                case "${SHELL:-}" in
                    */zsh) profile="${ZDOTDIR:-${HOME}}/.zshrc" line="export PATH=\"${entry}:\$PATH\"" ;;
                    */bash)
                        profile="${HOME}/.bashrc"
                        [ "${os}" != macos ] || profile="${HOME}/.bash_profile"
                        line="export PATH=\"${entry}:\$PATH\""
                        ;;
                    */fish)
                        profile="${XDG_CONFIG_HOME:-${HOME}/.config}/fish/config.fish"
                        line="fish_add_path \"${entry}\""
                        ;;
                esac
                ;;
        esac
        if [ -n "${profile}" ] && [ -f "${profile}" ] && grep -Fqx "${line}" "${profile}"; then
            next='ProtoMap CLI is installed. Open a new terminal, then:'
        elif [ -n "${profile}" ] && mkdir -p "$(dirname "${profile}")" 2> /dev/null &&
            printf '\n# ProtoMap CLI\n%s\n' "${line}" >> "${profile}" 2> /dev/null; then
            printf '%s\n' "Added ${shown} to your PATH in $(shorten "${profile}")."
            next='ProtoMap CLI is installed. Open a new terminal, then:'
        else
            printf '%s\n' "Add ${shown} to your PATH, such as in your shell's profile:" \
                "  export PATH=\"${entry}:\$PATH\""
            next='ProtoMap CLI is installed. Once it is on your PATH:'
        fi
        ;;
esac

say '' "${next}" '' \
    '  1. Log in to your ProtoMap Server:' '' \
    "     ${bold}protomap login --server=<your-server-url>${reset}" '' \
    '  2. In your repository, add ProtoMap to your coding agent, e.g. Claude Code:' '' \
    "     ${bold}claude mcp add protomap -- protomap mcp serve${reset}"
