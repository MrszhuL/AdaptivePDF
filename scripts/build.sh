#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-Release}"
if [[ "$configuration" != Release && "$configuration" != Debug ]]; then
  echo 'Usage: scripts/build.sh [Release|Debug]' >&2
  exit 64
fi
mkdir -p build
run_root="$(mktemp -d "$PWD/build/local-build.XXXXXX")"
xcodebuild -project AdaptivePDF.xcodeproj -scheme AdaptivePDF \
  -configuration "$configuration" -derivedDataPath "$run_root/DerivedData" \
  -destination 'platform=macOS,arch=x86_64' build
staged="$run_root/AdaptivePDF.app"
ditto "$run_root/DerivedData/Build/Products/$configuration/AdaptivePDF.app" "$staged"
codesign --verify --deep --strict "$staged"
destination="$PWD/build/AdaptivePDF.app"
if [[ -e "$destination/Contents/MacOS/AdaptivePDF" ]] && \
    /usr/sbin/lsof -t "$destination/Contents/MacOS/AdaptivePDF" >/dev/null 2>&1; then
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$staged/Contents/Info.plist")"
  build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$staged/Contents/Info.plist")"
  destination="$PWD/build/AdaptivePDF-$version-build$build_number-${run_root:t}.app"
  echo 'The previous local app is in use; the new build has a separate path.'
fi
if [[ -e "$destination" ]]; then mv "$destination" "$run_root/previous-app.app"; fi
mv "$staged" "$destination"
printf '%s\n' "$destination" > build/latest-app-path.txt
echo "App: $destination"
