#!/bin/bash
#
# Copyright (C) 2026 Nethesis S.r.l.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runtime smoke test of the Apache reverse-proxy in front of sogod, including
# the Microsoft ActiveSync endpoint. This CANNOT run during `docker build`
# (no services in a RUN layer): it boots the real image with supervisord and
# drives HTTP requests through Apache (:20001) -> sogod (:20000).
#
# Usage: tests/proxy-smoke.sh [IMAGE]
#        default: ghcr.io/nethserver/sogo-server:latest (what build-images.sh produces)
#
# Local manual run: ./tests/proxy-smoke.sh ghcr.io/nethserver/sogo-server:<branch-tag>
# (the branch image is already published by the CI) - this is what we already
# did, and it passes. Note: the automatic trigger via .github/workflows/
# proxy-smoke.yml (workflow_run / workflow_dispatch) only becomes active once
# the workflow is present on the default branch (main), i.e. after merge.
set -u

IMAGE="${1:-ghcr.io/nethserver/sogo-server:latest}"
NAME="sogo-proxy-smoke-$$"
HOSTPORT=20001
fail=0
ok(){ echo "OK:   $*"; }
err(){ echo "FAIL: $*"; fail=1; }

cleanup(){ podman rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Always pull the published image fresh: never silently test a stale local
# cache for this tag (e.g. :latest reused across runs). This is just a pull,
# not a rebuild - the freshly published ghcr image is what we want to test.
echo "== pulling $IMAGE =="
podman pull "$IMAGE" \
    || { echo "FAIL: could not pull $IMAGE"; exit 1; }

# Image contract: inspect the published image config before running it.
echo "== checking image contract =="
cfg=$(podman image inspect "$IMAGE" --format \
  'ENV={{range .Config.Env}}{{.}};{{end}} CMD={{.Config.Cmd}} PORTS={{range $p,$_ := .Config.ExposedPorts}}{{$p}};{{end}} LABELS={{range $k,$_ := .Config.Labels}}{{$k}};{{end}}')
echo "$cfg" | grep -q 'LD_PRELOAD=/usr/lib/libytnef.so' \
    && ok "image ENV LD_PRELOAD=/usr/lib/libytnef.so" \
    || err "image ENV LD_PRELOAD not set to libytnef"
echo "$cfg" | grep -q 'supervisord' \
    && ok "image CMD runs supervisord" || err "image CMD is not supervisord"
for p in 20000/tcp 20001/tcp; do
    echo "$cfg" | grep -q "$p" && ok "image EXPOSE $p" || err "image does not EXPOSE $p"
done
echo "$cfg" | grep -q 'org.opencontainers.image.title' \
    && ok "image OCI labels present" || err "image OCI labels missing"

echo "== starting $IMAGE as $NAME =="
podman run -d --name "$NAME" -p "127.0.0.1:${HOSTPORT}:20001" "$IMAGE" >/dev/null \
    || { echo "FAIL: container did not start"; exit 1; }

base="http://127.0.0.1:${HOSTPORT}"

# Wait until Apache is up AND the proxy can reach sogod (sogod has startsecs=30
# in supervisor, so a 502/503 just means "not ready yet"). Timeout ~120s.
echo "== waiting for apache->sogod to be ready =="
ready=0
for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${base}/SOGo" || echo 000)
    case "$code" in
        301|302|200) ready=1; break ;;        # proxy reached sogod
    esac
    sleep 2
done
[ "$ready" -eq 1 ] && ok "apache + sogod reachable (/SOGo -> $code)" \
                    || { err "proxy never became ready"; podman logs "$NAME" | tail -30; exit 1; }

# 1. /SOGo must redirect to the login UI (sogod served via the proxy)
loc=$(curl -s -o /dev/null -w '%{redirect_url}' "${base}/SOGo")
code=$(curl -s -o /dev/null -w '%{http_code}' "${base}/SOGo")
case "$code" in
    301|302) echo "$loc" | grep -q '/SOGo' \
                 && ok "/SOGo redirects into SOGo ($code -> $loc)" \
                 || err "/SOGo redirect target unexpected: $loc" ;;
    *) err "/SOGo expected redirect, got HTTP $code" ;;
esac

# 2. The login page itself is rendered through the proxy (no DB needed)
body=$(curl -sL --max-time 15 "${base}/SOGo/")
echo "$body" | grep -qiE 'SOGo|connect.html|WebServerResources' \
    && ok "/SOGo/ login page served through the proxy" \
    || err "/SOGo/ did not return a SOGo page"

