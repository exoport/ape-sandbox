# ape-sandbox

The official OCI image for [`ape sandbox`](https://github.com/exoport/apex_process_ape)
Kata microVM workspaces: a long-lived, hardware-isolated development workspace
(own guest kernel, KVM) that `aped` provisions per project.

**Public and framework-free.** Because `aped` runs on developers' machines and not
just central nodes, a private image would mean a registry credential per
*developer*. So this image bakes nothing private: the APEX framework is mounted
**read-only at runtime** from a checkout the node already has. Any node or laptop
pulls it anonymously.

**`ape` is delivered at runtime too, not baked.** `aped` mounts the `ape` installed
beside it read-only at `/opt/ape/bin` (first on `PATH`), so a workspace runs the version
matching the daemon that provisioned it. A baked `ape` was always the release that was
current when the image was built — structurally the previous one — and since project work
happens *inside* workspaces, an `ape` upgrade never reached the place the work happens.
It also means this image has **no dependency on an `ape` release at all**.

```bash
ape sandbox up dev            # aped pulls ghcr.io/exoport/ape-sandbox:<tag>
```

## What's in it

| Layer | Contents |
| --- | --- |
| Base | [`agent-infra/sandbox`](https://github.com/agent-infra/sandbox) (Apache-2.0) — headless browser (VNC + CDP), VS Code Server, terminal, MCP servers |
| Agent | `claude` (Claude Code CLI). **`ape` is not baked** — `aped` mounts it at runtime, see below |
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
| `/opt/ape/bin` | the `ape` binary, read-only, from the node's own install — first on `PATH` |

### Login shells (ssh / VS Code Remote)

`sshd` builds a **fresh** environment per session instead of passing the container
environment along, so anything set only via Dockerfile `ENV` does not exist over ssh.
`/etc/profile.d/ape-sandbox.sh` re-establishes it: the `PATH` entries this image adds
(`/opt/ape/bin`, `/usr/local/go/bin`) and then `$HOME/.ape-env`, the per-workspace file
`aped` writes with the durable cache paths (`GOPATH`, `GOBIN`, `ASDF_DATA_DIR`) and the
egress proxy.

Measured, not assumed: before this, `go` was missing from every ssh / VS Code Remote
shell even though the image ships it, and `GOPATH` pointed at the ephemeral rootfs
rather than the durable cache — so an ssh session silently defeated the offline-after-
warmup property.

Inside a workspace, install the framework's skills + pipelines from the mount
without touching the network:

```bash
ape framework setup --no-fetch
```

## Build

```bash
make build                                  # local build
make build NERDCTL="sudo nerdctl" NAMESPACE=aped   # straight into a local aped
make smoke                                  # verify claude/asdf/bingo + the mountpoints
make smoke-delivery APE=$(command -v ape)   # verify a mounted ape resolves as `ape`
make publish                                # build + push to ghcr.io/exoport
```

`smoke-delivery` replaces the old `ape version` check: proving a layer existed said
nothing useful once the binary stopped being baked, while mounting one in the way `aped`
does exercises the mechanism every workspace actually depends on.

CI publishes on a `vX.Y.Z` tag push and build-checks every PR that touches the
Dockerfile. No build secret is needed.

> **Package visibility:** the first push creates the GHCR package **private** —
> `ghcr.io/exoport/ape-sandbox` has since been made public, but a fork or a renamed
> package starts private again. Set it to public on the package page, or every
> consumer needs a pull credential, which is the whole thing this image exists to
> avoid. Check with:
>
> ```bash
> tok=$(curl -s "https://ghcr.io/token?scope=repository%3Aexoport%2Fape-sandbox%3Apull&service=ghcr.io" | jq -r .token)
> curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $tok" \
>   https://ghcr.io/v2/exoport/ape-sandbox/manifests/v1.0.0   # 200 = public
> ```

## Platforms

The published image is **`linux/amd64` only**: the workflow passes no `platforms:` to
`build-push-action`, so it builds for the runner it lands on.

The Dockerfile itself is already arch-parameterized — Go and asdf are fetched per
`TARGETARCH` — so adding arm64 is a **workflow** change, not a Dockerfile one. (`ape` is
not among them any more: it arrives from the node at runtime, which means the node's `ape`
must match the guest's architecture — `aped` asserts that rather than discovering it as an
exec format error inside the VM.) Two ways, in increasing order of moving parts:

- `platforms: linux/amd64,linux/arm64` plus `docker/setup-qemu-action`. One line, but
  the arm64 half builds under emulation; the npm native modules and Playwright are
  where that tends to get slow or fail.
- A matrix over a native `ubuntu-24.04-arm` runner (free for public repos) that pushes
  per-arch digests, then a merge job assembling one manifest index. Near-native build
  times, at the cost of a two-job workflow.

Either way it needs a **new image version** — a published tag is never re-pushed — and
the consumer's digest pin (`sandbox.DefaultImage`) has to move with it. `aped` requires
Linux + KVM + Kata, so this only matters once there is an arm64 host to run it on.

## Versioning

The image has its **own version line**, independent of `ape`. It changes for reasons `ape`
does not — a new base image, a newer asdf/bingo, a Playwright bump — and tying the tags
together would mean either cutting a meaningless `ape` release to ship an image fix, or a
tag that lies about what changed.

**One** pin remains, and it points one way:

| Pin | Where | Meaning |
| --- | --- | --- |
| `sandbox.DefaultImage` | `apex_process_ape`, `internal/sandbox/kata.go` (+ the `aped` policy image allow-list, which is matched by EXACT string and must move with it) | which image `ape` provisions |

Nothing here points back at `ape`. The old second pin (`ARG APE_VERSION`) is gone with the
baked binary, and so is the version floor it needed: `ape framework setup` requires the
scoped `safe.directory` fix (v0.0.49) to read the read-only, host-owned framework mount,
and a *delivered* `ape` is the node's own, so it cannot predate its own daemon.

## Pinning policy
- The base image is **digest-pinned** in the `Dockerfile`. Never publish an image
  built on a floating `:latest` base.
- `USER` is **numeric** (`0`). `aped`'s containerd driver resolves the image user
  without mounting the rootfs, so a named user (`root`) is rejected outright.
- The base expects `seccomp=unconfined`. That is acceptable here: the Kata microVM
  is the security boundary, not the container's seccomp profile.

## License

Apache-2.0 (the base image's license). The image contains no private APEX
material.
