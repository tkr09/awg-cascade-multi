#!/bin/bash
# All client/LAN/IPv6 rules are applied by one locked, guarded backend.
set -euo pipefail
[ "$#" -eq 0 ] || exit 2
exec /usr/bin/python3 -I /usr/local/sbin/awg-cascade-firewall.py
