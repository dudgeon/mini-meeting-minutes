#!/bin/bash
# Builds mmm from the newest commit on GitHub's main and publishes it as the `prebuilt` release,
# which install.sh downloads, so most Macs need no developer tools. Run it after pushing to main;
# until then, the installer keeps giving out the last version published.
#
# The release holds:
#   mmm-<commit>.tar.gz   mmm, its resource bundles, and COMMIT; the newest few are kept, so an
#                         installer that has just read commit.txt still finds its download
#   commit.txt            the newest commit, uploaded after its tarball
#
# Usage: scripts/publish-prebuilt.sh
set -euo pipefail

REPO=dudgeon/mini-meeting-minutes
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A fresh copy of main as GitHub has it, so nothing uncommitted or unpushed ends up in the build.
git clone --quiet --depth 1 --branch main "https://github.com/$REPO.git" "$work/src"
commit="$(git -C "$work/src" rev-parse HEAD)"
echo "Building $commit"
swift build --package-path "$work/src" -c release --disable-keychain
bin="$(swift build --package-path "$work/src" -c release --disable-keychain --show-bin-path)"

mkdir "$work/app"
cp "$bin/mmm" "$work/app/"
cp -R "$bin"/*.bundle "$work/app/"
echo "$commit" >"$work/app/COMMIT"
tarball="$work/mmm-$commit.tar.gz"
tar -czf "$tarball" -C "$work/app" .
echo "$commit" >"$work/commit.txt"
"$work/src/scripts/check-prebuilt.sh" "$tarball"

if gh release view prebuilt --repo "$REPO" >/dev/null 2>&1; then
  gh api -X PATCH "repos/$REPO/git/refs/tags/prebuilt" -f sha="$commit" -F force=true >/dev/null
else
  gh release create prebuilt --repo "$REPO" --prerelease --title "Prebuilt app" --target "$commit" \
    --notes "Downloaded by install.sh. Replaced by scripts/publish-prebuilt.sh."
fi
gh release upload prebuilt --repo "$REPO" "$tarball" --clobber
gh release upload prebuilt --repo "$REPO" "$work/commit.txt" --clobber
# Keep the five newest builds.
gh release view prebuilt --repo "$REPO" --json assets \
  --jq '[.assets[] | select(.name | startswith("mmm-"))] | sort_by(.createdAt) | reverse | .[5:] | .[].name' |
  while read -r old; do gh release delete-asset prebuilt "$old" --repo "$REPO" --yes; done
echo "Published $commit"
