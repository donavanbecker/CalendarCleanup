#!/bin/zsh
# Builds, signs and notarizes Calendar Cleanup, then publishes it as a GitHub release.
# Uses MARKETING_VERSION from the Xcode project as the version.
set -euo pipefail
cd "${0:A:h}/.."

project="CalendarCleanupApp/CalendarCleanup.xcodeproj"
profile="calendar-cleanup"
out="dist"

version=$(xcodebuild -project "$project" -scheme CalendarCleanup -configuration Release -showBuildSettings \
  | awk '$1 == "MARKETING_VERSION" { print $3 }')
tag="v$version"
zip="$out/CalendarCleanup-$version.zip"

if [[ -n $(git status --porcelain) ]]; then
  echo "Commit your changes first, so the release matches the code." >&2
  exit 1
fi
if gh release view "$tag" >/dev/null 2>&1; then
  echo "Release $tag already exists. Update MARKETING_VERSION in the Xcode project first." >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "No Developer ID Application certificate found. Create one in Xcode > Settings > Accounts > Manage Certificates." >&2
  exit 1
fi

mkdir -p "$out"
xcodebuild -project "$project" -scheme CalendarCleanup -configuration Release \
  -destination "generic/platform=macOS" -archivePath "$out/CalendarCleanup.xcarchive" archive
xcodebuild -exportArchive -archivePath "$out/CalendarCleanup.xcarchive" \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$out/export"

app="$out/export/Calendar Cleanup.app"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
spctl --assess --type execute --verbose "$app"

# Zip again so the download includes the notarization ticket.
ditto -c -k --keepParent "$app" "$zip"
gh release create "$tag" "$zip" --title "Calendar Cleanup $version" --generate-notes
