# ProtoMap Self-Hosted

Run ProtoMap on your own infrastructure with Docker Compose. Its platform shows your gRPC services and how they connect,
and its assistant answers questions about them from your scans.

![The services of a scanned repository, and how they call each other](images/services.png)

## Installation

You need Docker with Compose 2.23.1 or newer, and at least 4 GB of RAM and 20 GB of disk space.

```shell
git clone https://github.com/hounddogai/protomap
cd protomap/self-hosted
./install.sh
```

The installer asks whether to run PostgreSQL in Docker, for a trial, or to use your own PostgreSQL 18 or newer, and
which port to serve on, 3300 by default. It writes the configuration with its secrets to `.env`, pulls the image, and
starts the services.

Then open `http://<this computer>:3300`, enter the setup key the installer printed, and create your organization and its
owner. For anything but a local trial, put a proxy that ends TLS in front of the server.

## AI integration

- **The assistant.** The setup connects an AI provider with your own API key, such as Anthropic, OpenAI, Google, Amazon
  Bedrock, or Azure. Admins can connect more in **Settings > AI Agents**. Your code stays on your server;
  the assistant sends the provider your questions and the graph data it reads to answer them.
- **Coding agents.** Members install the ProtoMap CLI, log in, and add it to their agent as an MCP server, so the agent
  reads the graph with their uncommitted changes laid over it. The setup's last step, and the **+** beside
  **Repositories** in the sidebar, show the commands:

```shell
curl -fsSL https://install.protomap.ai | sh
protomap login --server=http://<this computer>:3300
claude mcp add protomap -- protomap mcp serve
```

On a computer without a browser, such as a VM over SSH, `protomap login` prints a code to enter at
`http://<this computer>:3300/#/cli` in a browser on any computer. Containers and CI set `PROTOMAP_URL` and
`PROTOMAP_API_KEY` to an API key from **Settings > API Keys** instead.

![Every call site of ProductCatalogService/GetProduct](images/call-sites.png)

## More

[`OPERATIONS.md`](OPERATIONS.md) covers the services and scaling, accounts, API keys, the CLI in depth, and upgrades.
