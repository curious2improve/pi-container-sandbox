# shellcheck shell=bash
# Sourced by bin/pcs — do not run directly (shared helpers come from common.sh).

pcs_cmd_status_usage() {
  cat <<EOF
Usage: pcs status [-h|--help]

Print a status summary: Apple Container service state, image presence,
container state, workspace source mapping, configured resource limits, and
the configured Qwen/oMLX endpoint (credentials redacted).
EOF
}

pcs_cmd_status() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        pcs_cmd_status_usage
        exit 0
        ;;
      *)
        pcs_err "unknown argument: $1"
        pcs_cmd_status_usage >&2
        exit 1
        ;;
    esac
  done

  pcs_require_container_cli
  pcs_load_env

  echo "== Apple Container service =="
  if pcs_container_system_running; then
    echo "status: running"
    container system status 2>/dev/null || true
  else
    echo "status: not running (start with: container system start)"
  fi

  echo
  echo "== Image =="
  echo "tag: ${PI_SANDBOX_IMAGE}"
  if pcs_image_exists "${PI_SANDBOX_IMAGE}"; then
    echo "present: yes"
  else
    echo "present: no (build with: pcs build)"
  fi

  echo
  echo "== Container =="
  echo "name: ${PI_SANDBOX_NAME}"
  if pcs_container_running "${PI_SANDBOX_NAME}"; then
    echo "state: running"
  elif pcs_container_exists "${PI_SANDBOX_NAME}"; then
    echo "state: stopped (exists but not running)"
  else
    echo "state: not present"
  fi

  echo
  echo "== Workspace source (bind mount -> /workspace) =="
  if [[ -n "${PI_SANDBOX_WORKSPACE_SOURCE}" ]]; then
    if [[ -d "${PI_SANDBOX_WORKSPACE_SOURCE}" ]]; then
      echo "source: ${PI_SANDBOX_WORKSPACE_SOURCE} (exists)"
    else
      echo "source: ${PI_SANDBOX_WORKSPACE_SOURCE} (MISSING on host)"
      echo "hint: re-point it with: pcs start --workspace-source <folder>"
    fi
  else
    echo "source: (not configured)"
    echo "hint: pass --workspace-source <folder> to 'pcs start' or 'pcs shell'"
  fi

  echo
  echo "== Resource limits (configured) =="
  echo "CPUs: ${PI_SANDBOX_CPUS}"
  echo "Memory: ${PI_SANDBOX_MEMORY}"

  echo
  echo "== Qwen/oMLX endpoint =="
  if [[ -n "${PI_SANDBOX_QWEN_URL:-}" ]]; then
    echo "endpoint: ${PI_SANDBOX_QWEN_URL}"
  else
    echo "endpoint: (not configured; set OPENAI_BASE_URL in config/sandbox.env)"
  fi
  echo "api key: $(pcs_redact "${OPENAI_API_KEY:-}")"
}
