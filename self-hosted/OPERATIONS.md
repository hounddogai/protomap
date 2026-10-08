# Operating ProtoMap Self-Hosted

What [`README.md`](README.md) leaves out: the services, accounts, API keys, the CLI, and upgrades.

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

## API keys

A request authenticates with `Authorization: Bearer <API key>` or with the platform's session cookie. API keys come in
two kinds:

- **Organization keys**, which admins create in the platform's settings for continuous integration. They scan and
  query, act without a user, and so have no chats.
- **Personal keys**, which act as the member who created them, with the member's role. Signing the CLI in creates one
  for the member's computer.

`PROTOMAP_SECRET_KEY` encrypts the AI provider API keys the server stores; back it up with the database. The server
accepts only API keys an admin pastes, never credentials of the machine it runs on.

## The CLI

Members install the ProtoMap CLI from its GitHub releases, for Linux, macOS, and Windows on x86_64 and aarch64; the
Linux builds need glibc 2.28 or newer. The platform's setup steps show the command, which installs the release of the
server's own version, such as 0.2.0, to `~/.local/bin` (or `PROTOMAP_INSTALL_DIR`) after checking it against the
release's `SHA256SUMS`:

```shell
curl -fsSL https://install.protomap.ai | sh -s -- 0.2.0
```

On Windows, in PowerShell:

```powershell
& ([scriptblock]::Create((irm https://install.protomap.ai/install.ps1))) 0.2.0
```

Members can also download the binaries from the [releases page](https://github.com/hounddogai/protomap/releases), or
build the CLI from source with `cargo build --release --package protomap-cli`.

Members sign the CLI in to the server and scan their repositories; every scan is uploaded as the member:

```shell
protomap login --server=http://localhost:3300
protomap scan /path/to/repository
```

`protomap login` opens the platform in the browser, which approves a key for the CLI and hands it to the CLI over this
computer's loopback address. A CLI that no browser can reach, such as one on a VM over SSH or in a container, prints a
code instead: the member opens `/#/cli` on the server in a browser on any computer, enters the code, and approves it,
and the CLI then fetches its key from the server. A code works once, for ten minutes.

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

Instead of logging in, the CLI takes the server and an API key from `PROTOMAP_URL` and `PROTOMAP_API_KEY`, such as in
containers and continuous integration: `export PROTOMAP_URL=http://localhost:3300 PROTOMAP_API_KEY=<the key>`.
`protomap mcp serve` needs a member's personal key, which `protomap login` stores, or which a member creates in
**Settings > API Keys**; an organization key acts as no member.

The server accepts an artifact into the shared graph only when it is a clean scan of a pushed commit on the primary
branch. Otherwise the answer says why, and the server keeps a member's scan as that member's private artifact, which
only that member's queries and chats show over the shared graph; an organization key's scan is not stored. Graph
queries on the server read the current graph version with the requesting member's latest scans laid over it. A scan
fails when the server cannot be reached.

## Upgrade and removal

Run `git pull` for the latest Compose project, then `docker compose pull` and `docker compose up --detach --wait`,
after setting `PROTOMAP_VERSION` to the new release if you pinned one. The server applies database migrations when it
starts. To remove ProtoMap and its data, run `docker compose down --volumes`; this does not touch your own PostgreSQL.
