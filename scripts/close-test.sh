#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build
run_root="$(mktemp -d "$PWD/build/close-checks.XXXXXX")"
xcodebuild -quiet -project AdaptivePDF.xcodeproj -scheme AdaptivePDF \
  -configuration Release -derivedDataPath "$run_root/DerivedData" \
  -destination 'platform=macOS,arch=x86_64' ARCHS=x86_64 \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=INTEGRATION_TESTS build
test_python="${ADAPTIVEPDF_PYTHON:-python3}"
"$test_python" scripts/run_close_flows.py \
  --app "$run_root/DerivedData/Build/Products/Release/AdaptivePDF.app" --output "$run_root/output"
echo "Report: $run_root/output/close-flows.json"
