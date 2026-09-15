#!/bin/bash
set -euo pipefail
umask 077
exec /usr/bin/python3 -I /usr/local/sbin/awg-cascade-provision.py "$@"
