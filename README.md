# ProtoMap Self-Hosted

Run the ProtoMap server in your own environment. It stores scans of your repositories, links them into one graph,
answers queries about it, and runs your members' chats with the assistant. Its platform UI shows the graph and the
chats, and its settings manage members, API keys, AI providers, and AI usage. Members scan repositories with the
ProtoMap CLI on their computers, which signs in to the server and uploads the scans.

## Requirements

- Docker with Compose 2.23.1 or newer.
- At least 4 GB of RAM and 20 GB of disk space.
- PostgreSQL 18 or newer, bundled for trials or your own for production.

## Installation

```shell
git clone https://github.com/hounddogai/protomap
cd protomap
./install.sh
```

The installer asks for the installation type and the port, generates `.env` with a setup key and other secrets, pulls
the image `hounddogai/protomap` from Docker Hub, and starts the services. Open the printed address and create the
owner's account with the setup key. The owner is the first admin.

1. **Trial** runs PostgreSQL in Docker Compose.
2. **Production** connects to your PostgreSQL. The first start needs permission to create tables.

The configuration lives in `.env` next to `compose.yaml`, which Docker Compose reads on its own. To keep it elsewhere,
run `./install.sh --env-file /path/to/env`, and add the same `--env-file /path/to/env` to every later `docker compose`
command.

## Services

The stack is the Docker Compose project `protomap`:

| Service    | Role                                                                                     |
| ---------- | ---------------------------------------------------------------------------------------- |
| `server`   | Runs `protomap-server`: the API and the platform UI.                                     |
| `worker`   | Runs `protomap-worker`: background jobs and the job queue dashboard.                     |
| `proxy`    | Runs Caddy, which publishes the port and spreads requests across the server's replicas. |
| `postgres` | The bundled database of trial installations.                                             |

The services run the latest release unless `PROTOMAP_VERSION` names another, such as `1.2.3`. One server and one
worker run by default. Both scale out, since they keep their state in PostgreSQL and each job runs once:

```shell
docker compose up --detach --wait --scale server=3 --scale worker=2
```

When `PROTOMAP_ADMIN_PASSWORD` is set, the workers serve the job queue dashboard at `http://127.0.0.1:8801`, with the
user `admin`; set `PROTOMAP_DASHBOARD_PORT` to publish it on another port. The dashboard and the bundled PostgreSQL
listen only on 127.0.0.1 of the Docker host, the computer that runs the stack, so no other computer reaches them. To
open the dashboard from your own computer, forward its port over SSH, then open `http://127.0.0.1:8801` there:

```shell
ssh -L 8801:127.0.0.1:8801 <Docker host>
```

The bundled PostgreSQL is published on a port Docker picks; find it with `docker compose port postgres 5432`, or set
`PROTOMAP_POSTGRES_PORT`.

The stack serves plain HTTP. API keys, passwords, and session cookies travel in requests, so put a proxy that ends TLS
in front of it for anything but a local trial, and set `PROTOMAP_BIND_ADDRESS=127.0.0.1` so only that proxy can reach
it. When that proxy sends `X-Forwarded-Proto: https`, session cookies are marked `Secure`. The server sets the
security headers of its pages itself.

## Accounts

Everyone signs in to a built-in account with an email and a password, and belongs to the server's one organization as
an admin or a member. Admins manage members, API keys, AI providers, and repository removal; members scan, query, and
chat.

- **Owner.** While the server has no members, `PROTOMAP_SETUP_KEY` creates the first admin's account.
- **Invitations.** An admin creates an invitation link for an email and a role, and gives it to the person, who opens
  it to create the account and join. Someone who has an account joins with its password.
- **Password resets.** An admin creates a reset link for a member, who opens it to set a new password. The member's
  browsers are signed out.
- **Removal.** A removed member keeps the account but is signed out, can no longer sign in, and loses their personal
  API keys and private scans.

Links work once, expire after 7 days, and stop working when the admin who created them is no longer an admin.
Browser sessions last 30 days. The server sends no email; admins give links to people themselves.

## API

A request authenticates with `Authorization: Bearer <API key>` or with the platform's session cookie. API keys come in
two kinds:

- **Organization keys**, which admins create in the platform's settings for continuous integration. They scan and
  query, act without a user, and so have no chats.
