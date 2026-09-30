#!/bin/zsh
# Builds the release assets and (optionally) publishes them as a GitHub release.
#
#   scripts/release.sh                 # build dist/ only
#   scripts/release.sh --publish       # also create release vX.Y.Z on github.com/ziozzang/jamak-trans
#
# Publishing uses `gh` when installed, otherwise the GitHub API with $GITHUB_TOKEN.
# Release notes: RELEASE_NOTES.md (or $NOTES_FILE) if present.
set -euo pipefail
cd "${0:A:h}/.."

REPO=ziozzang/jamak-trans
VERSION=${VERSION:-$(<VERSION)}
TAG=v$VERSION
ASSET=JamakTrans_${VERSION}_macos_universal.zip

NOTES_FILE=${NOTES_FILE:-RELEASE_NOTES.md}
NOTES=$( [[ -f $NOTES_FILE ]] && cat "$NOTES_FILE" || echo "Jamak Trans $TAG" )

VERSION=$VERSION ./build.sh
rm -rf dist && mkdir dist
ditto -c -k --keepParent build/JamakTrans.app "dist/$ASSET"
(cd dist && shasum -a 256 "$ASSET" > SHA256SUMS && shasum -a 256 -c SHA256SUMS)

[[ ${1:-} == --publish ]] || { echo "✓ dist/ ready (not published)"; exit 0; }

git tag -a "$TAG" -m "Jamak Trans $TAG" 2>/dev/null || true
git push origin "$TAG"

if command -v gh >/dev/null; then
  gh release create "$TAG" "dist/$ASSET" dist/SHA256SUMS --repo $REPO --title "Jamak Trans $TAG" --notes "$NOTES"
  exit 0
fi

: ${GITHUB_TOKEN:?set GITHUB_TOKEN or install gh}
API=https://api.github.com/repos/$REPO
auth=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json")
body=$(python3 -c 'import json,sys; print(json.dumps({"tag_name":sys.argv[1],"name":"Jamak Trans "+sys.argv[1],"body":sys.argv[2]}))' "$TAG" "$NOTES")
upload=$(curl -fsS "${auth[@]}" -d "$body" "$API/releases" | python3 -c 'import json,sys; print(json.load(sys.stdin)["upload_url"].split("{")[0])')
for f in "dist/$ASSET" dist/SHA256SUMS; do
  curl -fsS "${auth[@]}" -H "Content-Type: application/octet-stream" --data-binary @"$f" "$upload?name=${f:t}" >/dev/null
  echo "uploaded ${f:t}"
done
echo "✓ released $TAG"
