# ProtoMap Server

Run ProtoMap Server in your own environment. The scripts in `server/scripts` run from any folder. Each installation
keeps its `compose.yaml`, its settings, and its backups in `~/.protomap/server/<name>` (`~/.protomap/server/protomap`
by default), so the scripts in any clone can find it. Run them as the user who installed it.

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
`127.0.0.1` by default). Each installation on a computer needs its own Docker Compose project name, `protomap` by
default, so give a second installation a different one with `--name`, such as `--name=protomap-2`. The upgrade and
uninstall scripts then take the same `--name`.

When the installation finishes:

1. Open the ProtoMap URL the installer prints, such as `http://localhost:3300`, or this computer's address from another
   computer.
2. Enter the one-time setup key, which the installer prints when it runs in a terminal, and keeps as
   `PROTOMAP_SETUP_KEY` in `~/.protomap/server/protomap/.env`.
3. Create your organization and owner account.

The installer also installs the latest ProtoMap CLI, which updates itself. In Trial mode, it logs the CLI in as the
owner, so you can scan a repository right away:

```shell
protomap scan /path/to/repository
```

When the CLI is already logged in to another server, such as ProtoMap's cloud, the installer asks before it replaces
that login, and backs it up so uninstalling can restore it. When the installer cannot ask, such as in a script, it
leaves the CLI's login alone unless you pass `--replace-login`; log in to this server later with
`protomap login --server=<address>`. Each scan prints its **Destination** before it starts.

To install the CLI on other computers and connect coding agents, see the [main README](../README.md).

## Configuration

The installer writes your settings to `~/.protomap/server/protomap/.env`, and [`server/.env.example`](.env.example)
explains every setting. After you change them, apply them with
`docker compose --file ~/.protomap/server/protomap/compose.yaml up -d`. Each upgrade replaces that `compose.yaml` with
the clone's, so make changes in `.env`.

Back up `.env` along with your database. Its `PROTOMAP_SECRET_KEY` encrypts the secrets that ProtoMap Server
stores: AI provider API keys, the SMTP password, and single sign-on client secrets. If the key changes, ProtoMap Server
keeps running but can no longer read them, so Settings asks for each one again, and single sign-on logins under way
fail.

By default, ProtoMap Server is reachable from other machines on your network over plain HTTP. For anything but a trial,
put a proxy that serves HTTPS in front of it, and set `PROTOMAP_BIND_ADDRESS=127.0.0.1` so that only the proxy can reach
it. ProtoMap Server leaves `Strict-Transport-Security` to that proxy, so have it send the header once the server is
reached only over HTTPS. To count failed logins and other limits per client, also set `PROTOMAP_CLIENT_ADDRESS_HEADER`
to the header in which the proxy passes on each client's address (see [`server/.env.example`](.env.example)).

## Upgrade

Back up your database first, because ProtoMap Server is briefly unavailable while the upgrade runs. Upgrading keeps your
configuration and data:

```shell
git pull && ./server/scripts/upgrade.sh
```

ProtoMap Server runs the latest release unless `PROTOMAP_VERSION` in its `.env` names another, such as `1.2.3`. If
the upgrade fails, the previous version starts again: fix the reported error and run the upgrade again. The upgrade also
installs the latest CLI.

After an upgrade to another release, scan again each repository that the platform marks "Needs a New Scan". Your
organization sees the new scans once every marked repository is scanned again or removed. On other computers, a CLI
that updates itself does so when the server asks it to. To update one now, run `protomap update`.

The upgrade refuses a release older than the one running. To go back to one, restore the database backup made before
upgrading from it, set `PROTOMAP_VERSION` in `.env` to that release, then run
`docker compose --file ~/.protomap/server/protomap/compose.yaml down` and `./server/scripts/upgrade.sh`.

## Uninstall

Uninstall removes ProtoMap Server and its data. It offers to back up `.env`, the CLI's login, and the bundled database
first, into the installation's folder. It keeps the CLI, those backups, the clone, and your own PostgreSQL database.
If a Trial installation replaced the CLI's login, uninstalling restores it.

```shell
./server/scripts/uninstall.sh
```

To start over, uninstall, then run `./server/scripts/install.sh` again. With your own PostgreSQL, use a new or empty
database.

To restore a database backup that uninstalling made, such as
`~/.protomap/server/protomap/protomap-backup.20260101-120000.sql`, into a fresh Trial installation of the same name:
stop the services that use the database, load the backup, set `PROTOMAP_SECRET_KEY` in `.env` to the one in the
matching `.env.backup.20260101-120000`, start the services, and log the CLI in again with
`protomap login --server=<address>`:

```shell
cd ~/.protomap/server/protomap
docker compose stop proxy worker server
docker compose exec -T postgres \
  psql --set ON_ERROR_STOP=1 --quiet --username=protomap protomap < protomap-backup.20260101-120000.sql
docker compose up --detach --wait
```
