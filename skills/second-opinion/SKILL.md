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

Then classify the subject as **code** (a repo, PR, branch diff, or files) or
**non-code** (a document, a message draft, or free-form prose the user pasted).
This choice drives the command form in step 5 and the output format in step 4:
a non-code subject has no `file:line` and no git diff, so embed the text in the
brief and ask for a critique rather than a rewrite.

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
  (blocker / major / minor / nit), a location (`file:line` for code; where
  applicable otherwise), and reasoning — followed by a short overall verdict.
  Say explicitly: "if you find nothing significant, say so plainly rather than
  inventing issues". For a non-code subject (a document, message, or prose),
  ask for a critique with concrete findings, not a rewrite of the material.

**The counterpart is the sole reviewer — say so, and keep trigger phrases out of
the brief.** The counterpart very likely has this same skill installed. If the
brief contains "second opinion", "counterpart", or "blind review", it re-triggers
the protocol and tries to delegate to *another* agent (`claude -p`, a sub-agent),
which then fails on auth or the read-only sandbox and leaves the output file
holding only an apology instead of a review. So: call it "a code review request",
and state plainly that it must review directly and must not run any skill,
workflow, or agent/CLI (no `claude`, no `codex`, no sub-agents, no "second
opinion" process) — it is the only reviewer.

**Do not include your own findings, hypotheses, or draft review.** An independent
review is the whole point — anchoring the counterpart on your conclusions
destroys the value of the second opinion. Only pass along something the user
explicitly asked you to relay.

## 5. Invoke the counterpart

**Smoke-test the counterpart before the full review.** Codex can hang on startup
with zero output and 0% CPU (a stale in-progress update, a macOS
permission/Gatekeeper prompt, or a hanging codex MCP server can all cause it). A
hung process never writes `$OUT` and never exits, so the poll loop below would
wait forever. Catch it first with a fast liveness check under a short (~15s)
watchdog. GNU `timeout` is **not** installed on macOS by default (`command not
found`, exit 127), so use a portable shell watchdog — background the process,
keep its pid, poll `kill -0`, `kill -9` on the deadline — or `gtimeout` if
coreutils is installed, never a bare `timeout`. Redirect `</dev/null` so a
non-prompt check cannot block on an inherited pipe stdin:

```bash
# Claude Code side: liveness of codex. From Codex, use `claude --version` instead.
codex --version </dev/null >/dev/null 2>&1 &
p=$!
for _ in $(seq 15); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
if kill -0 "$p" 2>/dev/null; then kill -9 "$p" 2>/dev/null; startup_hang=1; fi
```

If the check does not return within the watchdog, the binary is hanging on
startup: do **not** launch the 5-20 min review. Tell the user the counterpart is
hanging on startup and how to fix it (reinstall, clear a stale in-progress
update, or answer a pending macOS permission/Gatekeeper prompt), then stop.

Run it read-only and **always in the background** — never in the foreground. A
substantial diff review routinely takes 5-20 minutes; a foreground run is killed
at the harness 10-minute wall (`Exit code 143`), and because codex writes `-o`
only at the very end, the whole run is lost with an empty output file. Launch it
detached to output and log paths you control, then poll it on a guarded loop —
one that trips on a startup hang, a stall, and a runaway ceiling, so it never
spins forever.

**Run the launch-plus-poll block itself as a background job** (your harness's
`run_in_background`, or a detached `setsid`/`&` script), never as one blocking
foreground call. The poll loop below runs for as long as the review does, so a
foreground invocation of it hits the very 10-minute wall described above and the
monitor dies before its own guards fire. It also writes the kill reason to a
file, so a later step in a fresh shell can still report why the run ended.

**From Claude Code (counterpart = Codex):**

```bash
# $BRIEF already written. Own the paths so polling targets them directly.
OUT=$(mktemp) LOG=$(mktemp) marker=$(mktemp)   # marker = "session files after launch"
REPO=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
nohup codex exec --sandbox read-only --skip-git-repo-check -C "$REPO" \
  -o "$OUT" - < "$BRIEF" > "$LOG" 2>&1 &
pid=$! start=$(date +%s)
last_size=0 last_change=$start reason=running

# Poll ~every 30s. Guards keep this from spinning forever WITHOUT killing a
# slow-but-working review: codex streams progress to $LOG, so a growing log
# means it is alive. Kill only on a startup hang, a stall (no log growth for
# STALL_SECS), or a runaway (absolute CEIL_SECS backstop) — never on total
# elapsed alone, since a large diff can legitimately run past any fixed cap.
# STALL_SECS is a heuristic: a genuinely silent model turn can trip it and a
# process that emits periodic noise can dodge it, so tune it to your reviews;
# CEIL_SECS is only the last-resort backstop against an infinite wait.
STALL_SECS=420 CEIL_SECS=3600
while kill -0 "$pid" 2>/dev/null; do
  now=$(date +%s) elapsed=$(( now - start ))
  size=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  [ "$size" -gt "$last_size" ] && { last_size=$size; last_change=$now; }
  # Startup hang: no log output AND no new session file within ~90s -> kill.
  if [ "$elapsed" -ge 90 ] && [ ! -s "$LOG" ] && \
     [ -z "$(find ~/.codex/sessions -name 'rollout-*.jsonl' -newer "$marker" 2>/dev/null)" ]; then
    reason=startup_hang; kill -9 "$pid" 2>/dev/null; break
  fi
  # Stall: no log growth for STALL_SECS past the 90s startup grace. No
  # `last_size > 0` guard, so a process that opens a transcript then goes silent
  # without ever writing $LOG is caught here too (not left to the ceiling).
  if [ "$elapsed" -ge 90 ] && [ $(( now - last_change )) -ge "$STALL_SECS" ]; then
    reason=stalled; kill -9 "$pid" 2>/dev/null; break
  fi
  # Runaway backstop only — not a normal-run deadline. Raise if your reviews
  # legitimately run longer; a live review keeps resetting the stall timer.
  if [ "$elapsed" -ge "$CEIL_SECS" ]; then reason=timed_out; kill -9 "$pid" 2>/dev/null; break; fi
  sleep 30
done
[ "$reason" = running ] && reason=exited
printf '%s\n' "$reason" > "$OUT.reason"   # readable by a later step in a fresh shell
```

After the loop, `$OUT.reason` is one of `exited` (codex returned on its own),
`startup_hang`, `stalled`, or `timed_out`. Branch on it: `exited` -> trust `$OUT`
(still verify it below); the three kill reasons -> attempt the recovery below,
and if that yields nothing, tell the user the run was killed and why (name the
reason) rather than reporting an empty review as "no findings".

`--skip-git-repo-check` is required: without it codex refuses with *"Not inside a
trusted directory"* whenever `-C` is not a checked-out repo (a scratchpad, a doc,
a pasted message). For a non-code subject, point `-C` at the directory holding
the material (or `pwd`) and embed the text itself in the brief. (If your own
shell sandbox blocks codex's API access, rerun unsandboxed — codex still enforces
its own read-only sandbox on the repo.)

