#!/usr/bin/env bash
# Runs on the host: DNSSEC validates, local data answers, the cache is used
# and access control refuses the container's own address. CI pipes it in
# with podman exec.
set -eu
if command -v apt-get >/dev/null; then
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bind9-dnsutils >/dev/null
else
  dnf -y -q install bind-utils
fi
# The first lookups after a start also fetch the root's keys. A fetch that
# fails is cached as bogus for val-bogus-ttl, 60 seconds by default, so the
# wait outlasts it.
for _ in $(seq 45); do dig @127.0.0.1 example.com | grep -q 'status: NOERROR' && break; sleep 2; done
# Full recursion from a CI runner loses the odd packet to the root or TLD
# servers, which shows as a one-off SERVFAIL; ask again before failing.
ok=
for _ in $(seq 10); do
  out=$(dig @127.0.0.1 example.com)
  echo "$out" | grep -q 'flags:.* ad[ ;]' && { ok=1; break; }
  sleep 3
done
echo "$out" >&2
[ -n "$ok" ]
dig @127.0.0.1 dnssec-failed.org | grep -q 'status: SERVFAIL'
[ "$(dig +short @127.0.0.1 nas.home.arpa)" = 192.168.1.10 ]
dig @127.0.0.1 printer.home.arpa | grep -q 'status: NXDOMAIN'
hits() { unbound-control stats_noreset | sed -n 's/^total.num.cachehits=//p'; }
before=$(hits)
dig @127.0.0.1 example.com >/dev/null
[ "$(hits)" -gt "$before" ]
addr=$(getent ahostsv4 "$(cat /proc/sys/kernel/hostname)" | awk '$1 !~ /^127\./ { print $1; exit }')
dig @"$addr" example.com | grep -q 'status: REFUSED'
