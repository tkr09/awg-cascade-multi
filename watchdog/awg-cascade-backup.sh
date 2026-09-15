#!/bin/bash
set -euo pipefail
umask 077
[ "$#" -le 1 ] || exit 2
exec /usr/bin/python3 -I /usr/local/sbin/awg-cascade-backup.py "$@"
