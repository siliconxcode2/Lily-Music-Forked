#!/bin/zsh
# Builds an unsigned Release .ipa for SideStore, AltStore or Feather, which sign
# it on install. Releases are built by .github/workflows/release.yml.
#
#   scripts/build-ipa.sh            → build/Lily.ipa
set -euo pipefail
root=${0:A:h:h}
out=$root/build
derived=$out/DerivedData
app=$derived/Build/Products/Release-iphoneos/Lily.app

rm -rf "$out/Payload" "$out/Lily.ipa"
# Post-processing strips the symbol table, which otherwise names every source
# file and object file by its full path on the build machine.
xcodebuild -project "$root/Lily.xcodeproj" -scheme Lily -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  DEPLOYMENT_POSTPROCESSING=YES \
  build -quiet

mkdir -p "$out/Payload"
cp -R "$app" "$out/Payload/"
if grep -rqaF -e "$HOME" "$out/Payload"; then
  print -u2 "Lily.app still holds paths under $HOME; not packaging it."
  exit 1
fi
# ditto keeps the bundle's symlinks and permissions as an .ipa needs them.
(cd "$out" && ditto -c -k --norsrc --keepParent Payload Lily.ipa)
rm -rf "$out/Payload"

print "Built $out/Lily.ipa ($(du -h "$out/Lily.ipa" | cut -f1))"
