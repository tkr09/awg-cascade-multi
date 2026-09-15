#!/bin/bash
# Complete, idempotent policy reconciliation, including strict pin guards.
set -euo pipefail
[ "$#" -eq 0 ] || exit 2
exec /usr/bin/python3 -I /usr/local/sbin/awg-cascade-routing.py
