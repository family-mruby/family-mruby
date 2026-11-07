#!/bin/bash
# Make $1 the only active FMRB_HW_TARGET in fmruby-core/.env (run in fmruby-core).
set -euo pipefail
target="$1"
sed -i -E 's/^FMRB_HW_TARGET=/#FMRB_HW_TARGET=/' .env
echo "FMRB_HW_TARGET=${target}" >> .env
test "$(grep -c '^FMRB_HW_TARGET=' .env)" = 1
grep "^FMRB_HW_TARGET=${target}\$" .env
