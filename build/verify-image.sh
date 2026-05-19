#!/bin/bash
#
# Copyright (C) 2026 Nethesis S.r.l.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runtime-stage self-check: a broken image must never ship. Runs fully offline
# during the build; any failure aborts it (exit 1). Kept as a COPY+RUN script
# because the CI buildah does not support Dockerfile heredocs.
#
# Expects SOGO_VERSION in the environment (Dockerfile ARG).
set -u
EXPECT_SOGO="${SOGO_VERSION:?SOGO_VERSION must be set}"
fail=0
err(){ echo "FAIL: $*"; fail=1; }
ok(){ echo "OK:   $*"; }

# 1. Shared libraries resolve (missing file is a FAIL, not a silent pass)
check_ldd(){
    local f="$1"
    if [ ! -e "$f" ]; then err "missing binary/library: $f"; return; fi
    # only ELF objects are worth an ldd (skip plists, stamp.make, etc.)
    [ "$(head -c4 "$f" 2>/dev/null)" = $'\x7fELF' ] || return
    local m; m=$(ldd "$f" 2>/dev/null | grep "not found" || true)
    if [ -n "$m" ]; then err "unresolved libs in $f:"; echo "$m"; else ok "ldd $f"; fi
}
for b in /usr/sbin/sogod /usr/bin/sogo-tool /usr/bin/sogo-ealarms-notify \
         /usr/sbin/sogo-slapd-sockd; do
    [ -e "$b" ] && check_ldd "$b"
