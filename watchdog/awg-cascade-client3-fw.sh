#!/bin/bash
# All client/LAN/IPv6 rules are applied by one locked, guarded backend.
set -euo pipefail
case "${1:-}" in --hook|--check-hook) test -x /usr/local/sbin/awg-cascade-firewall.py; exit $? ;; esac
[ "$#" -eq 0 ] || exit 2
exec /usr/bin/python3 -I /usr/local/sbin/awg-cascade-firewall.py
