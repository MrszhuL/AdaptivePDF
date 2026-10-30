#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
test_python="${ADAPTIVEPDF_PYTHON:-python3}"
"$test_python" scripts/verify_vendor.py
if [[ ! -f tmp/corpus/manifest.json ]]; then
  echo 'Prepare the corpus with Tests/generate_corpus.py --fetch first.' >&2
  exit 1
fi
mkdir -p build
check_root="$(mktemp -d "$PWD/build/corpus-checks.XXXXXX")"
xcodebuild -quiet -project AdaptivePDF.xcodeproj -scheme AdaptivePDF -configuration Release \
  -derivedDataPath "$check_root/DerivedData" -destination 'platform=macOS,arch=x86_64' \
  ARCHS=x86_64 SWIFT_ACTIVE_COMPILATION_CONDITIONS=INTEGRATION_TESTS build > "$check_root/build.log" 2>&1
ADAPTIVEPDF_CORPUS_MANIFEST="$PWD/tmp/corpus/manifest.json" ADAPTIVEPDF_CORPUS_OUTPUT="$check_root/output" \
  "$check_root/DerivedData/Build/Products/Release/AdaptivePDF.app/Contents/MacOS/AdaptivePDF" \
  --corpus-test > "$check_root/native.log" 2>&1
"$test_python" Tests/verify_corpus.py --manifest tmp/corpus/manifest.json --output "$check_root/output" > "$check_root/independent.log"
echo "Corpus report: $check_root/output/corpus-report.json"
echo "Independent report: $check_root/output/independent-corpus-report.json"
