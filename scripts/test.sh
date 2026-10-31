#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == /Library/Developer/CommandLineTools ]]; then
    swift test --disable-xctest \
        -Xswiftc -F"$developer_dir/Library/Developer/Frameworks" \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/Frameworks" \
        -Xlinker -F"$developer_dir/Library/Developer/Frameworks"
else
    swift test --disable-xctest
fi
