#!/bin/sh
# Copyright 2026 openduo
# SPDX-License-Identifier: FSL-1.1-Apache-2.0

# Fails when LICENSE or THIRD_PARTY_NOTICES.md is missing, or when a tracked (or new, not
# ignored) source file lacks the SPDX header in its first lines.
set -eu
cd "$(dirname "$0")/.."
bad=0
for f in LICENSE THIRD_PARTY_NOTICES.md; do
  [ -f "$f" ] || { echo "missing $f"; bad=1; }
done
for f in $(git ls-files --cached --others --exclude-standard -- \
  '*.swift' '*.go' '*.c' '*.h' '*.sh' '*.py' '*.xcconfig'); do
  [ -f "$f" ] || continue
  if ! head -n 4 "$f" | grep -q 'SPDX-License-Identifier: FSL-1.1-Apache-2.0'; then
    echo "missing SPDX header: $f"
    bad=1
  fi
done
exit $bad
