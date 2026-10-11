#!/usr/bin/env bash
#
# Interactive reset for ProtoMap self-hosted: deletes the installation and its data, then installs it again.

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

require_docker
is_installed || fail "No installation was found. Run ./install.sh."

heading "RESET PROTOMAP"
say "Resetting will:"
say "- Stop and remove the containers"
say "- Delete the bundled PostgreSQL's data: every organization, account, and scan"
say "- Move .env and the CLI's login to backups"
say "- Start a fresh installation"
if ! uses_bundled_postgres; then
    say ""
    say "Your own PostgreSQL keeps its data. Use a new or empty database during installation."
fi
confirm "Reset ProtoMap?" n || {
    say "Reset cancelled. Nothing was changed."
    exit 0
}

heading "REMOVE THE INSTALLATION"
say "Stopping the containers and deleting their data..."
docker compose down --volumes --remove-orphans
backup_configuration

heading "START A FRESH INSTALLATION"
exec ./install.sh
