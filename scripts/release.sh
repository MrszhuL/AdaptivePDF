#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mode="${1:---candidate}"
if [[ "$mode" != --candidate && "$mode" != --notarize ]]; then
  echo 'Usage: scripts/release.sh [--candidate|--notarize]' >&2
  exit 64
fi
test_python="${ADAPTIVEPDF_PYTHON:-python3}"
"$test_python" -c 'import pypdf' || { echo 'Release validation requires pypdf; set ADAPTIVEPDF_PYTHON to a prepared Python runtime.' >&2; exit 1; }
"$test_python" scripts/verify_vendor.py
if [[ "$mode" == --notarize ]]; then
  : "${ADAPTIVEPDF_SIGNING_IDENTITY:?Set a Developer ID Application identity}"
  : "${ADAPTIVEPDF_NOTARY_PROFILE:?Set an existing notarytool keychain profile}"
  if ! security find-identity -v -p codesigning | /usr/bin/fgrep -F -- "$ADAPTIVEPDF_SIGNING_IDENTITY" >/dev/null; then
    echo 'The specified signing identity is not installed in the keychain.' >&2; exit 1
  fi
fi
mkdir -p build dist
run_root="$(mktemp -d "$PWD/build/release-checks.XXXXXX")"
echo "Validation work directory: $run_root"
for variant in debug optimized; do
  configuration=Debug
  conditions=DEBUG
  if [[ "$variant" == optimized ]]; then configuration=Release; conditions=INTEGRATION_TESTS; fi
  echo "Running $variant native integration checks…"
  xcodebuild -quiet -project AdaptivePDF.xcodeproj -scheme AdaptivePDF -configuration "$configuration" \
    -derivedDataPath "$run_root/$variant" -destination 'platform=macOS,arch=x86_64' \
    ARCHS=x86_64 "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$conditions" build > "$run_root/$variant-build.log" 2>&1
  mkdir -p "$run_root/$variant-output"
  ADAPTIVEPDF_TEST_ROOT="$PWD" ADAPTIVEPDF_TEST_OUTPUT="$run_root/$variant-output" \
    "$run_root/$variant/Build/Products/$configuration/AdaptivePDF.app/Contents/MacOS/AdaptivePDF" \
    --self-test > "$run_root/$variant-tests.log" 2>&1
  if [[ "${ADAPTIVEPDF_CAPTURE:-0}" == 1 ]]; then
    "$test_python" Tests/verify_dark_screenshots.py --output "$run_root/$variant-output" > "$run_root/$variant-dark-pixels.log"
  fi
  "$test_python" Tests/verify_saved_pdf.py --output "$run_root/$variant-output" > "$run_root/$variant-pdf.log"
  "$test_python" Tests/verify_forms.py --output "$run_root/$variant-output" > "$run_root/$variant-forms.log"
  "$test_python" Tests/verify_pointer_pdf.py --output "$run_root/$variant-output" > "$run_root/$variant-pointer.log"
  "$test_python" Tests/verify_image_preservation.py --output "$run_root/$variant-output" > "$run_root/$variant-image-preservation.log"
  echo "Running $variant isolated close and quit flows…"
  "$test_python" scripts/run_close_flows.py --require-independent \
    --app "$run_root/$variant/Build/Products/$configuration/AdaptivePDF.app" \
    --output "$run_root/$variant-close" > "$run_root/$variant-close.log" 2>&1
  echo "Running $variant cross-process appearance restoration…"
  "$test_python" scripts/run_appearance_restart.py \
    --app "$run_root/$variant/Build/Products/$configuration/AdaptivePDF.app" \
    --output "$run_root/$variant-appearance" > "$run_root/$variant-appearance.log" 2>&1
done
corpus_manifest="${ADAPTIVEPDF_CORPUS_MANIFEST:-$PWD/tmp/corpus/manifest.json}"
if [[ -f "$corpus_manifest" ]]; then
  echo 'Running full corpus regression with the optimized build…'
  ADAPTIVEPDF_CORPUS_MANIFEST="$corpus_manifest" ADAPTIVEPDF_CORPUS_OUTPUT="$run_root/corpus-output" \
    "$run_root/optimized/Build/Products/Release/AdaptivePDF.app/Contents/MacOS/AdaptivePDF" \
    --corpus-test > "$run_root/corpus-tests.log" 2>&1
  "$test_python" Tests/verify_corpus.py --manifest "$corpus_manifest" --output "$run_root/corpus-output" > "$run_root/corpus-independent.log"
else
  echo 'Corpus validation is missing; public distribution remains blocked.'
fi
echo 'Building uninstrumented Universal distribution…'
xcodebuild -quiet -project AdaptivePDF.xcodeproj -scheme AdaptivePDF -configuration Release \
  -derivedDataPath "$run_root/production" -destination 'platform=macOS,arch=x86_64' \
  'ARCHS=x86_64 arm64' SWIFT_ACTIVE_COMPILATION_CONDITIONS= build > "$run_root/production-build.log" 2>&1
