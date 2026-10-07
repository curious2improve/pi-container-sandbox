# shellcheck shell=bash
# Sourced by bin/pcs — do not run directly (shared helpers come from common.sh).

pcs_cmd_stop_usage() {
  cat <<EOF
Usage: pcs stop [-h|--help]

Stop the sandbox container cleanly. Your project folder (the
--workspace-source directory behind /workspace) and the home-agent/
directory (agent home) are never touched by this command; all data
survives.
Use 'pcs reset --delete-data' to remove the container entirely.
EOF
}

pcs_cmd_stop() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        pcs_cmd_stop_usage
        exit 0
        ;;
      *)
        pcs_err "unknown argument: $1"
        pcs_cmd_stop_usage >&2
        exit 1
        ;;
    esac
  done

  pcs_require_container_cli
  pcs_load_env

  if ! pcs_container_running "${PI_SANDBOX_NAME}"; then
    pcs_info "'${PI_SANDBOX_NAME}' is not running; nothing to stop."
    return 0
  fi

  pcs_info "stopping '${PI_SANDBOX_NAME}'..."
  container stop "${PI_SANDBOX_NAME}"
  pcs_info "stopped. Your project folder and home-agent/ are untouched."
}
