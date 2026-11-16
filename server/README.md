# ProtoMap Server

Run ProtoMap Server in your own environment. The commands below run from `protomap`, the root of the clone.

![The services of a scanned repository, and how they call each other](images/service-sphere.png)

## Requirements

- Docker with Compose 2.23.1 or newer
- At least 4 GB of RAM and 20 GB of disk space

## Installation

```shell
git clone https://github.com/hounddogai/protomap.git
cd protomap
./server/scripts/install.sh
```

The installer asks for the installation type and the server's port, 3300 by default:

1. **Trial:** The quickest way to try ProtoMap. PostgreSQL is set up locally for you.
2. **Production:** Connects ProtoMap to your own PostgreSQL 18 database. This option requires more setup and
   maintenance.

To install without questions, such as from a script, give your choices as options:

```shell
./server/scripts/install.sh --trial --port=3300
PROTOMAP_DATABASE_URL='postgres://USER:PASSWORD@HOST:PORT/DATABASE' ./server/scripts/install.sh --production
```

`./server/scripts/install.sh --help` lists every option, such as `--dashboard-port` for the job queue dashboard (8801 on
`127.0.0.1` by default). Each installation on a computer needs a Docker Compose project name of its own, `protomap` by
default, so give a second one another with `--name`, such as `--name=protomap-2`.

When the installation finishes:

1. Open the ProtoMap URL the installer prints, such as `http://localhost:3300`, or this computer's address from another
   computer.
2. Enter the one-time setup key, which the installer prints when it runs in a terminal, and keeps as
   `PROTOMAP_SETUP_KEY` in `server/.env`.
3. Create your organization and owner account.

The installer also installs the ProtoMap CLI at the server's release. In Trial mode, it logs the CLI in as the owner, so
you can scan a repository right away:

```shell
protomap scan /path/to/repository
```

When the CLI is already logged in to another server, such as ProtoMap's cloud, the installer asks before it replaces
that login, and keeps a backup of it, which uninstalling puts back. Without input, such as from a script, the CLI keeps
its login and version unless you give `--replace-login`; log in to this server later with
`protomap login --server=<address>`. Each scan names its **Destination** before it starts.

To install the CLI on other computers and connect coding agents, see the [main README](../README.md).

## Configuration

The installer writes your settings to `server/.env`, and [`server/.env.example`](.env.example) explains every setting.
After you change `server/.env`, apply it with `docker compose --file server/compose.yaml up -d`.

Back up `server/.env` along with your database. Its `PROTOMAP_SECRET_KEY` encrypts the AI provider API keys that
ProtoMap Server stores, which cannot be read without it.

By default, ProtoMap Server is reachable from other machines on your network over plain HTTP. For anything but a trial,
put a proxy that serves HTTPS in front of it, and set `PROTOMAP_BIND_ADDRESS=127.0.0.1` so that only the proxy can reach
it.

## Upgrade

Back up your database first, because ProtoMap Server is briefly unavailable while the upgrade runs. Upgrading keeps your
configuration and data:

```shell
git pull && ./server/scripts/upgrade.sh
```

ProtoMap Server runs the latest release unless `PROTOMAP_VERSION` in `server/.env` names another, such as `1.2.3`. If
the upgrade fails, the previous version starts again: fix the reported error and run the upgrade again. The upgrade also
installs the CLI of the new release where the installer pinned the CLI to the server's release, or installed none.

After an upgrade to another release, scan again each repository that the platform marks "Needs a new scan": the shared
graph shows the new scans once every such repository is scanned again or removed. On other computers, a CLI that updates
itself does so when the server asks it to; install one pinned to a version again at the server's release with
`curl -fsSL https://protomap.ai/install.sh | sh -s -- --version <release>`.

The upgrade refuses a release older than the one running. To go back to one, restore the database backup made before
upgrading from it, set `PROTOMAP_VERSION` in `server/.env` to that release, then run
`docker compose --file server/compose.yaml down` and `./server/scripts/upgrade.sh`.

## Uninstall

Uninstall removes ProtoMap Server and its data. It offers to back up `server/.env`, the CLI's login, and the bundled
database first. It keeps the CLI, those backups, the clone, and your own PostgreSQL database, and logs the CLI back in
to the server a Trial installation replaced.

```shell
./server/scripts/uninstall.sh
```

To start over, uninstall, then run `./server/scripts/install.sh` again. With your own PostgreSQL, use a new or empty
database.

To restore a database backup that uninstalling made, such as `server/protomap-backup.20260101-120000.sql`, into a fresh
Trial installation: stop the services that use the database, load the backup, set `PROTOMAP_SECRET_KEY` in `server/.env`
to the one in the matching `server/.env.backup.20260101-120000`, start the services, and log the CLI in again with
`protomap login --server=<address>`:

```shell
docker compose --file server/compose.yaml stop proxy worker server
docker compose --file server/compose.yaml exec -T postgres \
  psql --set ON_ERROR_STOP=1 --quiet --username=protomap protomap < server/protomap-backup.20260101-120000.sql
docker compose --file server/compose.yaml up --detach --wait
```
