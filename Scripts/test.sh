#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"

# Supply bundled Swift Testing search paths omitted by some Command Line Tools releases.
TEST_DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
TEST_FRAMEWORKS="$TEST_DEVELOPER_DIR/Library/Developer/Frameworks"
TEST_RUNTIME="$TEST_DEVELOPER_DIR/Library/Developer/usr/lib"
if [[ -d "$TEST_FRAMEWORKS/Testing.framework" ]]; then
    exec swift test --disable-xctest \
        -Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$TEST_RUNTIME" "$@"
else
    exec swift test --disable-xctest "$@"
fi
