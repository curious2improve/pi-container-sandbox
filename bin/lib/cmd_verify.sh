# shellcheck shell=bash
# Sourced by bin/pcs — do not run directly (shared helpers come from common.sh).

pcs_cmd_verify_usage() {
  cat <<EOF
Usage: pcs verify [-h|--help]

Run a battery of checks inside a throwaway sandbox container to verify
isolation, tooling, the workspace mount, and Qwen/oMLX connectivity.
Does not print secrets.

Checks performed:
  - architecture is aarch64/arm64
  - effective user is UID 1000 (not root)
  - /workspace (your --workspace-source folder) and /home/agent (the agent
    home bind mount) are writable
  - workspace lifecycle: create/read/execute/delete of a hidden test project
    inside /workspace (removed again, so your project is left as it was)
  - the sandbox entrypoint seeded the agent home from the image template
    (.sandbox-home-initialized marker)
  - an unrelated root filesystem path is NOT writable (read-only root)
  - the /workspace source folder exists on the host
  - Linux capabilities are empty/reduced
  - Python, pip, Node.js, npm, Pi, Git, curl, jq, ripgrep, FFmpeg,
    ShellCheck, Ruff, pytest, ESLint, Prettier, TypeScript, diffutils,
    patch, man-db, lsof, htop, yq, uv, gh, strace, tmux, fzf are installed
  - (tool *presence* is checked; versions are intentionally unpinned)
  - public HTTPS reachability
  - configured Qwen /v1/models endpoint reachability
  - host DNS mapping host.container.internal is present (only when the
    configured endpoint uses it; ensured automatically by 'pcs start')

This requires a /workspace source: use --workspace-source, or a mapping
already persisted in config/sandbox.env (see 'pcs start --help').
EOF
}

pcs_cmd_verify() {
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
        pcs_cmd_verify_usage
        exit 0
        ;;
      *)
        pcs_err "unknown argument: $1"
        pcs_cmd_verify_usage >&2
        exit 1
        ;;
    esac
  done

  pcs_require_container_cli
  pcs_require_arm64_host
  pcs_ensure_container_system
  pcs_require_env_file
  pcs_load_env
  pcs_ensure_workspace_source "${WORKSPACE_SOURCE}" || exit 1
  pcs_ensure_agent_home

  pcs_info "configured Qwen/oMLX endpoint: ${PI_SANDBOX_QWEN_URL:-(not configured)}"
  pcs_info "(credentials are never printed by this command)"

  pcs_build_security_flags
  pcs_build_volume_flags

  # The in-container verification script. Runs as a single bash -c payload so
  # the whole battery of checks executes inside one throwaway container.
  # shellcheck disable=SC2016
  local VERIFY_SCRIPT='
set -uo pipefail
pass=0
fail=0

check() {
  local desc="$1"
  local result="$2"
  if [[ "${result}" == "ok" ]]; then
    printf "[PASS] %s\n" "${desc}"
    pass=$((pass + 1))
  else
    printf "[FAIL] %s: %s\n" "${desc}" "${result}"
    fail=$((fail + 1))
  fi
}

# architecture
arch="$(uname -m)"
if [[ "${arch}" == "aarch64" || "${arch}" == "arm64" ]]; then
  check "architecture is aarch64/arm64 (${arch})" ok
else
  check "architecture is aarch64/arm64" "got ${arch}"
fi

# user
uid="$(id -u)"
if [[ "${uid}" == "1000" ]]; then
  check "effective UID is 1000" ok
else
  check "effective UID is 1000" "got ${uid}"
fi
if [[ "${uid}" == "0" ]]; then
  check "process is not running as root" "running as root"
else
  check "process is not running as root" ok
fi

# writable paths
if touch /workspace/.pcs-verify-write-test 2>/dev/null; then
  rm -f /workspace/.pcs-verify-write-test
  check "/workspace is writable" ok
else
  check "/workspace is writable" "touch failed"
fi

if touch /home/agent/.pcs-verify-write-test 2>/dev/null; then
  rm -f /home/agent/.pcs-verify-write-test
  check "/home/agent (agent home) is writable" ok
else
  check "/home/agent (agent home) is writable" "touch failed"
fi

# workspace lifecycle: create/read/execute/delete of a hidden test project
# (merged from the former pcs smoke-test). The folder is removed again,
# leaving the mounted project exactly as it was.
proj="/workspace/.pcs-verify-project"
rm -rf "${proj}" 2>/dev/null
lifecycle_result="ok"
if mkdir -p "${proj}" 2>/dev/null; then
  cat > "${proj}/hello.py" <<'\''PYEOF'\''
def greet(name):
    return "hello, " + name

if __name__ == "__main__":
    print(greet("sandbox"))
PYEOF
  cat > "${proj}/run.sh" <<'\''SHEOF'\''
#!/usr/bin/env bash
set -euo pipefail
python3 "$(dirname "$0")/hello.py"
SHEOF
  chmod +x "${proj}/run.sh" 2>/dev/null || true
  if [[ "$(head -1 "${proj}/hello.py" 2>/dev/null)" == "def greet(name):" ]]; then
    output="$("${proj}/run.sh" 2>/dev/null)" || output="(execution failed)"
    if [[ "${output}" != "hello, sandbox" ]]; then
      lifecycle_result="unexpected output: ${output}"
    fi
  else
    lifecycle_result="read-back mismatch"
  fi
else
  lifecycle_result="mkdir failed"
