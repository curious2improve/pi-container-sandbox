# shellcheck shell=bash
# Sourced by bin/pcs — do not run directly (shared helpers come from common.sh).

pcs_cmd_start_usage() {
  cat <<EOF
Usage: pcs start [options] [-- command [args...]]

Start the Pi sandbox container interactively (foreground, removed on exit).

Options:
  --workspace-source <dir>  Host folder (your project) bind-mounted at
                            /workspace. Mandatory on first use; afterwards
                            the mapping is persisted in config/sandbox.env,
                            so later calls may omit it. Passing it again
                            updates the mapping.
  --detach        Run in the background instead of attaching interactively.
  -h, --help      Show this help and exit.

By default this runs 'pi' interactively from inside /workspace (the mounted
project folder). Pass a command after '--' to run something else instead,
e.g.:

  pcs start --workspace-source ~/Projects/myproj   # first run
  pcs start                                        # reuses the saved mapping
  pcs start -- bash
  pcs start -- pytest

Mounts (all read-write, the only host paths ever mounted):
  <--workspace-source dir> -> /workspace           (your project folder, in
                                                   place; .git included, so
                                                   local git works fully)
  home-agent/ -> /home/agent                        (the complete agent home:
                                                   .pi state, package caches,
                                                   dotfiles, tool config;
                                                   everything persists)

The workspace folder is YOUR folder: everything in it, including hidden
directories, is visible at /workspace and edits happen in place on your
machine. It is your responsibility to make sure it contains no credentials
or tokens that pi should not be able to read (e.g. .netrc, git credential
stores, remote-credential .git/config).
/home/agent is the one place you may deliberately hand things to the agent
(e.g. git/SSH credentials) - it is a repo folder, not your real home.
No other host bind mounts (\$HOME, \$HOME/.ssh, \$HOME/.config,
\$HOME/.gitconfig, \$HOME/.pi, /, /Users) are ever used.

The container entrypoint seeds /home/agent from a template baked into the
image, exactly once (cp -an: existing files are never overwritten; tracked
via /home/agent/.sandbox-home-initialized). Delete the marker (or the whole
home-agent/ folder) to force a re-seed.

On every start with the default 'pi' command, the entrypoint also runs
'pi update' and 'pi update --extensions' first, so pi and its extensions
are always the newest versions (best-effort: failures never block the
session).

Before starting, every extension listed in PI_SANDBOX_EXTENSIONS (see
config/sandbox.env) is checked with 'pi list' inside the image and installed
with 'pi install' if missing, so a fresh home-agent/ is self-repairing.

If the configured endpoint (OPENAI_BASE_URL) uses the synthetic hostname
host.container.internal, the system-wide Apple Container DNS entry for it is
checked with 'container system dns list' and created if missing (idempotent;
requires sudo once). The sandbox still starts if the mapping cannot be
created; the endpoint will simply be unreachable from inside.
EOF
}

# Returns 0 if the candidate IP is free: not assigned to a local interface,
# not currently answering on the network, and not covered by a specific
# (non-default) route.
pcs_host_dns_is_safe_ip() {
  local ip="$1"
  local route_info destination

  # Reject an address already assigned to a local interface.
  if ifconfig | grep -Eq "inet[[:space:]]+${ip//./\\.}([[:space:]]|$)"; then
    return 1
  fi

  # Reject an address currently responding on the network.
  if ping -q -c 1 -W 100 "$ip" >/dev/null 2>&1; then
    return 1
  fi

  # Reject an address covered by a specific route.
  # A normal "destination: default" route is acceptable.
  route_info="$(route -n get "$ip" 2>/dev/null || true)"
  destination="$(
    awk '/destination:/ { print $2; exit }' <<<"$route_info"
  )"

  case "$destination" in
    ""|default)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Find a synthetic IP that is safe to map to the host's 127.0.0.1.
# Prefers the RFC 5737 TEST-NET blocks recommended by Apple, then falls
# back to 172.16.0.0/12 candidates avoiding common Docker/Kubernetes and
# corporate subnets.
pcs_host_dns_find_safe_ip() {
  local ip
  local prefix
  local host

  for prefix in 192.0.2 198.51.100 203.0.113; do
    for host in 113 114 115 116 117 118 119 120; do
      ip="${prefix}.${host}"

      if pcs_host_dns_is_safe_ip "$ip"; then
        printf '%s\n' "$ip"
        return 0
      fi
    done
  done

  for prefix in 172.27 172.28 172.29 172.30 172.31; do
    for host in 253 254; do
      ip="${prefix}.255.${host}"

      if pcs_host_dns_is_safe_ip "$ip"; then
        printf '%s\n' "$ip"
        return 0
      fi
    done
  done

  return 1
}

