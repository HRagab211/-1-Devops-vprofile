#!/usr/bin/env bash
#
# vprofile application entrypoint.
#
# Why this exists: appconfig-data.xml declares entityManagerFactory with no lazy-init, so
# Hibernate bootstraps against MySQL during Spring context refresh. If the database is not
# reachable at that moment the context fails and Tomcat serves 404 forever -- there is no
# retry. Compose depends_on/service_healthy covers the normal case, but the application must
# not depend on the orchestrator alone, so we do a bounded TCP wait here as well.
#
# Configuration:
#   WAIT_FOR_TCP      space-separated "host:port" list to wait for. Empty (default) = no wait,
#                     which is what you want in Kubernetes where a startup probe owns this.
#   WAIT_FOR_TIMEOUT  total seconds to wait before giving up (default 90).
#
# On timeout this exits non-zero with a clear message. It never swallows a failure.

set -euo pipefail

WAIT_FOR_TCP="${WAIT_FOR_TCP:-}"
WAIT_FOR_TIMEOUT="${WAIT_FOR_TIMEOUT:-90}"

log() { printf '[entrypoint] %s\n' "$*"; }

# Pure-bash TCP probe via /dev/tcp -- no netcat, curl or other package needed in the runtime image.
tcp_open() {
    local host="$1" port="$2"
    (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null
}

wait_for_endpoints() {
    local deadline endpoint host port remaining
    deadline=$(( SECONDS + WAIT_FOR_TIMEOUT ))

    for endpoint in ${WAIT_FOR_TCP}; do
        host="${endpoint%:*}"
        port="${endpoint##*:}"

        if [ -z "${host}" ] || [ -z "${port}" ] || [ "${host}" = "${port}" ]; then
            log "FATAL: WAIT_FOR_TCP entry '${endpoint}' is not in host:port form."
            exit 78   # EX_CONFIG
        fi

        log "waiting for ${host}:${port} ..."
        until tcp_open "${host}" "${port}"; do
            remaining=$(( deadline - SECONDS ))
            if [ "${remaining}" -le 0 ]; then
                log "FATAL: timed out after ${WAIT_FOR_TIMEOUT}s waiting for ${host}:${port}."
                log "       The application will not start without it. Check that the"
                log "       dependency is running and reachable on the container network."
                exit 69   # EX_UNAVAILABLE
            fi
            sleep 1
        done
        log "${host}:${port} is accepting connections."
    done
}

if [ -n "${WAIT_FOR_TCP}" ]; then
    wait_for_endpoints
else
    log "WAIT_FOR_TCP is empty; starting immediately."
fi

log "starting Tomcat: $*"
# exec so the JVM becomes PID 1 and receives SIGTERM directly, letting Tomcat's shutdown
# hook drain its connectors instead of being killed.
exec "$@"
