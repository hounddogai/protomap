#!/usr/bin/env bash
#
# Interactive uninstall for ProtoMap self-hosted: removes the installation and its data, and keeps the CLI.

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

require_docker
if ! is_installed; then
    say "No installation was found. Nothing to uninstall."
    exit 0
fi

heading "UNINSTALL PROTOMAP"
say "Uninstalling will:"
say "- Stop and remove the containers"
say "- Delete the bundled PostgreSQL's data: every organization, account, and scan"
say "- Move .env and the CLI's login to backups"
say "- Keep the CLI, the Docker images, and this folder"
if ! uses_bundled_postgres; then
    say ""
    say "Your own PostgreSQL keeps its data."
fi
confirm "Uninstall ProtoMap?" n || {
    say "Uninstall cancelled. Nothing was changed."
    exit 0
}

heading "REMOVE THE INSTALLATION"
say "Stopping the containers and deleting their data..."
docker compose down --volumes --remove-orphans
backup_configuration

heading "UNINSTALL COMPLETE"
say "ProtoMap self-hosted is uninstalled."
