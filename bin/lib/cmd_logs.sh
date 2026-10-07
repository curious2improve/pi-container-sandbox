# shellcheck shell=bash
# Sourced by bin/pcs — do not run directly (shared helpers come from common.sh).

pcs_cmd_logs_usage() {
  cat <<EOF
Usage: pcs logs [--follow] [-n LINES] [-h|--help]

Print (or follow) logs from the running '${PI_SANDBOX_NAME:-pi-sandbox}' container.

Options:
  --follow, -f    Follow log output (like 'tail -f').
  -n LINES        Only show the last LINES lines.
  -h, --help      Show this help and exit.
EOF
}

pcs_cmd_logs() {
  local FOLLOW=0
  local LINES=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --follow|-f)
        FOLLOW=1
        shift
        ;;
      -n)
        LINES="${2:?-n requires a value}"
        shift 2
        ;;
      -h|--help)
        pcs_cmd_logs_usage
        exit 0
        ;;
      *)
        pcs_err "unknown argument: $1"
        pcs_cmd_logs_usage >&2
        exit 1
        ;;
    esac
  done

  pcs_require_container_cli
  pcs_load_env

  if ! pcs_container_exists "${PI_SANDBOX_NAME}"; then
    pcs_die "container '${PI_SANDBOX_NAME}' does not exist. Start it with: pcs start"
  fi

  local -a ARGS=()
  if (( FOLLOW )); then
    ARGS+=(--follow)
  fi
  if [[ -n "${LINES}" ]]; then
    ARGS+=(-n "${LINES}")
  fi

  exec container logs "${ARGS[@]}" "${PI_SANDBOX_NAME}"
}
