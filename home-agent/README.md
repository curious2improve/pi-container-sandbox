# home-agent — the sandbox's agent home

This directory is bind-mounted **read-write** as the complete agent home `/home/agent` inside the sandbox container (see `pcs_build_volume_flags()` in `bin/lib/common.sh`). Everything in it is visible to the agent user and persists on the host between sessions: dotfiles, `.pi/` state, package caches, tool config — and anything else you deliberately want the agent to have (git credentials, SSH keys, `curl`/`gh` config, ...).

Everything in this directory is **git-ignored** (live state that may contain sessions and credentials), with two exceptions that are tracked: this README and `.pi/agent/models.json` (endpoint/model definitions, no secrets).

## First-use seeding (template + marker)

The image bakes a template of the fully set-up agent home (default dotfiles, `.pi` skeleton, `.npm-global/`, `.cache/`, `.local/` with pipx and uv, ...) at `/usr/local/share/home-agent-template` — a path the `/home/agent` mount does **not** hide (see `config/Containerfile`). The sandbox entrypoint (`config/sandbox-entrypoint.sh`, copied into the image) copies that template into this directory **exactly once**, on the first container start:

- `cp -an` — archive, **no-clobber**: anything that already exists here is never overwritten; only missing pieces are filled in. Your customizations always win.
- Completion is tracked with the `.sandbox-home-initialized` marker file in this directory. Later starts skip the copy entirely.
- Delete the marker (or wipe the whole directory) to force a re-seed from the template.

## Expected folder structure

`.pi` is Pi's state directory (`~/.pi` = `.pi` here); Pi keeps its agent data under `.pi/agent`:

```text
home-agent/                       # = /home/agent in the container
├── README.md                     # this file (tracked, along with .pi/agent/models.json)
├── .sandbox-home-initialized     # entrypoint marker (managed automatically)
├── .bashrc, .profile, ...        # default dotfiles (from the template)
├── .npm-global/                  # global npm packages (bin/ on PATH)
├── .npm/, .cache/, .local/       # package caches + pipx/uv (all persist here)
├── .config/, ...                 # any tool config you or the agent creates
└── .pi/                          # = /home/agent/.pi (Pi state)
    └── agent/
        ├── settings.json         # user settings: model, preferences, packages
        ├── models.json           # custom endpoints / compatible model defs
        ├── auth.json             # API keys / OAuth credentials
        ├── AGENTS.md             # (optional) user instructions, applied everywhere
        ├── extensions/           # hand-written extensions
        ├── skills/               # (optional) user skills
        ├── prompts/              # (optional) prompt templates (slash commands)
        ├── themes/               # (optional) theme files
        ├── keybindings.json      # (optional) custom keybindings
        ├── trust.json            # project trust decisions (managed by Pi)
        ├── npm/                  # packages installed via `pi install` (managed by Pi)
        └── sessions/             # session history (managed by Pi)
```

You do not need to pre-create anything: the template plus Pi create the skeleton on first use. The entries you normally author yourself are `.pi/agent/settings.json` (and optionally `models.json` / `AGENTS.md`).

## Setting up the LLM API endpoint

Point the sandbox at your local OpenAI-compatible server (oMLX/Qwen or "splash") by creating `.pi/agent/settings.json` and `.pi/agent/models.json` here. Easiest ways:

- Run `./bin/pcs shell`, then `pi config` inside the container — the resulting files land in this directory, or
- Edit `.pi/agent/settings.json` / `.pi/agent/models.json` directly on the host (they are plain JSON); use the `OPENAI_BASE_URL` value from `config/sandbox.env` and replace the model id with the one your server reports at `/v1/models`.

## Extensions

`pcs start` checks every entry of `PI_SANDBOX_EXTENSIONS` (`config/sandbox.env`) with `pi list` inside the container and runs `pi install` for anything missing. Installed packages land in `.pi/agent/npm/` and persist in this directory — a fresh or wiped `home-agent/` repairs itself on the next start (template re-seed + extension preflight). Hand-written extensions belong in `.pi/agent/extensions/`.

## Notes

- The container runs as UID 1000. If Pi cannot write here, fix ownership: `sudo chown 1000:1000 home-agent` (`pcs start` warns when the owner UID differs).
- Deleting the contents of `.pi/agent/` resets all Pi user state (delete the marker file too if you also want a template re-seed). `pcs reset` never touches this directory.
- Never commit anything from here (contents are git-ignored on purpose — including `.pi/agent/auth.json`, which holds credentials).
