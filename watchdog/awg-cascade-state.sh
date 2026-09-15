#!/bin/bash
set -euo pipefail
case "${1:-}" in
    edit-state|edit-peers) ;;
    *) echo 'usage: awg-cascade-state.sh edit-state|edit-peers' >&2; exit 2 ;;
esac
[ "$#" -eq 1 ] || exit 2
exec /usr/bin/python3 -I /usr/local/sbin/awg-cascade-control.py "$1"
