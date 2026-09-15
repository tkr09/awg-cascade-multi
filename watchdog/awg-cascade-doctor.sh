#!/bin/bash
set -euo pipefail
[ "$#" -eq 0 ] || exit 2
exec /usr/bin/python3 -I /usr/local/sbin/awg-cascade-doctor.py