done
shopt -s nullglob
bundles=( /usr/lib/GNUstep/SOGo/*.SOGo/*.SOGo \
          /usr/lib/GNUstep/SaxDrivers-*/*/* \
          /usr/lib/GNUstep/SoProducts-*/*/* \
          /usr/lib/GNUstep/GDLAdaptors-*/*/* )
[ ${#bundles[@]} -gt 0 ] || err "no GNUstep SOGo/SOPE bundles found"
for so in "${bundles[@]}"; do [ -f "$so" ] && check_ldd "$so"; done

# 2. ldconfig cache knows the from-source libs
ldconfig -p | grep -Eiq 'libgnustep-base' || err "libgnustep-base not in ldconfig cache"
ldconfig -p | grep -Eiq 'libwbxml'        || err "libwbxml not in ldconfig cache"

# 3. Version parity: built libSOGo soname must match the requested version
if [ -e "/usr/lib/sogo/libSOGo.so.${EXPECT_SOGO}" ]; then
    ok "SOGo version ${EXPECT_SOGO} (libSOGo.so.${EXPECT_SOGO})"
else
    err "built SOGo version != ${EXPECT_SOGO} (got: $(ls /usr/lib/sogo/libSOGo.so.* 2>/dev/null | tr '\n' ' '))"
fi

# 4. Key runtime files installed (from-source has no .install hook safety net)
for f in /etc/sogo/sogo.conf /etc/httpd/conf/extra/SOGo.conf \
         /etc/logrotate.d/sogo /usr/lib/GNUstep/SOGo/ActiveSync.SOGo; do
    [ -e "$f" ] && ok "present $f" || err "missing $f"
done
[ -x /usr/lib/sogo/scripts/sogo-backup.sh ] || err "sogo-backup.sh missing or not executable"
ls /usr/lib/sogo/scripts/sql-*.sh >/dev/null 2>&1 || err "sql-*.sh helper scripts missing"
[ -n "$(ls -A /usr/lib/GNUstep/SOGo/WebServerResources/ 2>/dev/null)" ] \
    || err "WebServerResources (web UI assets) empty"

# 5. Runtime user + directories
id sogo >/dev/null 2>&1 || err "sogo system user missing"
for d in /var/run/sogo /var/spool/sogo /var/log/sogo; do
    [ -d "$d" ] && [ "$(stat -c %U "$d")" = sogo ] || err "$d missing or not owned by sogo"
done
# sogo.conf is installed 0600; sogod runs as 'sogo' so it must own/read it
[ "$(stat -c %U /etc/sogo/sogo.conf 2>/dev/null)" = sogo ] \
    && ok "/etc/sogo/sogo.conf owned by sogo (readable by sogod)" \
    || err "/etc/sogo/sogo.conf not owned by sogo (0600 -> sogod cannot read it)"

# 6. Service binaries are runnable
httpd -t >/dev/null 2>&1 && ok "apache config (incl. SOGo.conf) valid" \
                          || err "apache config invalid (httpd -t)"
memcached -h    >/dev/null 2>&1 || err "memcached not runnable"
supervisord -v  >/dev/null 2>&1 || err "supervisord not runnable"

# 7. Apache wiring for the SOGo reverse-proxy
#    httpd.conf must include SOGo.conf, and every module its directives need
#    (ProxyPass, Header/RequestHeader, RewriteRule, Alias, SetEnvIf, SetEnv,
#    Require) must actually be loaded.
grep -Eq '^[[:space:]]*Include[[:space:]]+conf/extra/SOGo\.conf' \
    /etc/httpd/conf/httpd.conf \
    && ok "httpd.conf includes SOGo.conf" \
    || err "httpd.conf does not Include conf/extra/SOGo.conf"
loaded=$(httpd -M 2>/dev/null)
for m in proxy_module proxy_http_module proxy_balancer_module headers_module \
         rewrite_module alias_module setenvif_module env_module \
         authz_host_module; do
    echo "$loaded" | grep -qw "$m" && ok "apache module $m loaded" \
                                   || err "required apache module not loaded: $m"
done
# Reverse-proxy target must match the port sogod is started on by supervisor
proxy_port=$(grep -oE '127\.0\.0\.1:[0-9]+' /etc/httpd/conf/extra/SOGo.conf | head -1 | cut -d: -f2)
sogod_port=$(grep -oE 'WOPort[[:space:]]+[0-9.]+:[0-9]+' /etc/supervisor.d/sogod.ini | grep -oE '[0-9]+$')
if [ -n "$proxy_port" ] && [ "$proxy_port" = "$sogod_port" ]; then
    ok "apache ProxyPass port ($proxy_port) matches sogod -WOPort"
else
    err "ProxyPass port ($proxy_port) != sogod -WOPort ($sogod_port)"
fi
# ActiveSync ProxyPass must be active (uncommented) in SOGo.conf.
# compile-sogo.sh ensures this via sed; verify it here.
grep -q '^ProxyPass /Microsoft-Server-ActiveSync' /etc/httpd/conf/extra/SOGo.conf \
    && ok "ActiveSync ProxyPass active in SOGo.conf" \
    || err "ActiveSync ProxyPass missing or commented in SOGo.conf"
# ActiveSync ProxyPass timeout must be large enough for EAS Ping (>=300s);
# match the standalone 'timeout=' token, not 'connectiontimeout='.
eas_to=$(grep -oE '(^|[[:space:]])timeout=[0-9]+' /etc/httpd/conf/extra/SOGo.conf | head -1 | grep -oE '[0-9]+')
if [ -n "$eas_to" ] && [ "$eas_to" -ge 300 ]; then
    ok "ActiveSync ProxyPass timeout=${eas_to}s (>=300)"
else
    err "ActiveSync ProxyPass timeout too low/absent (${eas_to:-unset}, need >=300)"
fi

# 7b. memcached endpoint coherence: sogod session cache must point at the
#     memcached supervisor actually starts. SOGoMemcachedHost in sogo.conf is
#     a // comment when unset -> SOPE default 127.0.0.1:11211.
mc_cmd=$(grep -E '^command=.*memcached' /etc/supervisor.d/memcached.ini)
mc_port=$(echo "$mc_cmd" | grep -oE '\-p[[:space:]]*[0-9]+' | grep -oE '[0-9]+')
mc_port=${mc_port:-11211}
sg_host=$(grep -E '^[[:space:]]*SOGoMemcachedHost[[:space:]]*=' /etc/sogo/sogo.conf \
          | head -1 | sed -E 's/.*=[[:space:]]*"?([^";]+)"?.*/\1/')
if [ -z "$sg_host" ]; then
    [ "$mc_port" = 11211 ] \
        && ok "memcached default port 11211 matches SOGo default (SOGoMemcachedHost unset)" \
        || err "SOGoMemcachedHost unset (SOGo uses :11211) but memcached runs on :$mc_port"
else
    echo "$sg_host" | grep -q "$mc_port" || echo "$sg_host" | grep -q '\.sock' \
        && ok "SOGoMemcachedHost ($sg_host) consistent with memcached.ini" \
        || err "SOGoMemcachedHost ($sg_host) does not match memcached port $mc_port"
fi

# 8. Binaries supervisor actually launches must exist and resolve their libs
#    (sogod.ini uses /usr/bin/sogod, not the /usr/sbin path checked above)
for prog in /usr/bin/sogod /usr/bin/httpd /usr/bin/memcached; do
    [ -x "$prog" ] && check_ldd "$prog" || err "supervised binary missing: $prog"
done
command -v crond >/dev/null 2>&1 || err "crond (cronie) not found"

# 9. Build-toolchain leak guard (size/cleanliness regression)
for t in gcc cc make cmake git gnustep-config; do
    command -v "$t" >/dev/null 2>&1 && err "build tool leaked into runtime image: $t"
done

if [ "$fail" -eq 0 ]; then
    echo "=== runtime image verification PASSED ==="
else
    echo "=== runtime image verification FAILED ==="; exit 1
fi
