#!/usr/bin/env bash
# Install (or uninstall) the /second-opinion skill for Claude Code and Codex.
#
# Both tools understand the same SKILL.md format, so the skill directory is
# symlinked into each tool's skills directory — one source of truth, and edits
# to this repo take effect immediately without reinstalling.
#
# Codex additionally gets a thin custom prompt so /second-opinion is always
# available as a slash command there.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLAUDE_SKILLS_DIR="${CLAUDE_HOME:-$HOME/.claude}/skills"
CODEX_SKILLS_DIR="${CODEX_HOME:-$HOME/.codex}/skills"
CODEX_PROMPTS_DIR="${CODEX_HOME:-$HOME/.codex}/prompts"

remove_link() {
  local dest=$1
  if [[ -L "$dest" ]]; then
    rm -- "$dest"
    echo "Removed $dest"
  elif [[ -e "$dest" ]]; then
    echo "SKIP: $dest exists and is not a symlink — leaving it untouched." >&2
  fi
}

if [[ "${1:-}" == "--uninstall" ]]; then
  remove_link "$CLAUDE_SKILLS_DIR/second-opinion"
  remove_link "$CODEX_SKILLS_DIR/second-opinion"
  remove_link "$CODEX_PROMPTS_DIR/second-opinion.md"
  exit 0
fi

link() {
  local target=$1 dest=$2
  if [[ -e "$dest" && ! -L "$dest" ]]; then
    echo "SKIP: $dest exists and is not a symlink — remove it manually first." >&2
    return 1
  fi
  ln -sfn "$target" "$dest"
  echo "Linked $dest -> $target"
}

mkdir -p "$CLAUDE_SKILLS_DIR" "$CODEX_SKILLS_DIR" "$CODEX_PROMPTS_DIR"

link "$REPO_DIR/skills/second-opinion" "$CLAUDE_SKILLS_DIR/second-opinion"
link "$REPO_DIR/skills/second-opinion" "$CODEX_SKILLS_DIR/second-opinion"
link "$REPO_DIR/codex/prompts/second-opinion.md" "$CODEX_PROMPTS_DIR/second-opinion.md"

echo
echo "Done. Invoke with /second-opinion in Claude Code and Codex."