fi
rm -rf "${proj}" 2>/dev/null || true
if [[ -e "${proj}" ]]; then
  lifecycle_result="test project was not deleted"
fi
check "workspace lifecycle (create/read/execute/delete)" "${lifecycle_result}"

# the entrypoint must have seeded the mounted home from the image template
if [[ -f /home/agent/.sandbox-home-initialized ]]; then
  check "sandbox entrypoint seeded the agent home" ok
else
  check "sandbox entrypoint seeded the agent home" "marker missing"
fi

# read-only root
if touch /etc/.pcs-verify-write-test 2>/dev/null; then
  rm -f /etc/.pcs-verify-write-test
  check "unrelated root path (/etc) is NOT writable" "unexpectedly writable"
else
  check "unrelated root path (/etc) is NOT writable" ok
fi

# capabilities (requires libcap; fall back to /proc/self/status CapEff)
cap_line="$(grep CapEff /proc/self/status 2>/dev/null | awk "{print \$2}")"
if [[ "${cap_line}" == "0000000000000000" || -z "${cap_line}" ]]; then
  check "Linux capabilities are empty (CapEff=${cap_line:-unknown})" ok
else
  check "Linux capabilities are empty" "CapEff=${cap_line}"
fi

# tool presence (no version assertions: versions are intentionally unpinned)
presence_check() {
  local desc="$1"
  local path
  if path="$(command -v "$2" 2>/dev/null)" || [[ -n "${path:-}" ]]; then
    check "${desc} is installed (${path})" ok
  else
    check "${desc} is installed" "command '"'"'$2'"'"' not found on PATH"
  fi
}

presence_check "Python" python3
presence_check "pip" pip
presence_check "Node.js" node
presence_check "npm" npm
presence_check "Pi" pi
presence_check "Git" git
presence_check "curl" curl
presence_check "jq" jq
presence_check "ripgrep" rg
presence_check "FFmpeg" ffmpeg
presence_check "ShellCheck" shellcheck
presence_check "Ruff" ruff
presence_check "pytest" pytest
presence_check "ESLint" eslint
presence_check "Prettier" prettier
presence_check "TypeScript" tsc
presence_check "diffutils" diff
presence_check "patch" patch
presence_check "man-db" man
presence_check "lsof" lsof
presence_check "htop" htop
presence_check "yq" yq
presence_check "uv" uv
presence_check "gh" gh
presence_check "strace" strace
presence_check "tmux" tmux
presence_check "fzf" fzf

# public HTTPS
if curl --silent --show-error --max-time 5 --output /dev/null https://1.1.1.1; then
  check "public HTTPS reachability (https://1.1.1.1)" ok
else
  check "public HTTPS reachability (https://1.1.1.1)" "curl failed"
fi

# Qwen/oMLX endpoint
if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
  models_url="${OPENAI_BASE_URL%/}/models"
  if curl --silent --show-error --max-time 5 --output /dev/null \
      --header "Authorization: Bearer ${OPENAI_API_KEY:-}" "${models_url}"; then
    check "Qwen/oMLX endpoint reachable (${models_url})" ok
  else
    hint=""
    if [[ "${models_url}" == *host.container.internal* ]]; then
      hint=" — if DNS resolution failed, run: pcs start"
    fi
    check "Qwen/oMLX endpoint reachable (${models_url})" "curl failed: endpoint unreachable or not serving /v1/models${hint}"
  fi
else
  check "Qwen/oMLX endpoint configured" "OPENAI_BASE_URL is not set"
fi

echo
echo "== summary: ${pass} passed, ${fail} failed =="
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
'

  pcs_info "running verification battery in a throwaway container... (the workspace lifecycle check creates and removes a hidden .pcs-verify-project inside your --workspace-source folder)"
  set +e
  container run --rm \
    --cpus "${PI_SANDBOX_CPUS}" \
    --memory "${PI_SANDBOX_MEMORY}" \
    "${PCS_SECURITY_FLAGS[@]}" \
    "${PCS_VOLUME_FLAGS[@]}" \
    --env-file "${PCS_ENV_FILE}" \
    "${PI_SANDBOX_IMAGE}" \
    /bin/bash -c "${VERIFY_SCRIPT}"
  local STATUS=$?
  set -e

  # Host-side checks (outside the container, against Apple Container's own
  # service state and the mount sources).
  echo
  local HOST_FAIL=0

  # When the endpoint uses the synthetic host-container hostname, the
  # system-wide Apple Container DNS entry must exist (it is ensured by
  # 'pcs start', which requires sudo on first creation).
  if [[ "${OPENAI_BASE_URL:-}" == *host.container.internal* ]]; then
    if container system dns list 2>/dev/null | grep -Fq "host.container.internal"; then
      echo "[PASS] host DNS mapping present (host.container.internal)"
    else
      echo "[FAIL] host DNS mapping missing (host.container.internal) — run: pcs start"
      HOST_FAIL=1
    fi
  fi

  echo
  echo "== workspace source (host-side check) =="
  if [[ -d "${PCS_WORKSPACE_SOURCE}" ]]; then
    echo "[PASS] workspace source folder exists: ${PCS_WORKSPACE_SOURCE}"
  else
    echo "[FAIL] workspace source folder missing: ${PCS_WORKSPACE_SOURCE}"
    HOST_FAIL=1
  fi

  if [[ "${STATUS}" -ne 0 || "${HOST_FAIL}" -ne 0 ]]; then
    pcs_err "verification failed."
    exit 1
  fi

  pcs_info "verification passed."
}
