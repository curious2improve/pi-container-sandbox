# shellcheck shell=bash
# Sourced by bin/pcs — do not run directly (shared helpers come from common.sh).

pcs_cmd_reset_usage() {
  cat <<EOF
Usage: pcs reset --delete-data [--delete-image] [-h|--help]

Destructive reset: removes the sandbox container.

This command NEVER touches your files:
  - Your project folder (the --workspace-source directory mounted at
    /workspace) is a plain host folder; nothing inside it is deleted.
  - The host-side home-agent/ directory (mounted as the complete agent
    home at /home/agent) is also untouched; delete its contents yourself
    if you want a clean Pi state (delete the
    .sandbox-home-initialized marker too to force a template re-seed).

Options:
  --delete-data     Required. Confirms you intend to delete sandbox data.
  --delete-image    Also remove the local/pi-dev:trixie image.
  -h, --help        Show this help and exit.

Reset vs stop:
  'pcs stop' stops the container only.
  'pcs reset --delete-data' (this command) deletes the container.
  Your project folder and home-agent/.pi/ survive in both cases.
EOF
}

pcs_cmd_reset() {
  local DELETE_DATA=0
  local DELETE_IMAGE=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delete-data)
        DELETE_DATA=1
        shift
        ;;
      --delete-image)
        DELETE_IMAGE=1
        shift
        ;;
      -h|--help)
        pcs_cmd_reset_usage
        exit 0
        ;;
      *)
        pcs_err "unknown argument: $1"
        pcs_cmd_reset_usage >&2
        exit 1
        ;;
    esac
  done

  if (( DELETE_DATA == 0 )); then
    pcs_err "refusing to reset without the explicit --delete-data flag."
    pcs_cmd_reset_usage >&2
    exit 1
  fi

  pcs_require_container_cli
  pcs_load_env

  if pcs_container_exists "${PI_SANDBOX_NAME}"; then
    pcs_info "removing container '${PI_SANDBOX_NAME}'..."
    container delete --force "${PI_SANDBOX_NAME}" >/dev/null 2>&1 || true
  fi

  if (( DELETE_IMAGE )); then
    pcs_info "deleting image '${PI_SANDBOX_IMAGE}'..."
    container image delete "${PI_SANDBOX_IMAGE}" >/dev/null 2>&1 || pcs_warn "could not delete image '${PI_SANDBOX_IMAGE}' (it may not exist)."
  fi

  pcs_info "reset complete."
}
