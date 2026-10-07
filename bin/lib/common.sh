#!/usr/bin/env bash
# Shared helpers for the pcs CLI (sourced by bin/pcs).
# This file is sourced, not executed directly, so it intentionally has no
# shebang-driven `set -euo pipefail` side effects beyond what the caller set.

# ---------------------------------------------------------------------------
# Repo root resolution, independent of the caller's working directory.
# ---------------------------------------------------------------------------
pcs_repo_root() {
  local source="${BASH_SOURCE[0]}"
  local dir
  dir="$(cd -- "$(dirname -- "${source}")" >/dev/null 2>&1 && pwd -P)"
  # lib/ -> bin/ -> repo root
  (cd -- "${dir}/../.." >/dev/null 2>&1 && pwd -P)
}

PCS_REPO_ROOT="$(pcs_repo_root)"
readonly PCS_REPO_ROOT
PCS_CONFIG_DIR="${PCS_REPO_ROOT}/config"
readonly PCS_CONFIG_DIR
PCS_ENV_FILE="${PCS_CONFIG_DIR}/sandbox.env"
readonly PCS_ENV_FILE

# ---------------------------------------------------------------------------
# Messaging helpers. All diagnostics go to stderr so stdout stays clean for
# any piped/scripted consumption.
# ---------------------------------------------------------------------------
pcs_err() { printf 'error: %s\n' "$*" >&2; }
pcs_warn() { printf 'warning: %s\n' "$*" >&2; }
pcs_info() { printf '%s\n' "$*" >&2; }
pcs_die() {
  pcs_err "$*"
  exit 1
}

# ---------------------------------------------------------------------------
# Defaults, overridable through environment variables of the same name.
# ---------------------------------------------------------------------------
pcs_load_defaults() {
  PI_SANDBOX_CPUS="${PI_SANDBOX_CPUS:-8}"
  PI_SANDBOX_MEMORY="${PI_SANDBOX_MEMORY:-16G}"
  PI_SANDBOX_IMAGE="${PI_SANDBOX_IMAGE:-local/pi-dev:trixie}"
  PI_SANDBOX_NAME="${PI_SANDBOX_NAME:-pi-sandbox}"
  PI_SANDBOX_QWEN_URL="${PI_SANDBOX_QWEN_URL:-${OPENAI_BASE_URL:-}}"
  # Space- or comma-separated list of pi extensions (package sources) that
  # must be present inside the sandbox; 'pcs start' installs any that are
  # missing. See pcs_ensure_pi_extensions().
  PI_SANDBOX_EXTENSIONS="${PI_SANDBOX_EXTENSIONS:-}"
  # Host folder bind-mounted read-write at /workspace. Supplied via
  # 'pcs start|shell --workspace-source' on first use, then persisted here.
  PI_SANDBOX_WORKSPACE_SOURCE="${PI_SANDBOX_WORKSPACE_SOURCE:-}"
  export PI_SANDBOX_CPUS PI_SANDBOX_MEMORY PI_SANDBOX_IMAGE PI_SANDBOX_NAME PI_SANDBOX_QWEN_URL PI_SANDBOX_EXTENSIONS PI_SANDBOX_WORKSPACE_SOURCE
}

