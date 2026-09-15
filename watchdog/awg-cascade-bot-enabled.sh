#!/bin/bash
set -euo pipefail
. /usr/local/sbin/awg-cascade-cfg.sh
awgc_load_config
[ "${BOT_ENABLED:-1}" = 1 ]