- **Personal keys**, which act as the member who created them, with the member's role. Signing the CLI in creates one
  for the member's computer.

`PROTOMAP_SECRET_KEY` encrypts the AI provider API keys the server stores; back it up with the database. The server
accepts only API keys an admin pastes, never credentials of the machine it runs on. `ARCHITECTURE.md` in the source
lists every route.

| Method and path                            | Purpose                                                       |
| ------------------------------------------ | ------------------------------------------------------------- |
| `POST /api/v1/artifacts`                   | Uploads an artifact and answers whether it entered the graph. |
| `GET /api/v1/repositories`                 | Lists repositories with their latest scans.                   |
| `DELETE /api/v1/repositories?identity=...` | Removes a repository from the graph.                          |
| `GET /api/v1/services`                     | Lists services with their implementers and dependents.        |
| `GET /api/v1/methods?service=...`          | Lists methods with their handlers and call sites.             |
| `GET /api/v1/flows`                        | Lists dataflows, filtered by `rpc`, `sink`, `uncertain`.      |
| `GET /api/v1/flows/{fingerprint}`          | Shows a dataflow's trace and its continuations.               |
| `PUT /api/v1/providers/{p}/connection`     | Connects an AI provider with a pasted API key.                |
| `GET /api/v1/members`                      | Lists members with their roles.                               |
| `POST /api/v1/links`                       | Creates an invitation or password reset link.                 |
| `POST /api/v1/api-keys`                    | Creates an organization key, or a personal key.               |
| `GET /api/v1/usage`                        | Totals the AI tokens of each member and model.                |

## The CLI

Members install the ProtoMap CLI from the server. The platform shows the command, which downloads the CLI for the
member's computer to `~/.local/bin` (or `PROTOMAP_INSTALL_DIR`):

```shell
curl -fsSL http://localhost:3300/install.sh | sh -s -- http://localhost:3300
```

On Windows, in PowerShell:

```powershell
& ([scriptblock]::Create((irm http://localhost:3300/install.ps1))) http://localhost:3300
```

The image offers the CLI of its own release for Linux, macOS, and Windows on x86_64 and aarch64; the Linux builds need
glibc 2.28 or newer. They live in the folder that `PROTOMAP_DOWNLOADS_DIR` names, as `protomap-<os>-<arch>`, with
`.exe` on Windows, and the platform offers every build the folder holds. Downloads, their list at
`GET /api/v1/downloads`, and the install scripts answer without a sign-in, since the CLI signs in only once it runs.
Members can also build the CLI from source with `cargo build --release --package protomap-cli`.

Members sign the CLI in to the server and scan their repositories; every scan is uploaded as the member:

```shell
protomap login --server=http://localhost:3300
protomap scan /path/to/repository
```

To let a coding agent, such as Claude Code, read the graph, members add the CLI to it as an MCP server in each
repository's folder; only repositories they add it to are scanned. While the agent runs, `protomap mcp serve` scans
that repository as files are saved and uploads each scan as the member's overlay of that checkout, so the agent and the
platform see the member's changes laid over the shared graph. Before each tool call it waits, up to 30 seconds, until
the server has the changes saved before the call. Other coding agents run `protomap mcp serve` over standard input and
output. The key `protomap login` stores only uploads scans and reads the graph, so an agent can never change the
organization's settings.

```shell
claude mcp add protomap -- protomap mcp serve
```

Continuous integration uses an organization key instead: `export PROTOMAP_URL=http://localhost:3300
PROTOMAP_API_KEY=<the key>`. `protomap mcp serve` needs a member's personal key, which `protomap login` stores.

The server accepts an artifact into the shared graph only when it is a clean scan of a pushed commit on the primary
branch. Otherwise the answer says why, and the server keeps a member's scan as that member's private artifact, which
only that member's queries and chats show over the shared graph; an organization key's scan is not stored. Graph
queries on the server read the current graph version with the requesting member's latest scans laid over it. A scan
fails when the server cannot be reached.

## Upgrade and removal

Run `git pull` for the latest Compose project, then `docker compose pull` and `docker compose up --detach --wait`,
after setting `PROTOMAP_VERSION` to the new release if you pinned one. The server applies database migrations when it
starts. To remove ProtoMap and its data, run `docker compose down --volumes`; this does not touch your own PostgreSQL.
