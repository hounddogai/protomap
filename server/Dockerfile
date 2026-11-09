# syntax=docker/dockerfile:1
# The release image, hounddogai/protomap on Docker Hub, which self-hosted installations run. It holds the server, which
# answers the API and serves the platform UI, and the worker, which runs background jobs and serves the job queue
# dashboard. It runs the server's binary, whose first argument selects its role ("server", the default, "migrate",
# "health", or the cloud's "admin"); the worker's binary is /usr/local/bin/protomap-worker, which a container runs in
# place of the entrypoint. Environment variables configure both. The final stage is distroless: it holds the binaries
# and the C runtime they link, with no shell or package manager, and runs as an unprivileged user.
# Users install the CLI from the GitHub release of the same version, which the platform's setup steps name.
# .github/workflows/deploy-image.yml builds it from the repository root:
#   docker build -f public/server/Dockerfile --build-arg PROTOMAP_VERSION=<version> \
#     -t hounddogai/protomap:<version> .
# Releases build without caches, so nothing a build of another branch cached can end up in them. Development builds
# use docker/dev/Dockerfile.

FROM node:26-trixie-slim AS ui
WORKDIR /build
COPY crates/server/ui/package.json crates/server/ui/pnpm-lock.yaml crates/server/ui/pnpm-workspace.yaml ./
# Node ships without Corepack since version 25, so npm installs the pnpm that package.json names.
RUN npm install --global "$(node --print 'require("./package.json").packageManager')"
COPY crates/server/ui/patches ./patches
RUN pnpm install --frozen-lockfile
COPY crates/server/ui/index.html crates/server/ui/api-docs.html crates/server/ui/admin.html \
    crates/server/ui/tsconfig.json crates/server/ui/tsconfig.app.json crates/server/ui/tsconfig.node.json \
    crates/server/ui/vite.config.ts ./
COPY crates/server/ui/public ./public
COPY crates/server/ui/src ./src
RUN pnpm run build

FROM rust:1-trixie AS server
ARG PROTOMAP_VERSION
RUN test -n "${PROTOMAP_VERSION}" || { echo "Set --build-arg PROTOMAP_VERSION=<version>." >&2; exit 1; }
WORKDIR /build
# The toolchain file names the Rust channel; rustup installs it here.
COPY rust-toolchain.toml ./
RUN rustup toolchain install
COPY Cargo.toml Cargo.lock ./
COPY crates crates
# Release builds embed the platform UI in the server's binary.
COPY --from=ui /build/dist crates/server/ui/dist
RUN cargo build --release --locked --package protomap-server --package protomap-worker \
    && cp target/release/protomap-server target/release/protomap-worker /usr/local/bin/

FROM gcr.io/distroless/cc-debian13:nonroot
ARG PROTOMAP_VERSION
LABEL org.opencontainers.image.title="ProtoMap" \
      org.opencontainers.image.vendor="HoundDog.ai" \
      org.opencontainers.image.url="https://protomap.ai" \
      org.opencontainers.image.version="${PROTOMAP_VERSION}"
COPY --from=server /usr/local/bin/protomap-server /usr/local/bin/protomap-worker /usr/local/bin/
EXPOSE 8800 8801
# Health checks are defined per service in compose.yaml, because the image runs in different roles.
ENTRYPOINT ["/usr/local/bin/protomap-server"]
CMD ["server"]
