#!/bin/bash
set -e

# Usage: ./release.sh 1.2.0 [--notes-file path/to/notes.md]
#
# Creates a version bump commit, an annotated tag carrying the release notes,
# and pushes both to trigger the GitHub Actions release workflow.
#
# --notes-file  Path to a Markdown file with the release notes (for AI agents
#               or scripted releases). Omit to open $EDITOR with a template.

NOTES_FILE=""
VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes-file)
      NOTES_FILE="$2"
      shift 2
      ;;
    -*)
      echo "Unknown flag: $1"
      echo "Usage: $0 <version> [--notes-file path/to/notes.md]"
      exit 1
      ;;
    *)
      if [ -z "$VERSION" ]; then
        VERSION="$1"
      else
        echo "Unexpected argument: $1"
        echo "Usage: $0 <version> [--notes-file path/to/notes.md]"
        exit 1
      fi
      shift
      ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version> [--notes-file path/to/notes.md]"
  echo "Example: $0 1.2.0"
  echo "Example: $0 1.2.0 --notes-file notes.md"
  exit 1
fi

TAG="v$VERSION"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: Version must be in semver format (e.g., 1.2.0)"
  exit 1
fi

echo "🚀 Releasing NoNoise Mac v$VERSION"
echo ""

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "main" ]; then
  echo "❌ Error: You must be on the 'main' branch to release"
  exit 1
fi

if ! git diff-index --quiet HEAD --; then
  echo "❌ Error: You have uncommitted changes. Please commit or stash them first."
  exit 1
fi

# ── Release notes ─────────────────────────────────────────────────────────────
if [ -n "$NOTES_FILE" ]; then
  if [ ! -f "$NOTES_FILE" ]; then
    echo "❌ Error: Notes file not found: $NOTES_FILE"
    exit 1
  fi
  RELEASE_NOTES_FILE="$NOTES_FILE"
else
  RELEASE_NOTES_FILE=$(mktemp /tmp/nonoise-release-notes-XXXXXX.md)
  cat > "$RELEASE_NOTES_FILE" << 'TEMPLATE'
## What's New

-

## Bug Fixes

-

## Notes

-
TEMPLATE
  echo "📝 Opening editor for release notes (save and close when done)..."
  ${EDITOR:-nano} "$RELEASE_NOTES_FILE"
fi

if ! grep -q '[^[:space:]]' "$RELEASE_NOTES_FILE" 2>/dev/null; then
  echo "❌ Error: Release notes are empty. Add content before releasing."
  exit 1
fi

# ── Version bump ──────────────────────────────────────────────────────────────
PLIST_FILE="Resources/Info.plist"
if [ ! -f "$PLIST_FILE" ]; then
  echo "❌ Error: $PLIST_FILE not found"
  exit 1
fi

echo "📝 Updating version in $PLIST_FILE"
# CFBundleVersion must be a MONOTONIC integer for Sparkle (see scripts/version-from-tag.sh).
# The old "MAJOR.MINOR digits" formula ignored PATCH and wasn't monotonic across minors.
if VERS=$(./scripts/version-from-tag.sh "$TAG"); then
  eval "$VERS"   # sets short (== $VERSION) and build
  BUILD_NUMBER="$build"
else
  echo "❌ Error: version-from-tag.sh rejected $TAG"
  exit 1
fi

if command -v plutil &> /dev/null; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST_FILE"
  plutil -replace CFBundleVersion -string "${BUILD_NUMBER}" "$PLIST_FILE"
else
  sed -i '' "/<key>CFBundleShortVersionString<\/key>/,/<\/string>/ s/<string>.*<\/string>/<string>$VERSION<\/string>/" "$PLIST_FILE"
  sed -i '' "/<key>CFBundleVersion<\/key>/,/<\/string>/ s/<string>.*<\/string>/<string>${BUILD_NUMBER}<\/string>/" "$PLIST_FILE"
fi

echo "✅ Version updated to $VERSION"
echo ""

echo "📦 Committing version bump"
git add "$PLIST_FILE"
git commit -m "chore(release): bump version to $VERSION"
echo "✅ Committed"
echo ""

# ── Annotated tag (carries the release notes) ─────────────────────────────────
echo "🏷️  Creating annotated git tag $TAG"
git tag -a "$TAG" -F "$RELEASE_NOTES_FILE"
echo "✅ Tag created"
echo ""

# ── Push ──────────────────────────────────────────────────────────────────────
echo "🚀 Pushing to GitHub (this triggers the release workflow)"
git push origin main "$TAG"
echo "✅ Pushed!"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✨ Release v$VERSION is on its way!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "GitHub Actions is building binaries now..."
echo "Watch progress: https://github.com/ivalsaraj/NoNoise-Mac/actions"
echo ""
echo "Release will be available in ~2-5 min at:"
echo "https://github.com/ivalsaraj/NoNoise-Mac/releases/tag/$TAG"