**From Codex (counterpart = Claude Code):** this path needs the same protections
as the codex path above — it too can hang or run long. Initialize its own paths
(do not rely on the codex block's `$OUT`/`$LOG`), launch it detached, and poll it
with the identical guarded loop (startup-hang / stall / ceiling, `$OUT.reason`),
also as a background job.

```bash
OUT=$(mktemp) LOG=$(mktemp) start=$(date +%s) last_size=0 last_change=$start reason=running
nohup claude -p --allowedTools "Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*),Bash(git branch:*),Bash(git merge-base:*)" \
  < "$BRIEF" > "$OUT" 2> "$LOG" &
pid=$!
# then the SAME poll loop as the codex path, watching $LOG for growth. claude
# streams its answer to $OUT, so there is no separate transcript to recover from:
# on a stall/ceiling kill, whatever is already in $OUT is the partial review.
```

**Verify the output before trusting it.** `-o` captures only codex's *last*
message, which is the review only on a clean run. After it exits, confirm `$OUT`
is non-empty and actually reads like a review (numbered findings / a verdict) —
not an auth or delegation apology ("couldn't complete the second-opinion
workflow", "Not logged in"), and not a rewrite of the material. If it is empty or
an apology: inspect `$LOG`; if codex tried to delegate to another agent, rerun
with the sole-reviewer brief from step 4.

**Recover a review lost to a hang or kill (codex path).** `-o` writes only
codex's final message, and only at the very end, so any kill reason
(`startup_hang` / `stalled` / `timed_out`) leaves `$OUT` empty even though the
work happened. The session transcript still holds it. Two rules matter: pick the
transcript from **this** launch (newer than `$marker`), not the globally newest —
otherwise you can recover a stale prior run or a concurrent codex process — and
extract the message **whole**, not line-oriented (`tail -1` would keep only the
last physical line of a multiline review and silently drop every finding).

```bash
# Newest transcript from THIS launch only; -print0/-0 is whitespace-safe and
# picks the single newest file (plain `find | xargs ls` can split into batches).
sess=$(find ~/.codex/sessions -name 'rollout-*.jsonl' -newer "$marker" -print0 2>/dev/null \
  | xargs -0 ls -t 2>/dev/null | head -1)
# Slurp the JSONL (-s) and take the LAST task_complete message as one whole value.
recovered=$(jq -rs 'map(select(.payload.type=="task_complete")) | last | .payload.last_agent_message // empty' "$sess" 2>/dev/null)
[ -z "$recovered" ] && recovered=$(jq -rs '[.[] | .. | objects | .last_agent_message? // empty] | last // empty' "$sess" 2>/dev/null)
```

If nothing usable can be recovered — the invocation failed on auth, network, or a
missing binary, or the transcript holds no review — report the error to the user
verbatim and stop. Never fabricate or paraphrase a second opinion that did not
actually run.

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
