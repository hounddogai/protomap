#!/bin/sh
#
# Installs the ProtoMap CLI from its GitHub releases. The latest release:
#
#   curl -fsSL https://install.protomap.ai | sh
#
# Or a version, such as the one a ProtoMap server runs, which its platform's install command names:
#
#   curl -fsSL https://install.protomap.ai | sh -s -- 0.1.0
#
# The CLI installs to ~/.local/bin, or to PROTOMAP_INSTALL_DIR. Releases have builds for Linux and macOS on x86_64 and
# aarch64, named protomap-<os>-<arch>, and a SHA256SUMS file that each download must match before it replaces the
# installed CLI. Windows installs with install.ps1 instead.
#
# PROTOMAP_RELEASES_URL replaces https://github.com/hounddogai/protomap/releases, such as with a mirror or a test's
# server, which serves the same paths: <url>/latest/download/<file> and <url>/download/<version>/<file>.

set -eu

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

# Quotes a word for a POSIX shell, so a printed command still works when its path holds spaces.
quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Whether $1 is a version, which is a release's tag, such as 1.2.3 or 1.2.3-beta.1. The character check also refuses
# line breaks, which grep would read as separate lines.
is_version() {
    case "$1" in
        *[!0-9A-Za-z.-]*) return 1 ;;
    esac
    printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
}

script_url='https://install.protomap.ai'
[ "$#" -le 1 ] || fail 'Pass one version at most:' "curl -fsSL ${script_url} | sh -s -- <version>"
version="${1:-}"
[ -z "${version}" ] || is_version "${version}" ||
    fail "${version} is not a version of the ProtoMap CLI, such as 1.2.3 or 1.2.3-beta.1."

case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    # Git Bash, MSYS2, and Cygwin on Windows.
    MINGW* | MSYS* | CYGWIN*)
        fail 'On Windows, install the ProtoMap CLI in PowerShell:' \
            "& ([scriptblock]::Create((irm ${script_url}/install.ps1)))${version:+ ${version}}"
        ;;
    *) fail "The ProtoMap CLI runs on Linux, macOS, and Windows; this computer runs $(uname -s)." ;;
esac
case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) fail "The ProtoMap CLI runs on x86_64 and aarch64; this computer is $(uname -m)." ;;
esac
command -v curl > /dev/null 2>&1 || fail 'Install curl, then run this again.'
# Both print the checksum of standard input first: sha256sum on Linux, and shasum on macOS.
if command -v sha256sum > /dev/null 2>&1; then
    hash_file() { sha256sum < "$1"; }
elif command -v shasum > /dev/null 2>&1; then
    hash_file() { shasum -a 256 < "$1"; }
else
    fail 'Install sha256sum or shasum, which check the download, then run this again.'
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

# Downloads the release's file named $1 to $2, or fails with $3 when the release does not have it.
download_file() {
    status="$(curl -sSL -o "$2" -w '%{http_code}' "${files}/$1")" ||
        fail "Cannot download ${files}/$1. Check the connection, then run this again."
    case "${status}" in
        2??) ;;
        404) fail "$3" ;;
        *) fail "Cannot download ${files}/$1: the server answered HTTP ${status}." ;;
    esac
}

directory="${PROTOMAP_INSTALL_DIR:-${HOME}/.local/bin}"
mkdir -p "${directory}"
# Download beside the destination and rename, so a failed download never replaces a working CLI.
download="$(mktemp "${directory}/.protomap.XXXXXX")"
sums="$(mktemp "${directory}/.protomap.XXXXXX")"
trap 'rm -f "${download}" "${sums}"' EXIT
printf '%s\n' "Downloading ${release} for ${os} on ${arch} from ${releases}"
download_file SHA256SUMS "${sums}" \
    "Cannot find ${release}, or its SHA256SUMS. See the releases at ${releases}"
download_file "${asset}" "${download}" \
    "There is no build for ${os} on ${arch} in ${release}. See the releases at ${releases}"

# SHA256SUMS lists each file as <checksum>  <name>, or <checksum> *<name> in binary mode.
expected="$(awk -v name="${asset}" '$2 == name || $2 == "*" name { print tolower($1); exit }' "${sums}")"
case "${expected}" in
    '' | *[!0-9a-f]*) fail "The SHA256SUMS of ${release} has no checksum for ${asset}." ;;
esac
actual="$(hash_file "${download}" | awk '{ print tolower($1) }')"
[ "${actual}" = "${expected}" ] ||
    fail "The download of ${asset} does not match its checksum in SHA256SUMS, so the installed CLI stays as it was." \
        "Run this again; if it fails again, the download is damaged on its way to this computer."
chmod 755 "${download}"
mv -f "${download}" "${directory}/protomap"
rm -f "${sums}"
trap - EXIT

printf '%s\n' "Installed ${release} to ${directory}/protomap."
case ":${PATH}:" in
    *":${directory}:"*) command="protomap" ;;
    *)
        command="$(quote "${directory}/protomap")"
        printf '%s\n' "${directory} is not on your PATH. Add it to your shell's profile, such as with:" \
            "  echo 'export PATH=\"${directory}:\$PATH\"' >> ~/.profile"
        ;;
esac
printf '%s\n' "Log in with: ${command} login --server=<your ProtoMap server's address>" \
    "Then add ProtoMap to your coding agent, such as Claude Code, so it reads the graph with your changes" \
    "laid over it:" \
    "  claude mcp add protomap -- ${command} mcp serve" \
    "Other coding agents run ${command} mcp serve from the repository's folder, over standard input and output."
