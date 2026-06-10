#!/usr/bin/env bash
# Cut a release: enforce a clean, pushed tree, bump the version, tag, and push.
# CI (.github/workflows/release.yml) does the signing/notarizing/publishing.
# See ADR 0010.
set -euo pipefail

bump="${1:-patch}"
case "$bump" in
	patch | minor | major) ;;
	*)
		echo "usage: release.sh {patch|minor|major}" >&2
		exit 1
		;;
esac

# Preflight gate — every release must map to a committed, pushed commit.
if ! git diff --quiet || ! git diff --cached --quiet; then
	echo "✗ uncommitted changes — commit or stash first" >&2
	exit 1
fi
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
	echo "✗ untracked files present — commit or clean them first" >&2
	exit 1
fi
if ! upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
	echo "✗ current branch has no upstream — push it first" >&2
	exit 1
fi
git fetch -q origin
if [ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]; then
	echo "✗ HEAD is not pushed to $upstream — push first" >&2
	exit 1
fi

read -r version build < <(python3 scripts/bump_version.py "$bump")
echo "→ releasing v$version (build $build)"

git add Engram/Engram.xcodeproj/project.pbxproj
git commit -m "chore(release): v$version"
git tag -a "v$version" -m "Engram v$version"
git push origin HEAD
git push origin "v$version"

echo "✓ pushed v$version — GitHub Actions will build, notarize, and publish it."
