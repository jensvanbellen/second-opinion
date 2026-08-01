---
name: second-opinion
description: >-
  Get an independent second opinion on the work at hand from a different coding
  agent (Codex when running in Claude Code, Claude Code when running in Codex).
  Figures out the review subject automatically — a PR under review, the current
  branch's work, uncommitted changes, or a specific issue or question — briefs
  the other agent blind, then reconciles both reviews into one merged report.
  Use when the user says "second opinion", "what does codex think", "what does
  claude think", "cross-check this", or wants independent eyes before merging.
license: MIT
---

# Second Opinion Protocol

Purpose: have a *different* coding agent independently review the work at hand,
then reconcile its findings with your own view into a single merged report. The
counterpart is briefed blind — it never sees your conclusions — so its opinion
is genuinely independent, and disagreement between the two of you is signal,
not noise.

## 1. Identify the counterpart

You brief whichever agent you are not:

| You are | Counterpart | Availability check |
|---------|-------------|--------------------|
| Claude Code | Codex | `command -v codex` |
| Codex | Claude Code | `command -v claude` |

If you are some third agent, use whichever of the two is installed. If the
counterpart binary is missing, tell the user which one is needed and stop.

## 2. Determine the subject

First match wins:

1. **Explicit argument** — a PR number/URL, issue reference, file paths, or a
   free-form question passed with the command.
2. **Conversation context** — the thing actively worked on or reviewed in this
   session: the PR you were just reviewing, the feature being built, the bug
   being chased.
3. **Repo state** — work on the current branch: commits not on the default
   branch (`git log --oneline main..HEAD`, falling back to `master`) plus
   uncommitted changes (`git status --short`, `git diff --stat`). Non-empty →
   that is the subject.
4. Nothing found → ask the user what needs a second opinion, and stop.

## 3. Pre-fetch external context

The counterpart runs sandboxed: repo files only, no network, no access to this
conversation. Anything that lives outside the repo must be fetched by you now
and embedded in the brief:

- PR subject: `gh pr view <n> --json title,body,baseRefName,headRefName` and
  `gh pr diff <n>` (or make sure the PR branch is checked out locally).
- Issue subject: `gh issue view <n> --json title,body,comments`.
- Goals or acceptance criteria that only exist in this conversation: summarize
  them into the brief yourself.

## 4. Write the brief

Write the brief to a temp file (`mktemp`), never as an inline shell argument —
long text and quoting do not mix. The counterpart knows nothing about this
session, so the brief must stand alone:

- **What the work is:** the goal, and acceptance criteria if known.
- **Where to look:** branch name, the exact diff command to run
  (e.g. `git diff main...HEAD`), key file paths, and any PR/issue text from
  step 3.
- **What kind of opinion:** correctness, design, security, completeness, edge
  cases — or the user's explicit question. Default when unspecified: "thorough
  review of this change; prioritize real problems over style".
- **Output format:** numbered findings, each with a severity
  (blocker / major / minor / nit), `file:line`, and reasoning — followed by a
  short overall verdict. Say explicitly: "if you find nothing significant, say
  so plainly rather than inventing issues".

**Do not include your own findings, hypotheses, or draft review.** A blind
review is the whole point — anchoring the counterpart on your conclusions
destroys the value of the second opinion. Only pass along something the user
explicitly asked you to relay.

## 5. Invoke the counterpart

Run it read-only, from the repo root, and be patient: multi-minute runs are
normal and acceptable. Use a generous timeout (10 minutes); if it may need
longer, run it in the background and poll.

**From Claude Code (counterpart = Codex):**

```bash
BRIEF=$(mktemp) OUT=$(mktemp)   # write the brief into $BRIEF first
codex exec --sandbox read-only -C "$(git rev-parse --show-toplevel)" \
  -o "$OUT" - < "$BRIEF"
```

The final review lands in `$OUT`; stdout is just the progress log. (If your own
shell sandbox blocks codex's API access, rerun the command unsandboxed — codex
still enforces its own read-only sandbox on the repo.)

**From Codex (counterpart = Claude Code):**

```bash
claude -p --allowedTools "Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*),Bash(git branch:*),Bash(git merge-base:*)" \
  < "$BRIEF" > "$OUT"
```

If the invocation fails (auth, network, missing binary), report the error to
the user verbatim and stop. Never fabricate or paraphrase a second opinion that
did not actually run.

## 6. Reconcile — do not just relay

Form your own view of the work first; in most sessions you already have one.
Then classify every counterpart finding:

- **New** — counterpart found it, you had not. Verify each such claim against
  the actual code before presenting it; label anything you could not verify.
- **Agreed** — both of you flagged it. High confidence.
- **Disputed** — you disagree with the counterpart, or it missed something you
  consider important. Say so, with your reasoning.

If one material disagreement remains that changes the verdict, you may send a
single follow-up with that specific point — `codex exec resume --last` from
Claude Code, `claude -p --continue` from Codex — and incorporate the answer.
Never loop beyond that one round.

## 7. Report

Present the merged review, verdict first. Group findings New / Agreed /
Disputed, each with `file:line` and clear attribution: "Codex", "me", or
"both". End with concrete recommended actions. If the second opinion surfaced
nothing new, say exactly that — two independent reviews agreeing is a useful
result, not a failure.