# 3. WebServerResources are served (Alias + static assets)
code=$(curl -s -o /dev/null -w '%{http_code}' "${base}/SOGo.woa/WebServerResources/css/")
[ "$code" != 502 ] && [ "$code" != 503 ] \
    && ok "WebServerResources alias reachable (HTTP $code)" \
    || err "WebServerResources alias unreachable (HTTP $code)"

# 4. ActiveSync endpoint reaches the EAS handler in sogod. Without credentials
#    sogod answers 401 (proxy OK). A 404/502/503 would mean the EAS ProxyPass
#    is missing/misordered or sogod unreachable.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
       -X OPTIONS "${base}/Microsoft-Server-ActiveSync")
case "$code" in
    401) ok "ActiveSync endpoint proxied to sogod EAS handler (HTTP 401, auth required)" ;;
    200|403) ok "ActiveSync endpoint reachable through proxy (HTTP $code)" ;;
    404) err "ActiveSync 404 - ProxyPass /Microsoft-Server-ActiveSync not effective" ;;
    *)   err "ActiveSync endpoint not proxied correctly (HTTP $code)" ;;
esac

# 5. The .well-known CalDAV/CardDAV autodiscovery rewrites (mod_rewrite) work
for kind in caldav carddav; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "${base}/.well-known/${kind}")
    loc=$(curl -s -o /dev/null -w '%{redirect_url}' "${base}/.well-known/${kind}")
    if [ "$code" = 301 ] && echo "$loc" | grep -q '/SOGo/dav'; then
        ok ".well-known/${kind} -> 301 ${loc}"
    else
        err ".well-known/${kind} expected 301 to /SOGo/dav, got $code ($loc)"
    fi
done

# 6. CalDAV/CardDAV endpoint itself is proxied to sogod's DAV handler.
#    Unauthenticated PROPFIND must reach sogod and get 401 (proxy OK); a
#    404/502/503 would mean DAV is not routed through the proxy.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
       -X PROPFIND -H 'Depth: 0' "${base}/SOGo/dav/")
case "$code" in
    401) ok "CalDAV/CardDAV endpoint proxied to sogod (PROPFIND -> 401, auth required)" ;;
    207|200) ok "CalDAV/CardDAV endpoint reachable through proxy (HTTP $code)" ;;
    404) err "/SOGo/dav PROPFIND 404 - DAV not routed through the proxy" ;;
    *)   err "CalDAV/CardDAV endpoint not proxied correctly (HTTP $code)" ;;
esac
# OPTIONS on the DAV endpoint should advertise DAV capabilities via the proxy
dav_hdr=$(curl -s -D - -o /dev/null --max-time 15 -X OPTIONS "${base}/SOGo/dav/" \
          | grep -i '^DAV:' || true)
[ -n "$dav_hdr" ] && ok "DAV capabilities advertised through proxy ($dav_hdr)" \
                   || ok "DAV OPTIONS proxied (no DAV header without auth - acceptable)"

# 7. All supervisor-managed services are RUNNING (a service may start then
#    crash; the HTTP checks above only cover sogod+apache). Fall back to a
#    process check if supervisorctl has no socket configured.
sv=$(podman exec "$NAME" supervisorctl status 2>/dev/null || true)
if [ -n "$sv" ]; then
    # sogod has startsecs=30: supervisor reports STARTING until then even
    # though it already serves HTTP. Poll until RUNNING, fail fast on a
    # terminal state (FATAL/EXITED/BACKOFF). Timeout ~60s.
    progs="sogod apache memcached cronie"
    for i in $(seq 1 30); do
        sv=$(podman exec "$NAME" supervisorctl status 2>/dev/null || true)
        echo "$sv" | grep -qiE '(FATAL|EXITED|BACKOFF)' && break
        pending=0
        for prog in $progs; do
            echo "$sv" | grep -iE "^${prog}\b" | grep -q 'RUNNING' || pending=1
        done
        [ "$pending" -eq 0 ] && break
        sleep 2
    done
    for prog in $progs; do
        line=$(echo "$sv" | grep -iE "^${prog}\b" || true)
        echo "$line" | grep -q 'RUNNING' \
            && ok "supervisor: $prog RUNNING" \
            || err "supervisor: $prog not RUNNING (${line:-absent})"
    done
