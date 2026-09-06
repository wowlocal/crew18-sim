#!/bin/bash
# Build-time identity is set before packaging and provenance signing.
set -euo pipefail
: "${CREW_BUNDLE_ID:?Set the bundle ID from the server-issued build plan}"
project_dir="${CREW_SOURCE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
project="${CREW_XCODE_PROJECT:-PodlodkaDive.xcodeproj}"
scheme="${CREW_XCODE_SCHEME:-PodlodkaDive}"
build_dir="${CREW_BUILD_DIR:-$project_dir/build/submission}"
label="${CREW_DISPLAY_NAME:-Crew prototype}"
if [[ ! "$CREW_BUNDLE_ID" =~ ^io\.podlodka\.crew18\.s[a-f0-9]{32}\.b[a-f0-9]{32}$ ]]; then
  printf 'Expected the exact server-issued submission/build bundle ID.\n' >&2
  exit 2
fi
if [[ "$project" = /* || "$project" = *..* || "$project" != *.xcodeproj ]]; then
  printf 'Expected a relative Xcode project path.\n' >&2
  exit 2
fi
mkdir -p "$build_dir"
xcodebuild -project "$project_dir/$project" -scheme "$scheme" \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$build_dir/derived" CODE_SIGNING_ALLOWED=NO \
  PRODUCT_BUNDLE_IDENTIFIER="$CREW_BUNDLE_ID" \
  INFOPLIST_KEY_CFBundleDisplayName="$label" \
  build > "$build_dir/build.log" 2>&1 || { tail -n 60 "$build_dir/build.log"; exit 1; }
apps=("$build_dir"/derived/Build/Products/Debug-iphonesimulator/*.app)
if [[ ${#apps[@]} -ne 1 || ! -d "${apps[0]}" ]]; then
  printf 'Expected exactly one app product.\n' >&2
  exit 1
fi
actual_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${apps[0]}/Info.plist")
if [[ "$actual_id" != "$CREW_BUNDLE_ID" ]]; then
  printf 'Built bundle ID does not match the build plan.\n' >&2
  exit 1
fi
/usr/bin/ditto -c -k --norsrc --keepParent "${apps[0]}" "$build_dir/prototype.app.zip"
shasum -a 256 "$build_dir/prototype.app.zip" > "$build_dir/prototype.app.zip.sha256"
printf 'Build artifact: %s/prototype.app.zip\n' "$build_dir"
