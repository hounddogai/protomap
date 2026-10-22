# ProtoMap

ProtoMap by HoundDog.ai maps your gRPC services: which services call which, through which methods and protobuf fields,
down to every call site. Run it on your own infrastructure, explore your architecture in its platform, ask its assistant
what a change would break, and give the same graph to coding agents such as Claude Code.

![The services of a scanned repository, and how they call each other](self-hosted/images/service-sphere.png)

## What you can do

- **See your architecture.** Every gRPC service defined across your repositories, in monorepos or across
  microservices, and how they connect, by repository, service, method, message, and field.
- **Assess the blast radius of a change.** Before you change a service, method, or field, see the services, consumers,
  and call sites it affects.
- **Find every call site of an RPC.** Which services call a method, in which file and function, and the call itself.
- **Trace how a field flows.** Follow a protobuf field through the code step by step, with the code at each step, from
  one service into the next.
- **Ask the assistant.** It answers from your scans, with file locations, and draws diagrams, using the AI provider you
  connect.
- **Give coding agents the graph.** Over MCP, with your uncommitted changes laid over the shared graph.

ProtoMap reads `.proto` files and the gRPC code that serves and calls them in Go, C#, Java, Kotlin, Python, Rust, Swift,
and TypeScript.

![CheckoutService and the services it depends on](self-hosted/images/service-detail.png)

![Every call site of ProductCatalogService/GetProduct](self-hosted/images/call-sites.png)

## Install ProtoMap Server

You need Docker with Compose 2.23.1 or newer, and at least 4 GB of RAM and 20 GB of disk space.

```shell
git clone https://github.com/hounddogai/protomap
cd protomap
./self-hosted/scripts/install.sh
```

Open the address the installer prints, enter the setup key it shows, and create your organization and its owner. Setup
then lets you connect an AI provider for the assistant, such as Anthropic or OpenAI, with your own API key, and shows
how to install the CLI. The installer also installs the CLI on the computer it runs on. See
[`self-hosted/`](self-hosted/README.md) for more.

## Scan your repositories with the CLI

The ProtoMap CLI scans repositories on your computer and uploads the scans to your server. Install it on macOS or Linux:

```shell
curl -fsSL https://protomap.ai/install.sh | sh
```

On Windows, in PowerShell:

```powershell
irm https://protomap.ai/install.ps1 | iex
```

The scripts install the latest release from the [releases page](https://github.com/hounddogai/protomap/releases), after
checking it against the release's `SHA256SUMS`. The CLI goes to `~/.local/bin` on macOS and Linux, and to
`%LOCALAPPDATA%\protomap\bin` on Windows, or to the folder `PROTOMAP_INSTALL_DIR` names. On Windows, the script adds the
folder to your `PATH`; on macOS and Linux, it says how when the folder is not on it.

Log in to your server, then scan a repository:

```shell
protomap login --server=http://<your server>:3300
protomap scan /path/to/repository
```

`protomap login` opens the platform in your browser to approve the login. On a computer without a browser, such as a
VM over SSH, or with `--no-open`, it prints a code instead: open `http://<your server>:3300/#/cli` in a browser on any
computer and enter it. `protomap logout` forgets the server and revokes this computer's key on it.

Scans of a pushed commit on a repository's primary branch, with no uncommitted changes, join the graph everyone in the
organization sees. Your other scans, such as of uncommitted changes or other branches, only show to you.

## Connect a coding agent

Add the CLI to your coding agent as an MCP server, from a repository's folder. While the agent runs, the CLI scans the
repository as files are saved, so the agent sees your changes laid over the graph:

```shell
claude mcp add protomap -- protomap mcp serve
```

**Scan a Repository** in the platform's sidebar gives the command for Codex, Gemini CLI, Copilot CLI, VS Code,
OpenCode, Amp, Droid, and Qwen Code, and the JSON for other agents, which run `protomap mcp serve` over standard input
and output. The agent reads the graph as you, so log in first, or use a personal API key.

## Containers, CI, and other automation

Instead of logging in, set `PROTOMAP_URL` to your server and `PROTOMAP_API_KEY` to an API key from the platform's
**Settings > API Keys**:

```shell
export PROTOMAP_URL=http://<your server>:3300 PROTOMAP_API_KEY=<key>
protomap scan /path/to/repository
```

A personal key acts as you, and also serves `protomap mcp serve` to an agent. An organization key, which admins create
for continuous integration, scans without a user, so only scans that can join the shared graph count, and it cannot
serve an agent.