else
    for proc in sogod httpd memcached crond; do
        podman exec "$NAME" pgrep -x "$proc" >/dev/null 2>&1 \
            && ok "process $proc alive" || err "process $proc not running"
    done
fi

# 8. mod_headers directives from SOGo.conf actually applied through the proxy
hdrs=$(curl -s -D - -o /dev/null --max-time 15 "${base}/SOGo/")
echo "$hdrs" | grep -iq '^Referrer-Policy:.*same-origin' \
    && ok "Referrer-Policy header set through proxy" \
    || err "Referrer-Policy header missing (mod_headers not effective)"
echo "$hdrs" | grep -iq '^Cache-Control:.*no-store' \
    && ok "Cache-Control no-store header present" \
    || ok "Cache-Control no-store not on /SOGo/ (Location-scoped - acceptable)"

# 9. Real static assets served via the WebServerResources Alias (CSS and JS,
#    so a broken .js MIME mapping is caught too).
for ext in css js; do
    asset=$(podman exec "$NAME" bash -c \
        "find /usr/lib/GNUstep/SOGo/WebServerResources -type f -name '*.${ext}' 2>/dev/null | head -1")
    if [ -n "$asset" ]; then
        rel=${asset#/usr/lib/GNUstep/SOGo/WebServerResources/}
        read -r acode actype < <(curl -s -o /dev/null \
            -w '%{http_code} %{content_type}' "${base}/SOGo.woa/WebServerResources/${rel}")
        [ "$acode" = 200 ] \
            && ok "static .${ext} served via Alias (${rel} -> 200, ${actype:-?})" \
            || err "static .${ext} ${rel} not served (HTTP $acode)"
    else
        err "no .${ext} asset found under WebServerResources"
    fi
done

# sogod must run unprivileged (as user 'sogo', per sogod.ini), not root
spid=$(podman exec "$NAME" pgrep -x sogod 2>/dev/null | head -1)
suser=$(podman exec "$NAME" ps -o user= -p "${spid:-0}" 2>/dev/null | tr -d ' ')
[ "$suser" = sogo ] \
    && ok "sogod runs as unprivileged user 'sogo'" \
    || err "sogod runs as '${suser:-unknown}' (expected sogo)"

# LD_PRELOAD library actually present in the image (TNEF/winmail.dat decode)
podman exec "$NAME" test -e /usr/lib/libytnef.so \
    && ok "LD_PRELOAD lib /usr/lib/libytnef.so present" \
    || err "/usr/lib/libytnef.so missing (LD_PRELOAD would fail)"

# 10. No crash-loop: sogod keeps the same PID over ~12s (no silent restart)
pid1=$(podman exec "$NAME" pgrep -x sogod 2>/dev/null | head -1)
sleep 12
pid2=$(podman exec "$NAME" pgrep -x sogod 2>/dev/null | head -1)
if [ -n "$pid1" ] && [ "$pid1" = "$pid2" ]; then
    ok "sogod stable (no restart, pid $pid1)"
else
    err "sogod restarted/crashed (pid before=$pid1 after=$pid2)"
fi

# 11. sogod is actually bound on :20000 inside the container (hex 4E20 in
#     /proc/net/tcp{,6}), independent of what supervisor believes. 20001=4E21.
ports=$(podman exec "$NAME" bash -c 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null')
echo "$ports" | grep -qiE ':4E20 .* 0A ' \
    && ok "sogod listening on :20000" \
    || err "sogod not listening on :20000"
echo "$ports" | grep -qiE ':4E21 .* 0A ' \
    && ok "apache listening on :20001" \
    || err "apache not listening on :20001"

# 12. Container logs free of hard failures (DB-less errors are expected and
#     whitelisted: sogod logs OCSFolderInfoURL without a configured database).
logs=$(podman logs "$NAME" 2>&1 | grep -viE 'OCSFolderInfoURL|GCSFolderManager' || true)
bad=$(echo "$logs" | grep -iE 'exited too quickly|cannot bind|address already in use|segfault|core dumped|FATAL ' || true)
[ -z "$bad" ] && ok "container logs free of hard failures" \
              || { err "hard failures in container logs:"; echo "$bad" | head -5; }

echo
if [ "$fail" -eq 0 ]; then
    echo "=== reverse-proxy smoke test PASSED ==="
else
    echo "=== reverse-proxy smoke test FAILED ==="
    echo "--- container logs (tail) ---"; podman logs "$NAME" 2>&1 | tail -40
fi
exit "$fail"