# Idempotently ensure the host.container.internal -> 127.0.0.1 DNS mapping
# exists in the Apple Container system. Keeps an existing mapping untouched
# (avoid changing the endpoint unnecessarily); only creates one when absent,
# which requires sudo.
pcs_ensure_host_dns_mapping() {
  # Keep an existing mapping. This avoids changing the endpoint unnecessarily.
  if container system dns list 2>/dev/null | grep -Fq "${PCS_HOST_DNS_NAME}"; then
    pcs_info "host DNS mapping already present (kept as-is):"
    container system dns list | grep -F "${PCS_HOST_DNS_NAME}" >&2 || true
    return 0
  fi

  local safe_ip
  if ! safe_ip="$(pcs_host_dns_find_safe_ip)"; then
    pcs_err "no suitable localhost-mapping IP found for ${PCS_HOST_DNS_NAME}."
    pcs_err "Check active VPNs, routes and local interfaces."
    return 1
  fi

  pcs_info "Creating ${PCS_HOST_DNS_NAME} using synthetic IP ${safe_ip} using sudo"
  # print the actual command we want to run to inform the user
  pcs_info "sudo container system dns create ${PCS_HOST_DNS_NAME} --localhost ${safe_ip}"

  if ! sudo container system dns create \
    "${PCS_HOST_DNS_NAME}" \
    --localhost "${safe_ip}"; then
    pcs_err "failed to create the ${PCS_HOST_DNS_NAME} DNS mapping."
    return 1
  fi

  echo "Created mapping:"
  container system dns list | grep -F "${PCS_HOST_DNS_NAME}" || true

  echo
  echo "Container API URL:"
  echo "http://${PCS_HOST_DNS_NAME}:8000/v1"
  return 0
}

pcs_cmd_start() {
  local DETACH=0
  local WORKSPACE_SOURCE=""
  local -a COMMAND_ARGS=()

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
      --detach)
        DETACH=1
        shift
        ;;
      -h|--help)
        pcs_cmd_start_usage
        exit 0
        ;;
      --)
        shift
        COMMAND_ARGS=("$@")
        break
        ;;
      *)
        pcs_err "unknown argument: $1"
        pcs_cmd_start_usage >&2
        exit 1
        ;;
    esac
  done

  pcs_require_container_cli
  pcs_require_arm64_host
  pcs_ensure_container_system
  pcs_require_env_file
  pcs_load_env

  if [[ -z "${OPENAI_BASE_URL:-}" ]]; then
    pcs_warn "OPENAI_BASE_URL is not set in ${PCS_ENV_FILE}; Pi will not be able to reach the Qwen/oMLX endpoint."
  elif [[ "${OPENAI_BASE_URL}" == *"${PCS_HOST_DNS_NAME}"* ]]; then
    # The endpoint uses the synthetic host-container hostname, which only
    # resolves if the system DNS entry exists. Self-repair it (idempotent;
    # sudo only on first creation). Never fatal: if the mapping cannot be
    # created the sandbox still starts, the endpoint just stays unreachable.
    pcs_ensure_host_dns_mapping \
      || pcs_warn "could not ensure the ${PCS_HOST_DNS_NAME} DNS mapping; the endpoint will not resolve inside the sandbox."
  fi

  pcs_ensure_workspace_source "${WORKSPACE_SOURCE}" || exit 1
  pcs_ensure_agent_home
  pcs_ensure_pi_extensions || true

  # Refuse to proceed if a stray host bind-mount flag leaked in via CONTAINER_
  # env-style overrides. This command only ever constructs the two documented
  # bind mounts (--mount type=bind); this check guards against accidental
  # copy/paste of Docker-style '-v' invocations elsewhere in the environment.
  if [[ "${CONTAINER_EXTRA_ARGS:-}" == *"--volume"* || "${CONTAINER_EXTRA_ARGS:-}" == *"-v "* ]]; then
    pcs_die "refusing to start: CONTAINER_EXTRA_ARGS appears to request an extra host bind mount, which this sandbox does not permit."
  fi

  pcs_build_security_flags
  pcs_build_volume_flags

  local -a RUN_MODE_FLAGS=(--rm)
  if (( DETACH )); then
    RUN_MODE_FLAGS+=(--detach)
  else
    RUN_MODE_FLAGS+=(--interactive)
    # Only request a pseudo-TTY when stdin is actually a terminal (e.g. not
    # when this command is driven from CI or a non-interactive pipe).
    if [[ -t 0 ]]; then
      RUN_MODE_FLAGS+=(--tty)
    fi
  fi

  # With no command arguments the image's default CMD ("pi") runs. The image
  # entrypoint (sandbox-entrypoint.sh, behind tini as PID 1) seeds the agent
  # home once, runs 'pi update' and 'pi update --extensions' (best-effort),
  # and then cds into /workspace before exec'ing 'pi', so pi starts in the
  # mounted project folder.

  pcs_info "starting ${PI_SANDBOX_NAME} (cpus=${PI_SANDBOX_CPUS} memory=${PI_SANDBOX_MEMORY}) workspace=${PCS_WORKSPACE_SOURCE}"

  exec container run \
    "${RUN_MODE_FLAGS[@]}" \
    --name "${PI_SANDBOX_NAME}" \
    --cpus "${PI_SANDBOX_CPUS}" \
    --memory "${PI_SANDBOX_MEMORY}" \
    "${PCS_SECURITY_FLAGS[@]}" \
    "${PCS_VOLUME_FLAGS[@]}" \
    --env-file "${PCS_ENV_FILE}" \
    "${PI_SANDBOX_IMAGE}" \
    "${COMMAND_ARGS[@]+"${COMMAND_ARGS[@]}"}"
}
