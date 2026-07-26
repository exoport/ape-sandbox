# syntax=docker/dockerfile:1

# ─────────────────────────────────────────────────────────────────────────────
# ape-sandbox — the official OCI image for `ape sandbox` Kata VM workspaces
# (APEX Process Platform, PLAN-16 D6 / PLAN-20 / PLAN-22). Provisioned by
# `ape sandbox up` (via `aped`) and run as a long-lived, hardware-isolated Kata
# microVM.
#
# PUBLIC and FRAMEWORK-FREE. This is the load-bearing property of the image:
# because `aped` runs on developers' machines too, "per-node credential" means
# "per-developer credential". So nothing private is baked — the APEX framework is
# mounted READ-ONLY at /opt/apex-framework at runtime from a checkout the node
# already has (`ape sandbox framework materialize <ref>`) — and any node or laptop
# can pull this image with no credential at all.
#
# It carries NO ape either (PLAN-23): `aped` mounts the `ape` installed beside it
# read-only at /opt/ape/bin, so a workspace runs the version matching the daemon that
# provisioned it. That is why this image no longer references an ape release at all.
#
# What it does carry: claude, node, git, sshd, chromium + Playwright, build tools, and
# the LANGUAGE-AGNOSTIC toolchain managers (asdf + bingo). It bakes no language runtime:
# a project declares its own versions in `.tool-versions` / `.bingo/` and
# `ape sandbox setup` materializes them into durable cache mounts, which keeps this one
# image from fanning out into a matrix of per-stack variants.
#
# VERSIONING — the image has its OWN version line, and it is now genuinely independent:
#   * This image changes for reasons ape does not: a new base, a newer asdf/bingo, a
#     Playwright bump, an extra build dep. Tying its tag to ape's would mean either
#     cutting a meaningless ape release to ship an image fix, or a tag that lies about
#     what changed.
#   * ONE pin remains, and it points this way: `sandbox.DefaultImage`
#     (apex_process_ape, internal/sandbox/kata.go) + the aped policy image allow-list
#     select which image ape provisions. Nothing here points back at ape.
#   * The in-guest ape version floor is gone with the baked binary. It used to matter —
#     `ape framework setup` needs the scoped `safe.directory` fix (v0.0.49) to read the
#     read-only, host-owned framework mount — and a baked ape could be older than that.
#     A delivered one is the node's own, so it cannot be.
#
# PINNING POLICY — read before publishing (see README.md):
#   * NEVER track a floating `:latest` base in a published image. BASE_IMAGE is
#     digest-pinned below.
#   * The base (agent-infra/sandbox) expects `seccomp=unconfined`. Acceptable
#     here: the Kata microVM *is* the security boundary, not the container's
#     seccomp profile.
#   * USER is numeric (0). aped's containerd driver resolves the image user
#     WITHOUT mounting the rootfs (PLAN-18 "barrier 3"), so a name like "root"
#     is rejected. Keep it numeric.
# ─────────────────────────────────────────────────────────────────────────────

# Base / reference: agent-infra/sandbox (Apache-2.0) — headless browser
# (VNC + CDP), VS Code Server, terminal, and MCP servers. Build FROM it so
# workspaces get the browser + editor + MCP layer for free.
#
# PINNED to a digest for reproducibility (never a floating :latest in a
# published image). This is the multi-arch (linux/amd64 + linux/arm64)
# manifest-list digest for agent-infra/sandbox 1.11.0; the :1.11.0 tag is
# kept for human readability but the @sha256 is what's resolved. To bump:
# pick a newer upstream release, re-resolve its manifest-list digest, and
# update this ARG + the README (see "Pinning policy").
ARG BASE_IMAGE=ghcr.io/agent-infra/sandbox:1.11.0@sha256:6328d7fd2f0ff0b4c147c3d05b3df1ce331f4a482eb6e550ecd64ed1fcf906e7
FROM ${BASE_IMAGE}

