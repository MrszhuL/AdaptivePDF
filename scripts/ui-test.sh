#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build
check_root="$(mktemp -d "$PWD/build/ui-checks.XXXXXX")"
echo 'UI tests require an unlocked graphical session and macOS developer-tool authorization.'
echo "Result bundle: $check_root/NativeFlow.xcresult"
xcodebuild -project AdaptivePDF.xcodeproj -scheme AdaptivePDFUITests \
  -derivedDataPath "$check_root/DerivedData" -destination 'platform=macOS,arch=x86_64' \
  -resultBundlePath "$check_root/NativeFlow.xcresult" test
