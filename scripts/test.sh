#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p tmp/test-output
xcodebuild -quiet -project AdaptivePDF.xcodeproj -scheme AdaptivePDF \
  -configuration Debug -derivedDataPath build/DerivedData \
  -destination 'platform=macOS,arch=x86_64' build
ADAPTIVEPDF_TEST_ROOT="$PWD" \
  build/DerivedData/Build/Products/Debug/AdaptivePDF.app/Contents/MacOS/AdaptivePDF --self-test
# Optional second parser; the application and native integration checks have no
# Python dependency. Install pypdf or set ADAPTIVEPDF_PYTHON to a prepared runtime.
test_python="${ADAPTIVEPDF_PYTHON:-python3}"
"$test_python" scripts/run_close_flows.py \
  --app build/DerivedData/Build/Products/Debug/AdaptivePDF.app --output tmp/close-flows
"$test_python" scripts/run_appearance_restart.py \
  --app build/DerivedData/Build/Products/Debug/AdaptivePDF.app --output tmp/appearance-restart
if "$test_python" -c 'import pypdf' >/dev/null 2>&1; then
  "$test_python" Tests/verify_saved_pdf.py
  "$test_python" Tests/verify_forms.py
  "$test_python" Tests/verify_pointer_pdf.py
  "$test_python" Tests/verify_image_preservation.py --output tmp/test-output
else
  echo 'Independent stream validation skipped: install pypdf, or set ADAPTIVEPDF_PYTHON.'
fi
