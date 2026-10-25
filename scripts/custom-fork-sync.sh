#!/usr/bin/env bash
set -euo pipefail
umask 077

# Credentials stay on this host; all dependency installation, builds and tests run on homepc.
state=/root/.local/state/paseo-fork-sync
mkdir -p "$state"
exec 9>"$state/lock"
flock -n 9
ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ControlPath=none homepc bash -s <<'REMOTE'
set -euo pipefail
state=/root/.local/share/paseo-fork-sync
repo="$state/repo"
export PATH="$state/node/bin:$state/claude/bin:$PATH"
exec 8>"$state/lock"
flock -n 8
cd "$repo"
test -z "$(git status --porcelain)" || { echo 'Dirty maintenance checkout; nothing overwritten' >&2; exit 1; }
test "$(git branch --show-current)" = custom
git fetch origin custom:refs/remotes/origin/custom main:refs/remotes/origin/main
git merge --ff-only origin/custom
git fetch https://github.com/getpaseo/paseo.git main
upstream=$(git rev-parse FETCH_HEAD)
if test "$(git rev-parse HEAD)" = "$(git rev-parse origin/custom)" &&
   test "$(git rev-parse origin/main)" = "$upstream" &&
   git merge-base --is-ancestor "$upstream" HEAD; then
  printf '{"status":"unchanged","custom":"%s","upstream":"%s"}\n' "$(git rev-parse HEAD)" "$upstream" > "$state/receipt.json"
  exit 0
fi
# Conflicts and failed checks remain available for repair. Never reset or discard them.
git merge --no-edit "$upstream"
export ONNXRUNTIME_NODE_INSTALL=skip ELECTRON_SKIP_BINARY_DOWNLOAD=1
npm ci --ignore-scripts --no-audit --no-fund > "$state/verification.log" 2>&1
npm run postinstall >> "$state/verification.log" 2>&1
npm run build:server >> "$state/verification.log" 2>&1
npm run typecheck:server >> "$state/verification.log" 2>&1
npm run lint >> "$state/verification.log" 2>&1
npm exec --workspace=@getpaseo/server -- vitest run \
  src/server/agent/providers/claude/agent.test.ts \
  src/server/agent/providers/claude/agent.history-load.test.ts \
  scripts/supervisor.readiness.test.ts --bail=1 >> "$state/verification.log" 2>&1
git diff --quiet
git diff --cached --quiet
git bundle create "$state/candidate.bundle" custom ^origin/main
printf '{"status":"verified","custom":"%s","upstream":"%s"}\n' "$(git rev-parse HEAD)" "$upstream" > "$state/receipt.json"
REMOTE
rsync -a -e 'ssh -o BatchMode=yes -o ConnectTimeout=15 -o ControlPath=none' \
  homepc:/root/.local/share/paseo-fork-sync/receipt.json "$state/receipt.json"
status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$state/receipt.json")
if test "$status" = unchanged; then
  cat "$state/receipt.json"
  exit 0
fi
test "$status" = verified
rsync -a -e 'ssh -o BatchMode=yes -o ConnectTimeout=15 -o ControlPath=none' \
  homepc:/root/.local/share/paseo-fork-sync/candidate.bundle "$state/candidate.bundle"
mirror="$state/publish.git"
if ! test -d "$mirror"; then git init --bare "$mirror"; fi
git -C "$mirror" fetch --depth=100 https://github.com/Philip320/paseo.git main:refs/heads/main
git -C "$mirror" fetch "$state/candidate.bundle" custom:refs/heads/custom
candidate=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["custom"])' "$state/receipt.json")
upstream=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upstream"])' "$state/receipt.json")
test "$(git -C "$mirror" rev-parse custom)" = "$candidate"
git -C "$mirror" -c 'credential.helper=!gh auth git-credential' push --atomic \
  https://github.com/Philip320/paseo.git "$candidate:refs/heads/custom" "$upstream:refs/heads/main"
git -C "$mirror" ls-remote https://github.com/Philip320/paseo.git refs/heads/custom refs/heads/main > "$state/remote-refs"
python3 -c 'import sys; refs=dict(line.split()[::-1] for line in open(sys.argv[1])); assert refs["refs/heads/custom"] == sys.argv[2]; assert refs["refs/heads/main"] == sys.argv[3]' "$state/remote-refs" "$candidate" "$upstream"
cat "$state/receipt.json"