# Pinned versions — bump deliberately, rebuild, then re-tag the image.
ARG CLAUDE_CODE_VERSION=latest
ARG PLAYWRIGHT_BROWSER=chromium
ARG NODE_MAJOR=20
# asdf (the Go rewrite) manages per-project language/runtime versions; bingo pins
# go-installable CLI tools per repo. Both are single static binaries.
ARG ASDF_VERSION=v0.16.7
ARG BINGO_VERSION=v0.10.0
ARG GO_VERSION=1.24.5
# buildx populates TARGETARCH (amd64 / arm64) for multi-arch builds.
ARG TARGETARCH=amd64

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER root
ENV DEBIAN_FRONTEND=noninteractive

# System packages: git, ssh server, build tools, curl/ca-certs, sudo. unzip/xz are
# what most asdf plugins need to unpack a release.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git openssh-server ca-certificates curl sudo build-essential unzip xz-utils \
 && rm -rf /var/lib/apt/lists/*

# Node.js LTS — only if the base doesn't already ship a usable node.
RUN if ! command -v node >/dev/null 2>&1; then \
      curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - && \
      apt-get install -y --no-install-recommends nodejs && \
      rm -rf /var/lib/apt/lists/*; \
    fi

# Claude Code CLI.
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

# ape is NOT baked (PLAN-23). aped mounts the `ape` installed beside it read-only at
# /opt/ape/bin when it provisions a workspace, so the workspace runs the version matching
# the daemon that created it. Baking one meant every workspace ran whatever release was
# current when this image was built — structurally the PREVIOUS one, and since project work
# happens inside workspaces, an ape upgrade never reached the place the work happens.
#
# It also removes this image's dependency on an ape release entirely: nothing here has to
# wait for, or point at, a version of ape.
#
# Only the mountpoint is created. An empty dir means a workspace on a node too old to
# deliver anything fails with "ape: command not found" rather than silently running a
# stale baked copy — the mount is the only way an ape gets here.
RUN mkdir -p /opt/ape/bin

# Go toolchain — the bootstrap for bingo (and the common case for APEX projects).
# A project that pins a DIFFERENT Go version gets it from asdf into its durable
# cache; this is only the floor needed to install tools.
RUN set -euo pipefail; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" | tar -xz -C /usr/local; \
    /usr/local/go/bin/go version
ENV PATH="/usr/local/go/bin:${PATH}"

# asdf (Go rewrite) — one static binary, no shim-init required.
RUN set -euo pipefail; \
    v="${ASDF_VERSION#v}"; \
    curl -fsSL "https://github.com/asdf-vm/asdf/releases/download/${ASDF_VERSION}/asdf-${ASDF_VERSION}-linux-${TARGETARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin asdf; \
    chmod 0755 /usr/local/bin/asdf; \
    asdf --version | grep -q "$v"

# bingo — installs a repo's version-pinned Go tools into $GOBIN.
RUN set -euo pipefail; \
    GOBIN=/usr/local/bin /usr/local/go/bin/go install "github.com/bwplotka/bingo@${BINGO_VERSION}"; \
    bingo version

# The framework is a RUNTIME mount, not a layer. Create the mountpoint and point
# `ape framework` at it, so `ape framework setup --no-fetch` needs no flags inside
# a workspace. An empty dir here means a workspace whose node serves no framework
# fails with a clear "not materialized" error rather than a mystery path.
RUN mkdir -p /opt/apex-framework
ENV APEX_FRAMEWORK_REPO=/opt/apex-framework

# /opt/ape/bin leads PATH so the delivered ape wins over anything else of that name. A
# project's bingo-pinned ape is unaffected: bingo installs VERSION-STAMPED names and its
# generated Variables.mk calls them by absolute path, so a pin never resolves through PATH.
# (Do not `bingo get -l ape` in a workspace — the unstamped link lands in $GOBIN, which is
# a node-wide shared cache, so two projects pinning different versions would contend for
# one name. The stamped names are what make that cache safe to share.)
ENV PATH="/opt/ape/bin:${PATH}"

# Container ENV above reaches `ape sandbox exec` and `attach`, which inherit the container
# process environment — and does NOT reach an ssh / VS Code Remote session, because sshd
# builds a fresh environment per session instead of passing its own along. So a login shell
# gets the same values from a profile drop-in (PLAN-23 D9): PATH here, and the rest from the
# per-workspace file aped writes into the composed home. Without the second half, `go` and
# `asdf` in an ssh session use the ephemeral rootfs instead of the durable /cache mounts.
RUN printf '%s\n' \
  '# ape-sandbox: login-shell environment (ssh / VS Code Remote).' \
  '# sshd does not pass the container environment into a session, so re-establish it here.' \
  'case ":$PATH:" in' \
  '  *:/opt/ape/bin:*) ;;' \
  '  *) PATH="/opt/ape/bin:$PATH"; export PATH ;;' \
  'esac' \
  '# Per-workspace values aped derives from the mounts it actually applied (tool caches,' \
  '# egress proxy). Absent when the workspace declared no toolchain — not an error.' \
  'if [ -r "$HOME/.ape-env" ]; then . "$HOME/.ape-env"; fi' \
  > /etc/profile.d/ape-sandbox.sh \
  && chmod 0644 /etc/profile.d/ape-sandbox.sh

# Chromium + Playwright (Excalidraw rendering / browser workloads run inside
# the VM, where a real guest kernel avoids gVisor's syscall-compat gaps).
RUN npx -y playwright@latest install --with-deps "${PLAYWRIGHT_BROWSER}"

# Workspace user. The Kata VM is the boundary, so in-guest privilege is not
# the security control; day-to-day work runs as an unprivileged `ape` user
# with passwordless sudo for in-guest setup convenience. Its home is
# /sandbox/home — the same path the composed ~/.claude is bind-mounted at —
# so HOME is consistent across `ssh` and `exec`, and sshd's default
# AuthorizedKeysFile (~/.ssh/authorized_keys) resolves to the composed
# /sandbox/home/.ssh/authorized_keys.
RUN useradd --home-dir /sandbox/home --shell /bin/bash ape \
 && echo 'ape ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ape \
 && chmod 0440 /etc/sudoers.d/ape

# sshd: key auth only, no root login, no passwords. Access is over the
# host-loopback port ape forwards; the overlay is a later phase. The composer
# writes the workspace's authorized_keys into the bind-mounted /sandbox/home/.ssh.
# StrictModes is off: the home is a virtio-fs bind whose in-guest uid/ownership
# need not match `ape`, which StrictModes would otherwise reject — acceptable
# because the Kata VM, not file ownership, is the boundary.
RUN mkdir -p /run/sshd \
 && sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
 && sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin no/'               /etc/ssh/sshd_config \
 && sed -ri 's/^#?PubkeyAuthentication.*/PubkeyAuthentication yes/'     /etc/ssh/sshd_config \
 && sed -ri 's/^#?StrictModes.*/StrictModes no/'                        /etc/ssh/sshd_config

