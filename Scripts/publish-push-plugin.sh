#!/usr/bin/env bash
# Publishes Tools/hermes-app-push to its public repo (UltraInstinct0x/hermes-app-push), the source
# `hermes plugins install UltraInstinct0x/hermes-app-push` reads. The plugin holds no secrets: the relay
# issues each gateway its own secret at runtime.
#
# Usage: Scripts/publish-push-plugin.sh "commit message"
set -euo pipefail
cd "$(dirname "$0")/.."
MESSAGE="${1:?commit message}"
REPO="UltraInstinct0x/hermes-app-push"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git clone --quiet "https://github.com/$REPO.git" "$WORK/repo"
rsync -a --delete --exclude .git --exclude .claude --exclude .pytest_cache --exclude __pycache__ --exclude '*.pyc' Tools/hermes-app-push/ "$WORK/repo/"
cd "$WORK/repo"
git add -A
if git diff --cached --quiet; then
  echo "nothing to publish"
  exit 0
fi
# Public commits carry the GitHub noreply address, never a personal email.
NOREPLY_EMAIL="63316492+UltraInstinct0x@users.noreply.github.com"
GIT_AUTHOR_EMAIL="$NOREPLY_EMAIL" GIT_COMMITTER_EMAIL="$NOREPLY_EMAIL" git commit -q -m "$MESSAGE"
git push -q origin HEAD
echo "published $(git rev-parse --short HEAD) to $REPO"
# The app installs a pinned commit (AppPlugin.push in HermesKit, docs/plugins.md §7).
echo "to have the app install it: bump the version, then set AppPlugin.push ref to $(git rev-parse HEAD)"
