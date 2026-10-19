#!/bin/bash
# Container entrypoint for the pi Apple Container sandbox.
#
# This file is copied into the image at /usr/local/bin/sandbox-entrypoint.sh
# (see config/Containerfile) and is the image ENTRYPOINT (behind tini,
# PID 1). It runs as the unprivileged 'agent' user (UID 1000), the same user
# every 'pcs' container run uses.
#
# Two jobs, in order:
#
# 1. Seed the agent home ONCE. The host folder mounted at /home/agent starts
#    empty on first use. The image carries a template of the fully set-up
#    agent home (/usr/local/share/home-agent-template: default dotfiles,
#    .pi skeleton, .npm-global, .cache, .local, ...). On the first run we
#    copy the template into the mounted home, never overwriting anything
#    that already exists (cp -an: archive + no-clobber) — customizations the
#    developer made on the host always win. Completion is tracked with the
#    .sandbox-home-initialized marker file in the home, so later runs skip
#    the copy entirely. Delete the marker (or the whole home) to force a
#    re-seed.
#
# 2. Launch. The command is the container's CMD / first arguments:
#       - "pi"    -> run 'pi update' and 'pi update --extensions' (so pi
#                    and its extensions are always fresh), then cd into
#                    /workspace (the mounted project folder) and exec pi
#                    with the remaining arguments
#       - "shell" -> cd into /workspace and exec bash
#       - anything else is exec'ed as-is (e.g. "bash -c ...", "pytest")
#
# Note: no root operations are possible or needed here (the container runs
# with --user 1000:1000 and --cap-drop ALL). The permission fixes below are
# therefore best-effort: they apply to files owned by the agent user and
# silently skip anything else.
set -uo pipefail

AGENT_HOME="${AGENT_HOME:-/home/agent}"
export HOME="${AGENT_HOME}"
TEMPLATE="/usr/local/share/home-agent-template"
MARKER="${AGENT_HOME}/.sandbox-home-initialized"

# ---------------------------------------------------------------------------
# 1) One-time home seeding from the image template.
# ---------------------------------------------------------------------------
if [[ ! -f "${MARKER}" ]]; then
  if [[ -d "${TEMPLATE}" ]]; then
    # -a: recursive, preserve attributes. -n: never overwrite existing
    # files or descend into existing directories' contents destructively —
    # host-side customizations are always kept, only missing pieces are
    # filled in. Errors (e.g. files owned by other UIDs) are not fatal.
    cp -an "${TEMPLATE}/." "${AGENT_HOME}/" 2>/dev/null || true
    # Best-effort permission repair for everything the agent owns.
    chown -R 1000:1000 "${AGENT_HOME}" 2>/dev/null || true
    chmod -R u+rwX "${AGENT_HOME}" 2>/dev/null || true
  fi
  : > "${MARKER}"
  echo "sandbox: agent home initialized from template (marker: ${MARKER})" >&2
fi

# ---------------------------------------------------------------------------
# 2) Launch.
# ---------------------------------------------------------------------------
case "${1:-}" in
  pi)
    shift
    # Keep pi and its installed extensions current on every start.
    # Best-effort: a failed update (e.g. no network) never blocks the
    # session, we just continue with the currently installed versions.
    pi update \
      || echo "sandbox: 'pi update' failed; continuing with the installed version" >&2
    pi update --extensions \
      || echo "sandbox: 'pi update --extensions' failed; continuing with the installed extensions" >&2
    cd /workspace 2>/dev/null || true
    exec pi "$@"
    ;;
  shell)
    cd /workspace 2>/dev/null || true
    exec bash
    ;;
  "")
    echo "sandbox-entrypoint: no command given" >&2
    exit 1
    ;;
  *)
    exec "$@"
    ;;
esac
