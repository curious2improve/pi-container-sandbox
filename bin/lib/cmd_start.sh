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

OPENAI_BASE_URL is optional: models may be defined entirely in
home-agent/.pi/agent/models.json. On every start, OPENAI_BASE_URL and the
baseUrl entries of models.json are checked independently. If any of them
points at the host loopback (localhost / 127.0.0.1 / ::1) or already at the
synthetic hostname host.container.internal, the Apple Container DNS entry
for host.container.internal is checked: it is created or replaced only
with positive evidence that it is broken — it is missing, its IP is no
longer safe on the current network, or the probe proves the packet-filter
redirect to 127.0.0.1 is gone (that rule is dropped on reboot and can go
stale after a network change). If the redirect cannot be verified either
way, the mapping is left untouched. sudo is used only for that create or
replace. The container's entrypoint additionally rewrites such
loopback URLs to host.container.internal (the environment variable for the
session, the models.json lines in place). URLs pointing at any other host,
domain, or IP (external APIs, the VM gateway) are left untouched. The
sandbox still starts if the mapping cannot be repaired; the endpoint will
simply be unreachable from inside.
EOF
}

# Returns 0 when the IP is not assigned to a local interface and is not
# covered by a specific route out a real interface. A host route via lo0 is
# acceptable: that is the loopback path, not a network that appeared after
# changing Wi-Fi or VPN.
pcs_host_dns_route_ok() {
  local ip="$1"
  local route_info destination iface

  if ifconfig 2>/dev/null | grep -Eq "inet[[:space:]]+${ip//./\\.}([[:space:]]|$)"; then
    return 1
  fi

  route_info="$(route -n get "$ip" 2>/dev/null || true)"
  destination="$(awk '/destination:/ { print $2; exit }' <<<"${route_info}")"
  iface="$(awk '/interface:/ { print $2; exit }' <<<"${route_info}")"

  if [[ "${iface}" == "lo0" ]]; then
    return 0
  fi

  case "${destination}" in
    ""|default)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Print the source address of one ping reply, or nothing if nobody answers.
# macOS ping -W is a per-reply timeout in milliseconds.
pcs_host_dns_ping_source() {
  local ip="$1"
  local src=""

  src="$(
    ping -n -c 1 -W 400 "${ip}" 2>/dev/null | awk '
      /bytes from / {
        line = $0
        sub(/.*bytes from /, "", line)
        sub(/:.*/, "", line)
        gsub(/[[:space:]]/, "", line)
        print line
        exit
      }
    ' || true
  )"
  printf '%s\n' "${src}"
}

# Returns 0 if the candidate IP is free to use as a new --localhost target:
# route_ok, and not answering ping. A live localhost redirect answers from
# 127.0.0.1, so this rejects that address too — callers must not use this to
# judge an existing mapping, or every start would rotate the IP.
pcs_host_dns_is_safe_ip() {
  local ip="$1"
  local src

  if ! pcs_host_dns_route_ok "${ip}"; then
    return 1
  fi
  src="$(pcs_host_dns_ping_source "${ip}")"
  if [[ -n "${src}" ]]; then
    return 1
  fi
  return 0
}

# Print the state of the pf redirect for one mapping IP: active, dead, or
# unknown.
# Apple's --localhost option installs `rdr inet from any to <ip> -> 127.0.0.1`.
# The DNS name survives a network change; the loaded pf rule often does not.
# "dead" is only reported on positive evidence: a local listener that was
# definitely up, reached twice in a row via the IP, never, or a ping reply
# from something other than 127.0.0.1 (the address is now in use). Probe
# failures (no nc, no bindable port, unanswered ping) print "unknown", so a
# healthy mapping is never deleted because of a flaky check.
pcs_host_dns_redirect_state() {
  local ip="$1"
  local port pid ready src dead_hits=0
  local _attempt _spin

  if command -v nc >/dev/null 2>&1; then
    for _attempt in 1 2 3 4 5; do
    port=$((40000 + (RANDOM % 20000)))
    # -k keeps the listener up so the readiness connect does not consume it.
    # macOS nc: `nc -l host port` (do not combine -l with -p, -s, or -z).
    nc -k -l 127.0.0.1 "${port}" >/dev/null 2>&1 &
    pid=$!
    ready=false
    for _spin in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      if ! kill -0 "${pid}" 2>/dev/null; then
        wait "${pid}" 2>/dev/null || true
        pid=""
        break
      fi
      if nc -z -G 1 127.0.0.1 "${port}" >/dev/null 2>&1; then
        ready=true
        break
      fi
      sleep 0.02
    done

    if [[ "${ready}" != true ]]; then
      if [[ -n "${pid}" ]]; then
        kill "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
      fi
      continue
    fi

    if nc -z -G 1 "${ip}" "${port}" >/dev/null 2>&1; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      printf 'active\n'
      return 0
    fi

    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    # The listener was definitely up and the IP never reached it. One miss
    # can be transient; two consistent misses prove the rdr rule is gone.
    dead_hits=$((dead_hits + 1))
    if (( dead_hits >= 2 )); then
      printf 'dead\n'
      return 0
    fi
  done
  fi

  # ICMP tie-break: a live redirect answers from 127.0.0.1 and a reply from
  # any other address proves the IP is in use. Silence is not evidence —
  # unrouted TEST-NET traffic often simply gets no answer at all.
  src="$(pcs_host_dns_ping_source "${ip}")"
  case "${src}" in
    127.0.0.1) printf 'active\n' ;;
    "") printf 'unknown\n' ;;
    *) printf 'dead\n' ;;
  esac
  return 0
}

