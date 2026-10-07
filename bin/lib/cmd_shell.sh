# shellcheck shell=bash
# Sourced by bin/pcs — do not run directly (shared helpers come from common.sh).

pcs_cmd_shell_usage() {
  cat <<EOF
Usage: pcs shell [--workspace-source <dir>] [-h|--help]

Open an interactive Bash shell in the sandbox (starting in /workspace).

  --workspace-source <dir>  Host folder (your project) bind-mounted at
                            /workspace. Mandatory on first use; afterwards
                            the mapping is persisted in config/sandbox.env,
                            so later calls may omit it. Passing it again
                            updates the mapping.

If '${PI_SANDBOX_NAME:-pi-sandbox}' is already running, this execs a Bash
shell inside it (it keeps that container's existing /workspace mapping).
Otherwise it starts a temporary container (same resource limits,
capabilities, read-only root, and bind mounts as 'pcs start', incl.
the agent home at /home/agent) running Bash, removed on exit.
EOF
}

pcs_cmd_shell() {
  local WORKSPACE_SOURCE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspace-source)
        if [[ $# -lt 2 || -z "${2}" ]]; then
          pcs_err "--workspace-source requires a value (an existing local folder)"
          exit 1
        fi
        WORKSPACE_SOURCE="$2"
        shift 2
        ;;
      -h|--help)
        pcs_cmd_shell_usage
        exit 0
        ;;
      *)
        pcs_err "unknown argument: $1"
        pcs_cmd_shell_usage >&2
        exit 1
        ;;
    esac
  done

  pcs_require_container_cli
  pcs_require_arm64_host
  pcs_ensure_container_system
  pcs_require_env_file
  pcs_load_env

  # Only request a pseudo-TTY when stdin is actually a terminal (e.g. not
  # when this command is driven from CI or a non-interactive pipe).
  local -a TTY_FLAGS=(--interactive)
  if [[ -t 0 ]]; then
    TTY_FLAGS+=(--tty)
  fi

  pcs_ensure_workspace_source "${WORKSPACE_SOURCE}" || exit 1

  if pcs_container_running "${PI_SANDBOX_NAME}"; then
    pcs_info "attaching Bash shell to running container '${PI_SANDBOX_NAME}'..."
    # The sandbox entrypoint re-runs its (no-op) home-seed check and then
    # cds into /workspace before exec'ing bash.
    exec container exec "${TTY_FLAGS[@]}" --user 1000:1000 "${PI_SANDBOX_NAME}" \
      /usr/local/bin/sandbox-entrypoint.sh shell
  fi

  pcs_info "no running sandbox found; starting a temporary container for a shell session..."
  pcs_build_security_flags
  pcs_build_volume_flags

  exec container run \
    --rm "${TTY_FLAGS[@]}" \
    --name "${PI_SANDBOX_NAME}-shell" \
    --cpus "${PI_SANDBOX_CPUS}" \
    --memory "${PI_SANDBOX_MEMORY}" \
    "${PCS_SECURITY_FLAGS[@]}" \
    "${PCS_VOLUME_FLAGS[@]}" \
    --env-file "${PCS_ENV_FILE}" \
    "${PI_SANDBOX_IMAGE}" \
    shell
}
