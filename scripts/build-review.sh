#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$project_dir/build/review"
derived_dir="$project_dir/build/review-derived"
mkdir -p "$output_dir"

xcodebuild \
  -project "$project_dir/PodlodkaDive.xcodeproj" \
  -scheme PodlodkaDive \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived_dir" \
  CODE_SIGNING_ALLOWED=NO \
  build > "$output_dir/build.log" 2>&1 || {
    tail -n 60 "$output_dir/build.log"
    exit 1
  }

/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
  "$derived_dir/Build/Products/Debug-iphonesimulator/PodlodkaDive.app" \
  "$output_dir/PodlodkaDive.app.zip"
printf 'Upload this simulator build to Tapflow:\n%s\n' "$output_dir/PodlodkaDive.app.zip"
