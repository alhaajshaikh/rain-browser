#!/bin/sh
# Merge upstream into a committed feature branch, keeping the AVKit additions.
# Never resets, rebases, stashes, force-pushes, or replaces an installed app.
set -eu

case "${1:---help}" in
  --check|--merge) action="$1" ;;
  --help|-h)
    cat <<'HELP'
Usage: tools/development/update-native-video.sh --check | --merge

--check  Read the latest upstream main revision without changing your checkout.
--merge  Fetch and merge upstream main into your clean, committed feature branch.

Commit your native-video changes on a branch before using --merge. If a merge
conflicts, resolve it and commit, or run git merge --abort. Then rebuild/sideload
your custom app. Installing the official IPA removes these local additions.
HELP
    exit 0 ;;
  *) echo "Unknown option. Use --help." >&2; exit 2 ;;
esac

task_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$task_root"
upstream_url=https://github.com/minh-ton/reynard-browser.git

if [ "$action" = --check ]; then
  git ls-remote --exit-code "$upstream_url" refs/heads/main
  exit 0
fi

branch=$(git symbolic-ref --quiet --short HEAD) || {
  echo "Create a feature branch before merging upstream." >&2; exit 1;
}
case "$branch" in
  main|master) echo "Use a feature branch, for example git switch -c native-avkit-video." >&2; exit 1 ;;
esac
if [ -n "$(git status --porcelain)" ]; then
  echo "Commit or move your local changes before merging upstream." >&2
  exit 1
fi
if [ -f "$(git rev-parse --git-path MERGE_HEAD)" ]; then
  echo "Finish or abort the current merge first." >&2; exit 1
fi

git fetch --no-tags "$upstream_url" main
git merge --no-edit FETCH_HEAD
cat <<'NEXT'
Upstream merged. Review the result and run the native-video bridge tests.

If Gecko's pinned release changed, rebuild the engine before building the app:
  ./tools/development/update-gecko.sh
  ./tools/development/apply-patches.sh
  ./tools/development/build-idevice.sh
  ./tools/development/build-gecko.sh

Then build Reynard in Xcode and sideload your custom IPA with its app extensions.
NEXT
