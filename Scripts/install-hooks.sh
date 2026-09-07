#!/bin/sh
set -eu

cd "$(git rev-parse --show-toplevel)"
HOOK_PATH="$(git config --get core.hooksPath || true)"
if [ -n "$HOOK_PATH" ] && [ "$HOOK_PATH" != .githooks ]; then
    echo 'A different hooks directory is configured; integrate the project hook there.' >&2
    exit 1
fi
DEFAULT_HOOK="$(git rev-parse --git-path hooks/pre-commit)"
if [ -z "$HOOK_PATH" ] && [ -e "$DEFAULT_HOOK" ]; then
    echo 'An existing pre-commit hook is installed; integrate the project hook without replacing it.' >&2
    exit 1
fi
git config --local core.hooksPath .githooks
echo 'Installed the project pre-commit hook for this checkout.'
