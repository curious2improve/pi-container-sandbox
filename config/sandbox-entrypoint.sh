#!/bin/bash
# Container entrypoint for the pi Apple Container sandbox.
#
# This file is copied into the image at /usr/local/bin/sandbox-entrypoint.sh
# (see config/Containerfile) and is the image ENTRYPOINT (behind tini,
# PID 1). It runs as the unprivileged 'agent' user (UID 1000), the same user
# every 'pcs' container run uses.
#
# Three jobs, in order:
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
# 2. Map local LLM endpoints to the host-container hostname. Inside the
#    container, localhost / 127.0.0.1 / ::1 is the container itself, not the
#    Mac — so a loopback endpoint could never work as written. OPENAI_BASE_URL
#    and the baseUrl entries of /home/agent/.pi/agent/models.json are
#    checked independently; every URL whose host is loopback is rewritten to
#    host.container.internal, which 'pcs start' / 'pcs shell' map back to the
#    host's own 127.0.0.1. URLs pointing at any other host, domain, or IP
#    (external APIs like OpenRouter, the VM gateway, ...) are left completely
#    untouched.
#
# 3. Launch. The command is the container's CMD / first arguments:
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
# 2) Map local LLM endpoints to the host-container hostname.
# ---------------------------------------------------------------------------
HOST_DNS_NAME="host.container.internal"

# $1: URL -> prints it with a loopback host replaced by HOST_DNS_NAME
# (port and path preserved); other hosts print unchanged.
map_url_host() {
  local url="${1:-}"
  if [[ "${url}" =~ ^(https?://)(localhost|127\.0\.0\.1|::1)([:/].*)?$ ]]; then
    printf '%s%s%s' "${BASH_REMATCH[1]}" "${HOST_DNS_NAME}" "${BASH_REMATCH[3]:-}"
  else
    printf '%s' "${url}"
  fi
}

if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
  mapped="$(map_url_host "${OPENAI_BASE_URL}")"
  if [[ "${mapped}" != "${OPENAI_BASE_URL}" ]]; then
    echo "sandbox: OPENAI_BASE_URL ${OPENAI_BASE_URL} -> ${mapped} (host-container hostname)" >&2
    OPENAI_BASE_URL="${mapped}"
    export OPENAI_BASE_URL
  fi
fi

MODELS_JSON="${AGENT_HOME}/.pi/agent/models.json"
if [[ -f "${MODELS_JSON}" ]] \
  && grep -Eq '"baseUrl"[[:space:]]*:[[:space:]]*"https?://(localhost|127\.0\.0\.1|::1)([:/]|")' "${MODELS_JSON}"; then
  sed -E -i 's#(https?://)(localhost|127\.0\.0\.1|::1)([:/])#\1'"${HOST_DNS_NAME}"'\3#g' "${MODELS_JSON}"
  echo "sandbox: models.json loopback baseUrl(s) -> ${HOST_DNS_NAME}" >&2
fi

# ---------------------------------------------------------------------------
# 3) Launch.
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