# Load config/sandbox.env (if present) without clobbering variables already
# set in the calling shell's environment, then apply defaults.
pcs_load_env() {
  if [[ -f "${PCS_ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${PCS_ENV_FILE}"
    set +a
  fi
  pcs_load_defaults
}

pcs_require_env_file() {
  if [[ ! -f "${PCS_ENV_FILE}" ]]; then
    pcs_die "missing ${PCS_ENV_FILE}. Run: cp config/sandbox.env.example config/sandbox.env"
  fi
}

# ---------------------------------------------------------------------------
# Mount / container naming (fixed names per the sandbox spec).
#
# The sandbox uses exactly two read-write host bind mounts and no named
# volumes: the user's project folder at /workspace, and the repo's
# home-agent/ (the complete agent home, incl. .pi) at /home/agent.
# ---------------------------------------------------------------------------

# Synthetic hostname Apple Container maps back to the host's own 127.0.0.1
# (system DNS entry, created by 'pcs start'). Lets containers reach a
# host-side API server bound to 127.0.0.1 only.
PCS_HOST_DNS_NAME="host.container.internal"
# shellcheck disable=SC2034  # used by the cmd_*.sh files sourced into bin/pcs
readonly PCS_HOST_DNS_NAME

# Host directory bind-mounted (read-write) at /home/agent/.pi inside the
# sandbox. Whatever lives in it is visible in the container's .pi folder and
# vice versa.
PCS_AGENT_HOME_DIR="${PCS_REPO_ROOT}/home-agent"
readonly PCS_AGENT_HOME_DIR

# Host directory bind-mounted (read-write) at /workspace. Supplied via
# --workspace-source (canonical absolute path); resolved by
# pcs_ensure_workspace_source().
PCS_WORKSPACE_SOURCE=""


# ---------------------------------------------------------------------------
# Prerequisite checks.
# ---------------------------------------------------------------------------
pcs_require_container_cli() {
  if ! command -v container >/dev/null 2>&1; then
    pcs_die "Apple's 'container' CLI was not found on PATH. Install it from https://github.com/apple/container and re-run."
  fi
}

pcs_require_arm64_host() {
  local arch
  arch="$(uname -m)"
  if [[ "${arch}" != "arm64" && "${arch}" != "aarch64" ]]; then
    pcs_die "this sandbox targets Apple silicon (arm64); detected host architecture '${arch}'."
  fi
}

# Returns 0 if the Apple Container system API is reachable.
pcs_container_system_running() {
  container system status >/dev/null 2>&1
}

pcs_ensure_container_system() {
  if ! pcs_container_system_running; then
    pcs_info "Apple Container system is not running; starting it..."
    if ! container system start; then
      pcs_die "failed to start the Apple Container system. Try running 'container system start' manually."
    fi
  fi
}


# (Re)write the PI_SANDBOX_WORKSPACE_SOURCE line in config/sandbox.env, so
# the /workspace -> host folder mapping persists across invocations.
pcs_persist_workspace_source() {
  local source="$1"
  local tmp
  tmp="$(mktemp)" || return 1
  awk -v key="PI_SANDBOX_WORKSPACE_SOURCE" -v val="${source}" '
    $0 ~ "^" key "=" { printf "%s=\"%s\"\n", key, val; found=1; next }
    { print }
    END { if (!found) printf "%s=\"%s\"\n", key, val }
  ' "${PCS_ENV_FILE}" > "${tmp}" && cat "${tmp}" > "${PCS_ENV_FILE}"
  local rc=$?
  rm -f "${tmp}"
  return ${rc}
}

# Resolve and validate the host folder that is bind-mounted at /workspace.
# With $1 given (the --workspace-source argument) it must be an existing
# directory; it is then persisted (updating any previous mapping). With $1
# empty, the persisted PI_SANDBOX_WORKSPACE_SOURCE (if any) is used. Sets
# the global PCS_WORKSPACE_SOURCE on success.
# Returns 1 (with a message) if no mapping is configured at all.
pcs_ensure_workspace_source() {
  local provided="${1:-}"
  local source="${provided:-${PI_SANDBOX_WORKSPACE_SOURCE:-}}"

  if [[ -z "${source}" ]]; then
    pcs_err "no /workspace source configured: pass --workspace-source <folder> (an existing local directory) or set PI_SANDBOX_WORKSPACE_SOURCE in ${PCS_ENV_FILE}"
    return 1
  fi

  if [[ ! -d "${source}" ]]; then
    pcs_die "workspace source '${source}' does not exist or is not a directory"
  fi
  # Canonical absolute path; the mount spec requires one.
  source="$(cd -- "${source}" >/dev/null 2>&1 && pwd -P)"

  if [[ -n "${provided}" && "${source}" != "${PI_SANDBOX_WORKSPACE_SOURCE}" ]]; then
    if ! pcs_persist_workspace_source "${source}"; then
      pcs_die "could not persist the workspace mapping to ${PCS_ENV_FILE}"
    fi
    PI_SANDBOX_WORKSPACE_SOURCE="${source}"
    export PI_SANDBOX_WORKSPACE_SOURCE
    pcs_info "workspace mapping updated: ${source} -> /workspace (saved to ${PCS_ENV_FILE})"
  fi

  PCS_WORKSPACE_SOURCE="${source}"
}

pcs_ensure_agent_home() {
  mkdir -p "${PCS_AGENT_HOME_DIR}"
  # The container runs as UID 1000; a host directory owned by a different
  # UID may not be writable from inside. Warn, do not fail.
  local uid
  uid="$(stat -f %u "${PCS_AGENT_HOME_DIR}" 2>/dev/null || stat -c %u "${PCS_AGENT_HOME_DIR}" 2>/dev/null || echo 1000)"
  if [[ "${uid}" != "1000" ]]; then
    pcs_warn "home-agent/ is owned by UID ${uid} but the sandbox runs as UID 1000; writes to /home/agent may fail. Fix with: sudo chown 1000:1000 home-agent"
  fi
}

# ---------------------------------------------------------------------------
# Pi extension preflight (run inside a throwaway container before the real
# sandbox session starts).
#
# Checks every entry of PI_SANDBOX_EXTENSIONS (space- or comma-separated)
# against `pi list` inside the sandbox image and installs any that are
# missing with `pi install`. A bare name such as "pi-permission-system" is
# resolved as an npm package; explicit sources ("npm:@scope/pkg",
# "git:github.com/user/repo", URLs, local paths) are passed through
# unchanged. Installs land in /home/agent/.pi inside the mounted agent
# home, so they persist for later runs.
# ---------------------------------------------------------------------------

pcs_ensure_pi_extensions() {
  local raw="${PI_SANDBOX_EXTENSIONS//,/ }"
  local -a exts=()
  read -r -a exts <<< "${raw}"
  local -a clean=()
  local e
  for e in ${exts[@]+"${exts[@]}"}; do
    [[ -n "${e}" ]] && clean+=("${e}")
  done
  (( ${#clean[@]} > 0 )) || return 0

  local joined="${clean[*]}"
  pcs_info "checking pi extensions in sandbox: ${joined}"

  # shellcheck disable=SC2016
  local script='
set -uo pipefail
rc=0
installed="$(pi list 2>/dev/null || true)"
for ext in ${PI_SANDBOX_EXTENSIONS}; do
  case "${ext}" in
    *:*|/*|http://*|https://*) source_spec="${ext}" ;;
    *) source_spec="npm:${ext}" ;;
  esac
  if printf "%s\n" "${installed}" | grep -Fq "${ext}"; then
    echo "pi extension present: ${ext}"
  elif pi install "${source_spec}"; then
    echo "pi extension installed: ${source_spec}"
  else
    echo "error: failed to install pi extension: ${source_spec}" >&2
    rc=1
  fi
done
exit "${rc}"
'

  pcs_build_security_flags
  pcs_build_volume_flags
  # No --entrypoint override: the image entrypoint (sandbox-entrypoint.sh,
  # behind tini) seeds the agent home once, then execs the command.
  if ! container run --rm \
    --cpus "${PI_SANDBOX_CPUS}" \
    --memory "${PI_SANDBOX_MEMORY}" \
    "${PCS_SECURITY_FLAGS[@]}" \
    "${PCS_VOLUME_FLAGS[@]}" \
    --env "PI_SANDBOX_EXTENSIONS=${joined}" \
    "${PI_SANDBOX_IMAGE}" \
    /bin/bash -c "${script}"; then
    pcs_err "one or more pi extensions could not be installed; the sandbox still starts, but missing extensions will be absent."
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Image / container helpers.
# ---------------------------------------------------------------------------
pcs_image_exists() {
  local image="$1"
  container image list 2>/dev/null | awk 'NR>1{print $1":"$2}' | grep -qx "${image}"
}

pcs_container_exists() {
  local name="$1"
  container list --all --format json 2>/dev/null | grep -q "\"id\"[[:space:]]*:[[:space:]]*\"${name}\""
}

pcs_container_running() {
  local name="$1"
  container list --format json 2>/dev/null | grep -q "\"id\"[[:space:]]*:[[:space:]]*\"${name}\""
}

# ---------------------------------------------------------------------------
# Shared standard mount/security flags for run/create/exec-style invocations.
# Populates the PCS_RUN_FLAGS array; callers must declare it with
# `local -a PCS_RUN_FLAGS=()` (or similar) before calling, or use it as a
# global array as done in the commands below.
# ---------------------------------------------------------------------------
pcs_build_security_flags() {
  PCS_SECURITY_FLAGS=(
    --platform linux/arm64
    --user 1000:1000
    --cap-drop ALL
    --read-only
    --tmpfs /tmp
    --tmpfs /run
  )
}

pcs_build_volume_flags() {
  # Exactly two read-write host bind mounts, nothing else. Mounts are
  # writable by default (no 'readonly' directive); the --read-only flag only
  # affects the root filesystem. Do NOT add an explicit 'rw' directive:
  # Apple container CLI >= 1.5 rejects it when --read-only is set ("unknown
  # directive rw").
  # PCS_WORKSPACE_SOURCE is set by pcs_ensure_workspace_source(); the caller
  # must run that before calling this.
  PCS_VOLUME_FLAGS=(
    --mount "type=bind,source=${PCS_WORKSPACE_SOURCE},target=/workspace"
    --mount "type=bind,source=${PCS_AGENT_HOME_DIR},target=/home/agent"
  )
}

# Redact secret-looking values (API keys) before printing anything derived
# from the env file.
pcs_redact() {
  local value="$1"
  if [[ -z "${value}" ]]; then
    printf '(unset)'
    return
  fi
  local len=${#value}
  if ((len <= 4)); then
    printf '****'
  else
    printf '%s****%s' "${value:0:2}" "${value: -2}"
  fi
}
