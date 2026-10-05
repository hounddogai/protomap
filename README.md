# ProtoMap

ProtoMap by HoundDog.ai maps how your gRPC services call each other and how protobuf fields flow between them and into
data sinks. The ProtoMap CLI scans repositories on your computer and uploads the scans to a ProtoMap server, whose
platform shows the graph and answers questions about it, and it lets coding agents such as Claude Code read the graph.

## Install the CLI

On macOS and Linux:

```shell
curl -fsSL https://raw.githubusercontent.com/hounddogai/protomap/main/install.sh | sh
```

On Windows, in PowerShell:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/hounddogai/protomap/main/install.ps1)))
```

The scripts install the latest release for your computer, on x86_64 or aarch64, after checking it against the
release's `SHA256SUMS`. The CLI goes to `~/.local/bin` on macOS and Linux, or to `PROTOMAP_INSTALL_DIR`. To install
a given release, such as the one your server runs, pass its version: `sh -s -- 0.1.0` after `sh`, or `0.1.0` after the
PowerShell command. The platform's setup steps show the command with your server's version. The binaries are also on
the [releases page](https://github.com/hounddogai/protomap/releases).

## Use the CLI

Log in to your ProtoMap server, which opens the platform in your browser to approve the login, then scan repositories.
Every scan is uploaded as you:

```shell
protomap login --server=https://protomap.example.com
protomap scan /path/to/repository
```

To let a coding agent read the graph, add the CLI to it as an MCP server in each repository's folder. While the agent
runs, the CLI scans the repository as files are saved, so the agent sees your changes laid over the shared graph:

```shell
claude mcp add protomap -- protomap mcp serve
```

Continuous integration scans with an organization API key, which admins create in the platform's settings, instead of
a login: set `PROTOMAP_URL` and `PROTOMAP_API_KEY`, then run `protomap scan`.

## Run your own server

[`self-hosted/`](self-hosted/README.md) runs the ProtoMap server in your own environment with Docker Compose:

```shell
git clone https://github.com/hounddogai/protomap
cd protomap/self-hosted
./install.sh
```
