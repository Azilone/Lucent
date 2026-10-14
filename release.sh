#!/bin/zsh
# Publishes a new version: bumps the version, builds the universal zip, creates the
# GitHub release, then updates appcast.xml so installed copies update via Sparkle.
#
#   ./release.sh 1.2 "- New thing
#   - Fixed thing"
#
# Needs: gh (logged in), the Sparkle EdDSA key in the keychain (account "lucent").
set -e
cd "$(dirname "$0")"
VERSION=$1; NOTES=$2
if [[ -z $VERSION || -z $NOTES ]]; then echo 'usage: ./release.sh <version> "<markdown notes>"'; exit 1; fi
if [[ -n $(git status --porcelain) ]]; then echo "Commit your changes first."; exit 1; fi

BUILD=$(( $(sed -n 's/^BUILD=//p' build.sh) + 1 ))
sed -i '' "s/^VERSION=.*/VERSION=$VERSION/; s/^BUILD=.*/BUILD=$BUILD/" build.sh
./build.sh --zip

# 1. Publish the binary first, so the appcast never points to a missing file.
git commit -qam "Release $VERSION"
git tag "v$VERSION"
git push -q && git push -q origin "v$VERSION"
gh release create "v$VERSION" "build/Lucent-$VERSION.zip" --title "Lucent $VERSION" --notes "$NOTES"

# 2. Sign the update and add it to the appcast.
STAGE=build/appcast
rm -rf $STAGE && mkdir -p $STAGE
cp "build/Lucent-$VERSION.zip" $STAGE/
[[ -f appcast.xml ]] && cp appcast.xml $STAGE/
print -r -- "$NOTES" | python3 -c '
import sys, html
items = [html.escape(l.strip()[2:]) for l in sys.stdin if l.strip().startswith("- ")]
print("<ul>" + "".join(f"<li>{i}</li>" for i in items) + "</ul>")' > "$STAGE/Lucent-$VERSION.html"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast --account lucent --embed-release-notes \
  --download-url-prefix "https://github.com/Azilone/Lucent/releases/download/v$VERSION/" \
  --link "https://github.com/Azilone/Lucent" $STAGE
cp $STAGE/appcast.xml appcast.xml
git add appcast.xml
git commit -qm "Appcast: Lucent $VERSION"
git push -q
echo "Released Lucent $VERSION (build $BUILD)"
