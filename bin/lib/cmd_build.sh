# shellcheck shell=bash
# Sourced by bin/pcs — do not run directly (shared helpers come from common.sh).

pcs_cmd_build_usage() {
  cat <<EOF
Usage: pcs build [options]

Build the local/pi-dev:trixie image for linux/arm64 using Apple's 'container' CLI.

Options:
  --release           Static check that no version pinning remains in the
                       Containerfile, then a clean rebuild (--no-cache
                       --pull) that re-resolves every dependency to the
                       newest available release.
  --no-cache          Build without using the layer cache.
  --pull              Pull the latest base image before building.
  --node-major N      Override the Node.js major *series* installed from the
                       NodeSource repository (default: 24). APT still
                       resolves the newest release within that series.
  -h, --help          Show this help and exit.

This image is intentionally not version-pinned: every build takes the
newest Debian packages, the newest Pi agent, and the newest npm/PyPI
packages available at build time.

Examples:
  pcs build
  pcs build --no-cache --pull
  pcs build --release
EOF
}

pcs_cmd_build() {
  local NO_CACHE=0
  local PULL=0
  local RELEASE_MODE=0
  local NODE_MAJOR_OVERRIDE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --release)
        RELEASE_MODE=1
        NO_CACHE=1
        shift
        ;;
      --no-cache)
        NO_CACHE=1
        shift
        ;;
      --pull)
        PULL=1
        shift
        ;;
      --node-major)
        NODE_MAJOR_OVERRIDE="${2:?--node-major requires a value}"
        shift 2
        ;;
      -h|--help)
        pcs_cmd_build_usage
        exit 0
        ;;
      *)
        pcs_err "unknown argument: $1"
        pcs_cmd_build_usage >&2
        exit 1
        ;;
    esac
  done

  pcs_require_container_cli
  pcs_require_arm64_host
  pcs_ensure_container_system

  local CONTAINERFILE="${PCS_REPO_ROOT}/config/Containerfile"
  if [[ ! -f "${CONTAINERFILE}" ]]; then
    pcs_die "Containerfile not found at ${CONTAINERFILE}"
  fi

  pcs_load_env

  local -a BUILD_ARGS=()
  if [[ -n "${NODE_MAJOR_OVERRIDE}" ]]; then
    BUILD_ARGS+=(--build-arg "NODE_MAJOR=${NODE_MAJOR_OVERRIDE}")
  fi

  # "Release mode" check: the opposite of the old pinning policy — no
  # version-bearing ARG and no pinned npm/PyPI spec may remain in the
  # Containerfile, so the build always resolves the newest releases. This is a
  # static sanity check on the Containerfile content, not a network call.
  if (( RELEASE_MODE )); then
    pcs_info "release mode: verifying the Containerfile has no version pinning..."
    if grep -E '^ARG [A-Z_]*_VERSION=' "${CONTAINERFILE}" >/dev/null; then
      pcs_die "release mode: version-pinning ARG(s) remain in Containerfile."
    fi
    if grep -E 'pip install .*==|npm install -g .*@[0-9]' "${CONTAINERFILE}" >/dev/null; then
      pcs_die "release mode: pinned npm/PyPI package versions remain in Containerfile."
    fi
    NO_CACHE=1
    PULL=1
  fi

  local -a PULL_FLAG=()
  if (( PULL )); then
    PULL_FLAG=(--pull)
  fi

  local -a CACHE_FLAG=()
  if (( NO_CACHE )); then
    CACHE_FLAG=(--no-cache)
  fi

  pcs_info "building ${PI_SANDBOX_IMAGE} for linux/arm64 from ${CONTAINERFILE} (all dependencies resolve to newest releases)..."
  container build \
    --file "${CONTAINERFILE}" \
    --tag "${PI_SANDBOX_IMAGE}" \
    --platform linux/arm64 \
    "${PULL_FLAG[@]}" \
    "${CACHE_FLAG[@]}" \
    "${BUILD_ARGS[@]}" \
    "${PCS_REPO_ROOT}"

  pcs_info "build complete: ${PI_SANDBOX_IMAGE}"
}
