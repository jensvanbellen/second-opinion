# second-opinion

One `/second-opinion` skill that lets your coding agent ask a *different*
coding agent for an independent review — Claude Code asks Codex, Codex asks
Claude Code.

Reviewing a PR in Claude Code and want to know what Codex would flag? Deep into
a branch and want fresh eyes before opening the PR? Run `/second-opinion`. The
agent figures out what the subject is (the PR under review, the current
branch's work, uncommitted changes, or whatever you pass as an argument),
writes a self-contained blind brief, invokes the other agent headlessly against
the same repo, verifies its claims, and reports one merged review: what's new,
what both agree on, and where they disagree. No copy-pasting between terminals.

## Install

```bash
git clone https://github.com/jensvanbellen/second-opinion.git && cd second-opinion && ./install.sh
```

This symlinks the skill into both tools:

| Tool | Location | Invoke |
|------|----------|--------|
| Claude Code | `~/.claude/skills/second-opinion` | `/second-opinion` |
| Codex | `~/.codex/skills/second-opinion` + `~/.codex/prompts/second-opinion.md` | `/second-opinion` |

Both tools read the exact same `skills/second-opinion/SKILL.md` — one source of
truth, no drift. Because they are symlinks, edits to this repo take effect
immediately. `./install.sh --uninstall` removes everything. Restart open
sessions after installing so the skill is picked up.

## Requirements

- Both CLIs installed and authenticated: `claude` and `codex`.
- `gh` CLI (optional) — only needed when the subject is a PR or issue, so the
  briefing agent can pre-fetch it for the sandboxed counterpart.

## Usage

| Command | What happens |
|---------|--------------|
| `/second-opinion` | Auto-detects the subject: active PR review or conversation topic, else current-branch work + uncommitted changes |
| `/second-opinion 123` or `/second-opinion <PR URL>` | Second opinion on that PR |
| `/second-opinion src/foo.py src/bar.py` | Second opinion scoped to specific files |
| `/second-opinion is this migration safe to run twice?` | Free-form question about the work at hand |

Typical flow:

```
# In Claude Code, mid PR review:
/second-opinion
→ briefs Codex blind, waits (a few minutes is normal), verifies its findings,
  reports: 2 new findings (verified), 3 agreed, 1 disputed — with file:line
```

The counterpart runs **read-only** — it can never modify your working tree.

## Design decisions

- **Blind briefing.** The counterpart never sees the first agent's findings or
  hypotheses — anchoring it on those would collapse the two opinions into one.
  The brief contains only the goal, where to look, and what kind of feedback is
  wanted. Sharing your own take requires an explicit ask.
- **The counterpart works the repo, not a paste.** It gets invoked inside the
  same repository with a read-only sandbox, so it reads real code and real
  diffs instead of whatever fit in a copy-paste. Context that lives outside the
  repo (PR description, issue thread, goals discussed in conversation) is
  pre-fetched by the briefing agent and embedded in the brief, because the
  counterpart runs without network access.
- **Reconcile, don't relay.** The first agent must verify the counterpart's
  new claims against the code before presenting them, and must say where it
  disagrees. The deliverable is a merged review with attribution
  (new / agreed / disputed), not a forwarded wall of text.
- **At most one follow-up round.** If a material disagreement remains, exactly
  one clarifying exchange is allowed (`codex exec resume --last` /
  `claude -p --continue`). No open-ended agent-to-agent debate loops.
- **Honest failure.** If the counterpart CLI is missing, unauthenticated, or
  errors out, the skill reports that and stops — it never fabricates a second
  opinion.
- **Symlink install, one skill file.** Same pattern as
  [agent-handoff](https://github.com/jensvanbellen/agent-handoff): both tools
  read the identical SKILL.md, the Codex prompt is a thin pointer so
  `/second-opinion` is guaranteed as a slash command there too.

## Repo layout

```
skills/second-opinion/SKILL.md    # the skill — single source of truth
codex/prompts/second-opinion.md   # thin Codex slash-command pointer
install.sh                        # symlinks into ~/.claude and ~/.codex
```
