#!/bin/bash
# Durable two-sided migration; keys travel only through stdin.
set -euo pipefail
umask 077
exec /usr/bin/python3 -I /usr/local/sbin/awg-cascade-awg3.py "$@"
