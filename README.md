# ape-sandbox

The official OCI image for [`ape sandbox`](https://github.com/exoport/apex_process_ape)
Kata microVM workspaces: a long-lived, hardware-isolated development workspace
(own guest kernel, KVM) that `aped` provisions per project.

**Public and framework-free.** Because `aped` runs on developers' machines and not
just central nodes, a private image would mean a registry credential per
*developer*. So this image bakes nothing private: the APEX framework is mounted
**read-only at runtime** from a checkout the node already has. Any node or laptop
pulls it anonymously.

```bash
ape sandbox up dev            # aped pulls ghcr.io/exoport/ape-sandbox:<tag>
```

## What's in it

| Layer | Contents |
| --- | --- |
| Base | [`agent-infra/sandbox`](https://github.com/agent-infra/sandbox) (Apache-2.0) — headless browser (VNC + CDP), VS Code Server, terminal, MCP servers |
| Agent | `claude` (Claude Code CLI), `ape` (pinned public release) |
| Dev | `git`, `build-essential`, `sshd`, chromium + Playwright |
| Toolchain managers | `asdf` (language/runtime versions) + `bingo` (repo-pinned Go tools), plus a bootstrap Go |

**No language runtimes are baked** beyond the Go bootstrap. A project declares its
own versions and materializes them into durable cache mounts:

```yaml
# .apesandbox.yaml in your project
version: 1
toolchain:
  tool_versions: .tool-versions   # asdf
  bingo: true                     # the repo's pinned Go tools
  caches: [asdf, go]              # durable host-backed caches
```

```bash
ape sandbox setup dev             # asdf install + bingo get, inside the workspace
```

That keeps one image instead of a matrix of per-stack variants. A team that wants a
heavy stack pre-baked (Flutter, CUDA) can build a variant and select it with the
profile's `image:` override.

## Runtime mountpoints

`aped` binds these; the image only creates the mountpoints.

| Path | What lands there |
| --- | --- |
| `/sandbox/home` | the composed `~/.claude` — the guest `$HOME` |
| `/workspace/<name>` | one directory per project repo; the main repo is the working directory |
| `/opt/apex-framework` | the pinned APEX framework, **read-only** (`$APEX_FRAMEWORK_REPO` points here) |
| `/cache/<tool>` | durable tool caches (`asdf`, `go`, `cargo`, …) so a rebuild is offline |

Inside a workspace, install the framework's skills + pipelines from the mount
without touching the network:

```bash
ape framework setup --no-fetch
```

## Build

```bash
make build                                  # local build
make build NERDCTL="sudo nerdctl" NAMESPACE=aped   # straight into a local aped
make smoke                                  # verify ape/claude/asdf/bingo are present
make publish                                # build + push to ghcr.io/exoport
```

CI publishes on a `vX.Y.Z` tag push and build-checks every PR that touches the
Dockerfile. No build secret is needed.

> **Package visibility:** the first push creates the GHCR package **private**. Set
> it to public on the package page — otherwise every consumer needs a pull
> credential again, which is the whole thing this image exists to avoid.

## Pinning policy

- The image tracks **ape releases**: tag it to match, then update
  `sandbox.DefaultImage` (`internal/sandbox/kata.go`) and the `aped` policy image
  allow-list in the `apex_process_ape` repo.
- The base image is **digest-pinned** in the `Dockerfile`. Never publish an image
  built on a floating `:latest` base.
- `USER` is **numeric** (`0`). `aped`'s containerd driver resolves the image user
  without mounting the rootfs, so a named user (`root`) is rejected outright.
- The base expects `seccomp=unconfined`. That is acceptable here: the Kata microVM
  is the security boundary, not the container's seccomp profile.

## License

Apache-2.0 (the base image's license). The image contains no private APEX
material.