# Mountpoints aped binds at runtime:
#   /sandbox/home       the composed ~/.claude (guest $HOME)
#   /workspace          the ROOT for project repos, each at /workspace/<name>
#   /cache              durable tool caches (asdf/go/cargo/...), one per subdir
#   /opt/ape/bin        the `ape` binary, read-only, from the node's own install
#   /opt/apex-framework the pinned framework checkout, read-only
RUN mkdir -p /sandbox/home /workspace /cache && chown ape:ape /sandbox/home

COPY entrypoint.sh /usr/local/bin/ape-sandbox-entrypoint
RUN chmod 0755 /usr/local/bin/ape-sandbox-entrypoint

# USER must be NUMERIC (see the header): 0 = root.
USER 0

LABEL org.opencontainers.image.title="ape-sandbox" \
      org.opencontainers.image.description="APEX Process ape sandbox Kata VM workspace image (public, framework-free; the framework is mounted read-only at runtime)" \
      org.opencontainers.image.source="https://github.com/exoport/ape-sandbox" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="exoport"

EXPOSE 22
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/ape-sandbox-entrypoint"]
# Default command keeps the workspace long-lived so `exec`/`attach` work across
# many sessions. `ape sandbox up` provisions detached (-d).
CMD ["sleep", "infinity"]