# Decide what to do with the current mapping. Arguments are plain facts so
# the policy can be tested without Apple Container:
#   $1 exists      true|false   domain is in `container system dns list`
#   $2 ip          current --localhost address, or empty if it could not be read
#   $3 route_ok    true|false   ip is still safe on this network
#   $4 redirect    active|dead|unknown   pf redirect state (see above)
# Prints one of: keep, create, repair-same, repair-new.
# "unknown" never repairs: without positive evidence the mapping stays
# untouched, so a flaky probe can never delete a working one.
pcs_host_dns_decide() {
  local exists="${1:-false}"
  local ip="${2:-}"
  local route_ok="${3:-false}"
  local redirect="${4:-unknown}"

  if [[ "${exists}" != true ]]; then
    printf 'create\n'
    return 0
  fi
  if [[ -n "${ip}" && "${route_ok}" == true && "${redirect}" != dead ]]; then
    printf 'keep\n'
    return 0
  fi
  # Same address, dead redirect: recreate it so pf is reloaded. Do not pick a
  # new address just because the rule is gone.
  if [[ -n "${ip}" && "${route_ok}" == true ]]; then
    printf 'repair-same\n'
    return 0
  fi
  printf 'repair-new\n'
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

# Returns 0 when Apple Container has a DNS domain for the host alias.
pcs_host_dns_domain_exists() {
  container system dns list 2>/dev/null |
    awk 'NR > 1 { print $1 }' |
    grep -Fxq "${PCS_HOST_DNS_NAME}"
}

# Print the localhost IP from an Apple Container resolver file on stdin.
pcs_host_dns_ip_from_resolver_text() {
  awk '
    {
      line = $0
      if (!sub(/.*localhost:/, "", line)) next
      sub(/[^0-9.].*/, "", line)
      if (line ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
        print line
        exit
      }
    }
  '
}

# Print the localhost IP for one domain from a `scutil --dns` dump on stdin.
# scutil lists `flags` before `options` inside a resolver block. Stopping at
# `flags` always misses `options localhost:<ip>`, so the caller thinks the
# mapping has no address, skips delete, and `dns create` fails because the
# name already exists.
pcs_host_dns_ip_from_scutil_text() {
  local domain="${1:-${PCS_HOST_DNS_NAME}}"
  awk -v domain="${domain}" '
    $1 == "domain" && $3 == domain { found = 1; next }
    found && $1 == "domain" { exit }
    found && /localhost:/ {
      line = $0
      sub(/.*localhost:/, "", line)
      sub(/[^0-9.].*/, "", line)
      if (line ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print line
      exit
    }
  '
}

# Print the --localhost IP configured for the host alias.
# Returns 1 when it cannot be read. The domain may still exist.
# Prefers /etc/resolver/containerization.<name> (`options localhost:<ip>`).
pcs_host_dns_configured_ip() {
  local file ip=""

  file="/etc/resolver/containerization.${PCS_HOST_DNS_NAME}"
  if [[ -r "${file}" ]]; then
    ip="$(pcs_host_dns_ip_from_resolver_text < "${file}")"
  fi

  if [[ -z "${ip}" ]]; then
    ip="$(scutil --dns 2>/dev/null | pcs_host_dns_ip_from_scutil_text "${PCS_HOST_DNS_NAME}" || true)"
  fi

  if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "${ip}"
    return 0
  fi
  return 1
}

# Ensure host.container.internal is a working localhost redirect.
# sudo runs only when the mapping must be created or replaced.
pcs_ensure_host_dns_mapping() {
  local exists=false
  local ip="" route_ok=false redirect=unknown
  local decision target=""

  if pcs_host_dns_domain_exists; then
    exists=true
    ip="$(pcs_host_dns_configured_ip || true)"
  fi

  if [[ "${exists}" == true && -n "${ip}" ]] && pcs_host_dns_route_ok "${ip}"; then
    route_ok=true
    redirect="$(pcs_host_dns_redirect_state "${ip}")"
  fi

  decision="$(pcs_host_dns_decide "${exists}" "${ip}" "${route_ok}" "${redirect}")"

  case "${decision}" in
    keep)
      if [[ "${redirect}" == unknown ]]; then
        pcs_info "host DNS mapping left as is: ${PCS_HOST_DNS_NAME} -> ${ip}"
        pcs_info "  (localhost redirect could not be verified; nothing was changed)"
      else
        pcs_info "host DNS mapping already correct:"
        pcs_info "  ${PCS_HOST_DNS_NAME} -> ${ip} (localhost redirect active)"
      fi
      return 0
      ;;
    create|repair-same|repair-new)
      ;;
    *)
      pcs_err "internal error: unexpected host DNS plan '${decision}'"
      return 1
      ;;
  esac

  if [[ "${decision}" == "repair-same" ]]; then
    target="${ip}"
  elif ! target="$(pcs_host_dns_find_safe_ip)"; then
    pcs_err "no suitable localhost-mapping IP found for ${PCS_HOST_DNS_NAME}."
    pcs_err "Check active VPNs, routes and local interfaces."
    return 1
  fi

  case "${decision}" in
    create)
      pcs_info "host DNS mapping is missing; creating ${PCS_HOST_DNS_NAME} -> ${target}"
      ;;
    repair-same)
      pcs_info "host DNS mapping does not redirect to 127.0.0.1 (verified):"
      pcs_info "  ${PCS_HOST_DNS_NAME} -> ${ip}"
      pcs_info "Recreating the same mapping so the packet-filter rule is reloaded."
      ;;
    repair-new)
      if [[ -n "${ip}" ]]; then
        pcs_info "host DNS mapping is not valid on this network:"
        pcs_info "  current:  ${PCS_HOST_DNS_NAME} -> ${ip}"
        pcs_info "  required: ${PCS_HOST_DNS_NAME} -> ${target}"
      else
        pcs_info "host DNS mapping exists, but its localhost IP could not be read."
        pcs_info "Replacing it with ${PCS_HOST_DNS_NAME} -> ${target}."
      fi
      ;;
  esac

  if [[ "${decision}" != "create" ]]; then
    # Drift guard: never delete a mapping whose current content we cannot
    # re-read as exactly what we inspected. (The CLI has no in-place update.
    #) If the state changed since the probe, abort instead of destroying it.
    if ! pcs_host_dns_domain_exists ||
       [[ "$(pcs_host_dns_configured_ip || true)" != "${ip}" ]]; then
      pcs_err "the ${PCS_HOST_DNS_NAME} mapping changed while deciding; not deleting it."
      return 1
    fi
    pcs_info "sudo container system dns delete ${PCS_HOST_DNS_NAME}"
    if ! sudo container system dns delete "${PCS_HOST_DNS_NAME}"; then
      pcs_err "failed to delete the existing ${PCS_HOST_DNS_NAME} DNS mapping."
      return 1
    fi
  fi

  pcs_info "sudo container system dns create ${PCS_HOST_DNS_NAME} --localhost ${target}"
  if ! sudo container system dns create "${PCS_HOST_DNS_NAME}" --localhost "${target}"; then
    pcs_err "failed to create the ${PCS_HOST_DNS_NAME} DNS mapping."
    return 1
  fi

  pcs_info "host DNS mapping updated: ${PCS_HOST_DNS_NAME} -> ${target}"
  return 0
}

