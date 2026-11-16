#!/usr/bin/env bash
# Parse every shipped script and the emitted shell integration under Bash 3.2 (the macOS system
# shell). Runs inside the official bash:3.2 image, so CI needs no macOS runner.
set -eu
bash --version | head -1
case "$BASH_VERSION" in 3.2.*) ;; *) echo "expected Bash 3.2, got $BASH_VERSION" >&2; exit 1 ;; esac
for f in bin/gtr bin/git-gtr lib/*.sh lib/commands/*.sh adapters/editor/*.sh adapters/ai/*.sh; do
  bash -n "$f"
done
out=$(mktemp)
# shellcheck source=/dev/null
. lib/commands/init.sh
_init_emit_posix_trust_helpers '' | sed 's/__FUNC__/gtr/g' > "$out"
bash -n "$out"
echo "Bash 3.2 parse OK"
