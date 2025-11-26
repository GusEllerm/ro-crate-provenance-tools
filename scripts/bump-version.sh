#!/bin/bash
# Bump version in pyproject.toml and create git tag

set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 0.2.0"
  exit 1
fi

VERSION=$1

# Validate version format (basic check)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: Version must be in format MAJOR.MINOR.PATCH (e.g., 0.2.0)"
  exit 1
fi

# Get current version
CURRENT_VERSION=$(grep -E '^version = ' pyproject.toml | sed -E 's/version = "(.+)"/\1/')

echo "Current version: $CURRENT_VERSION"
echo "New version: $VERSION"

# Update pyproject.toml
if [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS
  sed -i '' "s/version = \".*\"/version = \"$VERSION\"/" pyproject.toml
else
  # Linux
  sed -i "s/version = \".*\"/version = \"$VERSION\"/" pyproject.toml
fi

echo "✅ Updated pyproject.toml"

# Show git status
echo ""
echo "Next steps:"
echo "  1. Review changes: git diff pyproject.toml"
echo "  2. Commit: git add pyproject.toml && git commit -m 'chore: bump version to $VERSION'"
echo "  3. Tag: git tag -a v$VERSION -m 'Release version $VERSION'"
echo "  4. Push: git push origin main && git push origin v$VERSION"