app="$run_root/staging/AdaptivePDF.app"
mkdir -p "$run_root/staging"
ditto "$run_root/production/Build/Products/Release/AdaptivePDF.app" "$app"
release_stamp="$(TZ=Asia/Shanghai date +%Y%m%d-%H%M%S)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
out="$PWD/dist/AdaptivePDF-$version-build$build_number-$release_stamp"
mkdir -p "$out/verification"
for variant in debug optimized; do
  cp "$run_root/$variant-output/integration-report.json" "$out/verification/$variant.json"
  cp "$run_root/$variant-tests.log" "$out/verification/$variant.log"
  cp "$run_root/$variant-pdf.log" "$out/verification/$variant-pdf.log"
  cp "$run_root/$variant-forms.log" "$out/verification/$variant-forms.log"
  cp "$run_root/$variant-pointer.log" "$out/verification/$variant-pointer.log"
  cp "$run_root/$variant-close/close-flows.json" "$out/verification/$variant-close.json"
  cp "$run_root/$variant-close.log" "$out/verification/$variant-close.log"
  cp "$run_root/$variant-appearance/appearance-restart.json" "$out/verification/$variant-appearance.json"
  cp "$run_root/$variant-appearance.log" "$out/verification/$variant-appearance.log"
  cp "$run_root/$variant-output/image-preservation.json" "$out/verification/$variant-image-preservation.json"
  cp "$run_root/$variant-output/thumbnails.json" "$out/verification/$variant-thumbnails.json"
  cp "$run_root/$variant-output/thumbnail-sidebar-dark.png" "$out/verification/$variant-thumbnail-sidebar-dark.png"
  cp "$run_root/$variant-output/thumbnail-sidebar-light.png" "$out/verification/$variant-thumbnail-sidebar-light.png"
  if [[ -f "$run_root/$variant-output/dark-pixels.json" ]]; then
    cp "$run_root/$variant-output/dark-pixels.json" "$out/verification/$variant-dark-pixels.json"
    cp "$run_root/$variant-output/screenshots.json" "$out/verification/$variant-screenshots.json"
    cp "$run_root/$variant-output/window-dark.png" "$out/verification/$variant-window-dark.png"
    cp "$run_root/$variant-output/window-light.png" "$out/verification/$variant-window-light.png"
  fi
done
if [[ -f "$run_root/corpus-output/corpus-report.json" ]]; then
  cp "$run_root/corpus-output/corpus-report.json" "$out/verification/corpus.json"
  cp "$run_root/corpus-output/independent-corpus-report.json" "$out/verification/corpus-independent.json"
  cp "$run_root/corpus-tests.log" "$out/verification/corpus.log"
  cp "$run_root/corpus-independent.log" "$out/verification/corpus-independent.log"
fi
if [[ "$mode" == --notarize ]]; then
  for library in "$app/Contents/Frameworks/"*.dylib; do
    codesign --force --options runtime --timestamp --sign "$ADAPTIVEPDF_SIGNING_IDENTITY" "$library"
  done
  codesign --force --options runtime --timestamp --sign "$ADAPTIVEPDF_SIGNING_IDENTITY" "$app"
  ditto -c -k --keepParent "$app" "$run_root/notary-submit.zip"
  xcrun notarytool submit "$run_root/notary-submit.zip" --keychain-profile "$ADAPTIVEPDF_NOTARY_PROFILE" \
    --wait --output-format json > "$out/verification/app-notarization.json"
  "$test_python" -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted"' "$out/verification/app-notarization.json"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  "$test_python" scripts/check_release.py "$app" --report "$out/verification/production.json" --require-developer-id
else
  "$test_python" scripts/check_release.py "$app" --report "$out/verification/production.json"
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/AdaptivePDF-macOS.zip"
ln -s /Applications "$run_root/staging/Applications"
hdiutil create -quiet -volname AdaptivePDF -srcfolder "$run_root/staging" -format UDZO -fs HFS+ "$out/AdaptivePDF.dmg"
if [[ "$mode" == --notarize ]]; then
  codesign --timestamp --sign "$ADAPTIVEPDF_SIGNING_IDENTITY" "$out/AdaptivePDF.dmg"
  xcrun notarytool submit "$out/AdaptivePDF.dmg" --keychain-profile "$ADAPTIVEPDF_NOTARY_PROFILE" \
    --wait --output-format json > "$out/verification/dmg-notarization.json"
  "$test_python" -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted"' "$out/verification/dmg-notarization.json"
  xcrun stapler staple "$out/AdaptivePDF.dmg"
  xcrun stapler validate "$out/AdaptivePDF.dmg"
fi
hdiutil verify "$out/AdaptivePDF.dmg" > "$out/verification/dmg-verify.log"
mountpoint="$run_root/install-check"
mkdir -p "$mountpoint"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mountpoint" "$out/AdaptivePDF.dmg"
trap 'hdiutil detach -quiet "$mountpoint" || true' EXIT
xcrun swift scripts/launch_probe.swift "$mountpoint/AdaptivePDF.app" "$PWD/Tests/Fixtures/Academic.pdf" "$out/verification/launch.json"
hdiutil detach -quiet "$mountpoint"
trap - EXIT
if [[ "$mode" == --notarize ]]; then
  spctl --assess --type execute --verbose=2 "$app" > "$out/verification/gatekeeper.log" 2>&1
  "$test_python" scripts/package_release.py --app "$app" --output "$out" --notarized
else
  "$test_python" scripts/package_release.py --app "$app" --output "$out"
fi
printf '%s\n' "$out" > build/latest-release-path.txt
echo "Candidate package: $out"
