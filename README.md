# Pi Apple macOS Container Sandbox

[![macOS](https://img.shields.io/badge/macOS-26%2B_Tahoe-black?logo=apple&logoColor=white)](https://developer.apple.com/macos/)
[![arch](https://img.shields.io/badge/arch-arm64_Apple_silicon-blue)](#prerequisites)
[![runtime](https://img.shields.io/badge/runtime-Apple_Container-lightgrey)](https://github.com/apple/container)
[![license](https://img.shields.io/badge/license-GPLv3-blue.svg)](#license)

**Run the Pi coding agent, including third-party extensions, safely on your own Mac.**

A minimal, reproducible development sandbox for [Pi](https://github.com/earendil-works/pi) (`@earendil-works/pi-coding-agent`) on Apple silicon. It follows the same idea as [Pi’s containerization docs](https://pi.dev/docs/latest/containerization): isolate Pi and every extension with native, lightweight macOS platform tools.

> Set Pi to full-auto with no restrictions and watch it go. ;-)

## Contents

- [Pi Apple macOS Container Sandbox](#pi-apple-macos-container-sandbox)
  - [Contents](#contents)
  - [Features](#features)
  - [Prerequisites](#prerequisites)
  - [Quick start](#quick-start)
  - [Command reference](#command-reference)
  - [Configuration](#configuration)
    - [Local LLM endpoint (Qwen / oMLX / Ollama)](#local-llm-endpoint-qwen--omlx--ollama)
    - [Pi settings and extensions](#pi-settings-and-extensions)
    - [Resource limits](#resource-limits)
  - [Persistent storage](#persistent-storage)
  - [Security model](#security-model)
  - [Dependency versions](#dependency-versions)
  - [Repository layout](#repository-layout)
  - [Scope and limitations](#scope-and-limitations)
  - [License](#license)

## Features

- **Apple `container` only.** No Docker Desktop, Podman, Colima, OrbStack, or any other third-party runtime is used or required.
- **Debian Trixie ARM64** (`debian:trixie-slim`) with a practical Python, Node.js, media, linting, build, and shell toolchain, plus `diff`, `patch`, `man`, `lsof`, `htop`, `yq`, `uv` (via pipx/PyPI — not a Debian package), `gh`, `strace`, `tmux`, and `fzf`. Add packages in `config/Containerfile`.
- **No version pinning.** Each build resolves the newest Debian packages, Pi agent, and npm/PyPI packages available at build time.
- **Unprivileged `agent` (UID/GID 1000), never root.** All Linux capabilities dropped (`--cap-drop ALL`). Root filesystem is read-only; only `/tmp`, `/run`, and the two host bind mounts below are writable.
- **Exactly two host bind mounts.** Your project folder (via `pcs start --workspace-source <dir>`, mandatory on first use, then persisted) at `/workspace` — edited in place, including `.git`. This repository’s `home-agent/` at `/home/agent` — the complete agent home (Pi state, package caches, dotfiles, tool config). A container entrypoint seeds it from an image-baked template exactly once and never overwrites your customizations. No other host path is ever mounted.
- **Local or remote LLMs.** Talks to a Qwen / oMLX / “splash” OpenAI-compatible API on the Mac, default `http://host.container.internal:8000/v1` (Apple Container maps that hostname to the host’s `127.0.0.1`). Or use any internet API (OpenRouter, etc.).
- **Normal Apple Container networking.** Outbound Internet works. This is explicitly *not* a network-filtering solution.

**Your responsibility:** because the project folder is fully visible to Pi, keep credentials and tokens Pi should not read out of it. `/home/agent` is the one place you may *deliberately* hand the agent git/SSH credentials and tool configs.

## Prerequisites

- Apple silicon Mac running **macOS Tahoe (macOS 26)** or later
- [Homebrew](https://brew.sh/)
- Apple’s [`container` CLI](https://github.com/apple/container) installed and working
- A local OpenAI-compatible LLM API on the Mac — recommended: [splash](https://github.com/incoai/splash); oMLX, Ollama, and similar also work — **or** any internet LLM API (OpenRouter, etc.)
- Optional: [Ghostty](https://ghostty.org/) (OSC 7501 support)

```bash
brew install container
# or download the signed installer from:
# https://github.com/apple/container/releases
```

Useful `container` commands (every `pcs` subcommand already runs `container system start` if needed):

```bash
container system start      # starts container-apiserver (once per boot/login)
container system status     # service + host/server info
container list --all        # running and stopped containers
container volume list
container image list
```

## Quick start

```bash
./bin/pcs build
cp config/sandbox.env.example config/sandbox.env
# edit config/sandbox.env if your endpoint is not
# http://host.container.internal:8000/v1
./bin/pcs start --workspace-source ~/Projects/myproject   # first run: pick the project folder
./bin/pcs verify
./bin/pcs stop
```

`--workspace-source` is saved in `config/sandbox.env` on first use, so later `./bin/pcs start` (and `shell` / `verify`) reuse it. Pi starts in `/workspace` (your project).

`pcs` lives in `bin/pcs`. Run `./bin/pcs <subcommand>` from the repository root, or add `bin/` to your `PATH`.

`config/sandbox.env` is git-ignored. It holds your real endpoint and is never committed.

## Command reference

Every subcommand:

- runs under `set -euo pipefail`
- quotes variable expansions
- works from any working directory (repository root via `BASH_SOURCE`)
- prints concise, prefixed errors (`error: ...`)
- supports `-h` / `--help`
- avoids Homebrew-only utilities and requires **Bash ≥ 4.4** (macOS system Bash is 3.2 — use Homebrew `bash` or newer)

| Subcommand | Purpose |
|---|---|
| `pcs build` | Build and tag `local/pi-dev:trixie` for `linux/arm64`, always resolving dependencies to their newest releases. |
| `pcs start [--workspace-source <dir>]` | Start interactively (default: `pi` in `/workspace`). `--workspace-source` is mandatory on first use (an existing local folder), then persisted in `config/sandbox.env`; passing it again updates the mapping. If the configured endpoint uses `host.container.internal`, ensures the system-wide DNS mapping (checked via `container system dns list`, created only if missing; `sudo` once). |
| `pcs shell [--workspace-source <dir>]` | Bash in `/workspace` of the running sandbox, or a temporary one. Same `--workspace-source` semantics as `start`. |
| `pcs status` | Service / image / container / workspace-source / limits / endpoint. |
| `pcs logs` | Print or follow sandbox container logs. |
| `pcs stop` | Stop the sandbox without touching any data. |
| `pcs reset` | Destructively remove the container. Never touches your project folder or `home-agent/`. |
| `pcs verify` | Full isolation / tooling / connectivity check battery. |

```bash
./bin/pcs build                       # newest of everything
./bin/pcs build --no-cache --pull     # clean rebuild, fresh base layer, re-resolve all deps
./bin/pcs build --release             # verify no pinning remains, then clean rebuild

./bin/pcs start --workspace-source ~/Projects/myproject   # first run
./bin/pcs start                       # reuses the saved mapping; runs `pi` in /workspace
./bin/pcs start -- bash               # drop into Bash instead
./bin/pcs start -- pytest             # run pytest instead
./bin/pcs start --detach -- sleep 3600

./bin/pcs shell                       # Bash in /workspace, running or temporary container

./bin/pcs status
./bin/pcs logs --follow
./bin/pcs stop

./bin/pcs reset --delete-data                     # container only (never your files)
./bin/pcs reset --delete-data --delete-image      # also remove the image

./bin/pcs verify
```

**Stop vs reset**

- **`pcs stop`** stops the running container. Your project folder and `home-agent/` are left untouched.
- **`pcs reset --delete-data`** removes the container. It does **not** touch your project folder or `home-agent/` — clear `home-agent/` yourself for a clean Pi state (also delete `.sandbox-home-initialized` if you want a template re-seed). Refuses to run without `--delete-data`. Add `--delete-image` to remove the built image (off by default).

## Configuration

### Local LLM endpoint (Qwen / oMLX / Ollama)

Pi and `pcs verify` read the endpoint from `config/sandbox.env`.

`127.0.0.1` **inside the container is not your Mac**, so `http://127.0.0.1:8000/v1` would fail.

**Recommended: host-container DNS** (no engine changes). Point `OPENAI_BASE_URL` at `http://host.container.internal:8000/v1`. `./bin/pcs start` then:

1. Checks `container system dns list`.
2. If missing, creates a system-wide Apple Container DNS entry `host.container.internal` pointing at a synthetic, non-routable IP that Apple Container maps back to the host’s `127.0.0.1` (`sudo` once; existing mappings are left untouched).

Any container can then reach an engine bound to **`127.0.0.1` only** — no `0.0.0.0` binding, no gateway-IP guessing, no port publishing.

```dotenv
OPENAI_BASE_URL=http://host.container.internal:8000/v1
OPENAI_API_KEY=local-only-placeholder
```

**Alternative: VM gateway** (no DNS mapping). Two things must line up:

1. The local engine must bind to an address the container can reach, not just `127.0.0.1`. Binding `0.0.0.0` is simplest, but **exposes the API on the local network**.
2. `OPENAI_BASE_URL` must be an address the container can reach — typically the Apple Container VM gateway (`nameserver` in `/etc/resolv.conf` inside a running container, or `ip route`), e.g.:

   ```dotenv
   OPENAI_BASE_URL=http://192.168.64.1:8000/v1
   ```

This project never modifies your local engine’s configuration. It only consumes `OPENAI_BASE_URL` / `OPENAI_API_KEY`. `./bin/pcs verify` prints the configured endpoint (never the API key) and fails concisely if `/v1/models` is unreachable.

### Pi settings and extensions

Pi’s persistent state lives in `/home/agent/.pi` — on the host, `home-agent/.pi/agent/settings.json`. See [`home-agent/README.md`](home-agent/README.md) for folder structure, first-use template seeding, and setup.

You can edit Pi settings from outside the sandbox and `/reload` inside Pi. Pi can also modify those files itself.

```bash
# interactive, from inside the sandbox:
./bin/pcs shell && pi config

# or edit the JSON directly on the host (plain files, git-ignored):
$EDITOR home-agent/.pi/agent/settings.json
```

Use the `OPENAI_BASE_URL` from `config/sandbox.env` and the model id your local server reports at `/v1/models`.

**`AGENTS.md`.** Tell Pi it is running in a sandbox: the project is in `/workspace`, and its home folder, `/workspace`, and `/tmp` are the only places it can and should write. You can also tell Pi to modify itself autonomously.

**Extensions.** Official packages from [pi.dev/packages](https://pi.dev/packages) go in `config/sandbox.env` (`PI_SANDBOX_EXTENSIONS`) and are installed automatically on startup. Configure each one per its docs. Extra Linux packages (ffmpeg, ImageMagick, …) belong in the Containerfile — Pi cannot install Debian packages inside the container.

### Resource limits

Defaults: **8 CPUs / 16 GiB**. Override in `config/sandbox.env` or the environment:

```dotenv
PI_SANDBOX_CPUS=8
PI_SANDBOX_MEMORY=16G
PI_SANDBOX_IMAGE=local/pi-dev:trixie
PI_SANDBOX_NAME=pi-sandbox
PI_SANDBOX_QWEN_URL=http://host.container.internal:8000/v1
```

## Persistent storage

Two read-write **host bind mounts**. Both are plain directories on your machine — nothing lives in Apple Container’s volume store — so `pcs stop` and `pcs reset` can never lose your files.

| Host path | Mounted at | Purpose |
|---|---|---|
| Your project folder | `/workspace` | Project in place. Everything — including `.git`, `.npm`, dotfiles — is visible and writable. Pi can read history, commit, branch, and tag against the real repository. No import/export copy step. |
| `home-agent/` (this repo) | `/home/agent` | Complete agent home: `.pi/`, package caches, dotfiles, tool config. Seeded from the image template on first use. Never used for project code. |

The `/workspace` source is `pcs start --workspace-source <dir>` (mandatory on first use; the folder must exist). Scripts persist it as `PI_SANDBOX_WORKSPACE_SOURCE` in `config/sandbox.env`. Passing the flag again updates the mapping.

`home-agent/` contents are git-ignored (live state: sessions, credentials). Whatever you place there is visible at `/home/agent`; whatever the agent writes appears on the host. `pcs start` warns if the directory’s host UID is not 1000, which would block writes from inside.

**First-use seeding.** The image bakes a template at `/usr/local/share/home-agent-template` (a path the mount does not hide). `config/sandbox-entrypoint.sh` copies it with `cp -an` exactly once (existing files are never overwritten) and records that in `home-agent/.sandbox-home-initialized`. Delete the marker or the folder to force a re-seed.

npm / pip / uv caches live in the agent home (`.npm/`, `.cache/`, `.local/`) and persist between sessions. No `/tmp` redirection is performed.

**Never mounted** by any script in this repo: `$HOME`, `$HOME/.ssh`, `$HOME/.config`, `$HOME/.gitconfig`, `$HOME/.pi`, `/`, `/Users`. Apple Container’s SSH-agent forwarding (`container run --ssh`) is never used.

**Security:** the entire workspace folder — including hidden files — is readable and writable by Pi. Do not point `--workspace-source` at a folder (or a parent of one) that contains credentials Pi should not access (`~/.netrc`, git credential stores, SSH config, other projects’ `.env` files). Keep those secrets outside the project tree.

## Security model

Every sandbox container is equivalent to:

```bash
container run --rm -it \
  --name pi-sandbox \
  --platform linux/arm64 \
  --cpus 8 --memory 16G \
  --user 1000:1000 \
  --cap-drop ALL \
  --read-only \
  --tmpfs /tmp --tmpfs /run \
  --mount type=bind,source=/path/to/your/project,target=/workspace \
  --mount type=bind,source=$PWD/home-agent,target=/home/agent \
  --env-file ./config/sandbox.env \
  local/pi-dev:trixie
```

The workspace `source` is the `--workspace-source` folder persisted in `config/sandbox.env`. Mounts are writable by default; `--read-only` applies only to the root filesystem. The image entrypoint seeds `/home/agent` from its built-in template once, then launches the command. `pcs` never passes `--entrypoint`.

- Apple silicon arm64 only. Rosetta is never enabled. No x86_64 packages are installed.
- UID/GID 1000 (`agent`) for Pi and all tooling, never root.
- Root filesystem read-only; writable: `/tmp`, `/run`, and the two bind mounts above.
- All Linux capabilities dropped; none added back. `pcs verify` confirms `CapEff` is all-zero inside the sandbox.
- Those two bind mounts are the only host paths visible. The project folder is fully exposed by design; keeping secrets out of it is on you. `home-agent/` is where you *may* hand credentials and tool configs to the agent — decide per folder what belongs there.
- `tini` is PID 1 (`ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/sandbox-entrypoint.sh"]`), so signals are forwarded and zombies are reaped for long-running Pi sessions and their subprocesses.

## Dependency versions

This sandbox ships **no version pinning anywhere**. Every build installs the newest available:

| Component | Source |
|---|---|
| Debian packages | whatever `trixie` currently provides (`--pull` for a fresh `trixie-slim` base) |
| Pi agent (`@earendil-works/pi-coding-agent`) | newest npm release |
| ESLint, Prettier, TypeScript, typescript-language-server | newest npm releases |
| black, mypy, pytest, ruff in `/opt/venv` | newest PyPI releases |
| `uv` | PyPI via Debian `pipx` (no `uv` package in Debian) |
| Node.js | newest release in the selected major series |

The only build argument is `NODE_MAJOR` (default `24`). It selects the Node.js *major series* in the NodeSource repository, not a package version: Pi requires Node.js ≥ 22, while Debian Trixie’s `nodejs` is older. Override with `pcs build --node-major N`.

Practical consequences:

- Rebuild periodically: `./bin/pcs build --no-cache --pull`.
- `pcs build --release` statically checks that **no** pinning (`*_VERSION` ARGs, `==` / `@x.y.z` specs) has crept into `config/Containerfile`, then does a clean, no-cache build with a fresh base-image pull.
- The build log prints resolved toolchain versions at the end of the image build, so drift is visible even though it is not asserted.
- `pcs verify` checks tool **presence only**, never versions.

## Repository layout

```text
pi-container-sandbox/
├── README.md
├── home-agent/                    # bind-mounted read-write as /home/agent (see its README.md)
├── config/
│   ├── Containerfile              # Debian Trixie ARM64 image definition
│   ├── sandbox.env.example        # safe placeholder env file
│   └── sandbox-entrypoint.sh      # seeds /home/agent once, then launches
└── bin/
    ├── pcs                        # single CLI entry point
    └── lib/
        ├── common.sh              # shared helpers (sourced by bin/pcs)
        ├── cmd_build.sh           # one file per subcommand
        ├── cmd_start.sh           # also ensures host.container.internal DNS
        ├── cmd_shell.sh
        ├── cmd_status.sh
        ├── cmd_logs.sh
        ├── cmd_stop.sh
        ├── cmd_reset.sh
        └── cmd_verify.sh
```

## Scope and limitations

This implements the **“Native Apple Container alone”** option only. It deliberately does **not** include a gateway/proxy container, nftables or eBPF filtering, a custom init image, domain allowlists, private- or corporate-network filtering, a Docker-compatible daemon, SSH-agent forwarding, direct host home-directory mounts, automatic host credential access, privileged containers, or nested virtualization.

> **Host and network isolation.** Filesystem containment is limited to the two bind mounts above. Everything else stays isolated: read-only root filesystem, all capabilities dropped, unprivileged user, no SSH-agent or other host mounts. The sandbox does **not** prevent the container from reaching the local network or a corporate network through Apple Container’s default networking — public Internet and local/corporate access are both available. Network restriction is out of scope; that is what lets the agent use the Internet flexibly.

## License

[GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html)

Copyright (C) 2026 the Pi Apple macOS Container Sandbox contributors.

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the [GNU General Public License](https://www.gnu.org/licenses/gpl-3.0.html) for more details.
