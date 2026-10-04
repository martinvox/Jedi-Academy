#!/bin/sh
# Commits and pushes any uncommitted work every N seconds (default 300) so a
# session can be resumed elsewhere. Usage: port/tools/autosave.sh [branch] [seconds]
BRANCH=${1:-$(git rev-parse --abbrev-ref HEAD)}
INTERVAL=${2:-300}
cd "$(git rev-parse --show-toplevel)" || exit 1
while true; do
	sleep "$INTERVAL"
	if [ -n "$(git status --porcelain -- port docs)" ]; then
		git add -A port docs
		git commit -q -m "WIP autosave: Godot port in progress" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_018FUsYbkTTPy1nTo1mmM2Qb" && git push -q -u origin "$BRANCH"
	fi
done