# Print the health of the configured alias: ok, dead, unknown, or missing.
# "unknown" means the redirect could not be probed; it is not evidence of a
# broken mapping.
pcs_host_dns_mapping_state() {
  local ip="" state

  if ! pcs_host_dns_domain_exists; then
    printf 'missing\n'
    return 0
  fi
  ip="$(pcs_host_dns_configured_ip || true)"
  if [[ -z "${ip}" ]]; then
    printf 'dead\n'
    return 0
  fi
  if ! pcs_host_dns_route_ok "${ip}"; then
    printf 'dead\n'
    return 0
  fi
  state="$(pcs_host_dns_redirect_state "${ip}")"
  if [[ "${state}" == active ]]; then
    printf 'ok\n'
  else
    printf '%s\n' "${state}"
  fi
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

  # OPENAI_BASE_URL is optional: models may come entirely from
  # home-agent/.pi/agent/models.json. Check it and the models.json baseUrls
  # independently: if any of them points at the host loopback or already at
  # the synthetic host-container hostname, the DNS mapping must work. The
  # container entrypoint rewrites loopback URLs to ${PCS_HOST_DNS_NAME}
  # itself. External / other-host URLs are never touched.
  if [[ -z "${OPENAI_BASE_URL:-}" ]]; then
    pcs_info "OPENAI_BASE_URL is not set (optional); models come from home-agent/.pi/agent/models.json."
  fi
  if pcs_config_needs_host_dns; then
    # Repair the mapping only when it is missing or no longer a working
    # localhost redirect. sudo is required only for that create or replace.
    # Never fatal: the sandbox still starts, the endpoint just stays
    # unreachable.
    pcs_info "local LLM endpoint detected; ensuring the ${PCS_HOST_DNS_NAME} -> 127.0.0.1 host DNS mapping..."
    pcs_ensure_host_dns_mapping \
      || pcs_warn "could not ensure the ${PCS_HOST_DNS_NAME} DNS mapping; the local endpoint will not resolve inside the sandbox."
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
