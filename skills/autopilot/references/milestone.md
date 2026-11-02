# Autopilot when every eval passes: the milestone gate, planning, and shipping

What an autopilot run does once its evals metric is all-pass (P == T)
(`${CLAUDE_PLUGIN_ROOT}/skills/autopilot/SKILL.md` → Run ledger → All evals pass, and step 3).
`scripts/octo-milestone-gate.sh` makes the decision; `genesis --next`
(`${CLAUDE_PLUGIN_ROOT}/skills/genesis/references/next.md`) plans the milestone; `auto --pr`
ships it.

## Web access

Autopilot's `allowed-tools` holds no web tool. A skill's pre-allowed tools last for the whole turn,
not only that skill's steps, and `research`, `implement`, and `auto` run in autopilot's turn while
reading untrusted issue, PR, and code text: a pre-allowed fetch there could carry the private
repo's content out. Invoking genesis through the Skill tool would leak its WebSearch and WebFetch
to the rest of the turn in the same way, so autopilot follows next.md by reference instead.

So under autopilot, `genesis --next` plans **ungrounded** (next.md step 5's fallback): no web call,
`ungrounded: no web access` in the section and the PR. The one exception is when the user's own
permission settings already allow both tools. One call checks them, with next.md step 1's
`<root>`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/octo-web-allowed.sh" <root>
```

It reads the repo's `.claude/settings.json` and `.claude/settings.local.json`, and
`~/.claude/settings.json`; a missing file allows nothing. Genesis's `approval_paths` lists
`.claude/`, so no PR that `auto` merges unattended can add an allow entry there. It prints
`web: allowed` only when, for each of WebSearch and WebFetch, both of these hold:
- a bare entry for it (`"WebSearch"`, `"WebFetch"`) is in a `permissions.allow`;
- no `deny` or `ask` entry in any of those files names it, bare or scoped (such as
  `WebFetch(domain:x)`), since either one wins over an allow.

Only then may it ground, under next.md step 5's caps and rules. A `web: not allowed (<reason>)`
line, or any other exit, means ungrounded. The check doesn't read the CLI's `--allowedTools` or
managed settings. That is the safe direction: an allow there goes unseen, so the run plans
ungrounded more often.

Never call a web tool the check doesn't allow. An in-session schedule would stop on an `ask`
prompt and wait for a human. A `claude -p --permission-prompts none` run gets a denial instead,
which next.md step 5's **Web denied** fallback turns into an ungrounded plan. A grounded milestone
comes from a human running `/octoperator:genesis --next` by hand, under genesis's own
`allowed-tools`.

## The gate's decisions

Step 3 runs discovery (3a) first, so ready work comes before a new milestone. Then it asks the gate,
even with `--resume`. It passes the metric's `rate:` and `head:` values, the number of issues
discovery kept, the ledger state's `planning-failed:` tip (`none` when that line is `none`), and
`--resume` when that flag was passed:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/octo-milestone-gate.sh" --repo "$REPO" --rate <rate> \
  --head <head> --buildable <count> --failed-tip <tip> [--resume]
```

It prints `milestone-pr:`, `tip:`, and `decision:`. A next-milestone PR is a PR from this repo
whose head branch starts with `milestone-`, the branch `genesis --next` opens.

| `decision:` | Why | The run | Status line |
|---|---|---|---|
| `build` | discovery found buildable work | the ledger's decision (step 3), as if not all-pass | as that run ends |
| `plan` | nothing below holds | [Planning](#planning) | `all evals pass → planning next milestone` |
| `open <pr>` | a next-milestone PR waits for its guard and merge | observe, so no second milestone is filed | `stopped: next-milestone PR #<pr> open` |
| `failed` | the last run's planning failed at this tip | observe: the same failure would repeat | `stopped: milestone planning failed at this tip` |
| `declined <pr>` | a human closed the newest milestone PR unmerged, and nothing landed since it was planned, or since it was closed | observe | `stopped: next-milestone PR #<pr> declined` |
| `stale dispatch` | the metric's run judged an older commit than the tip, and no evals run for the tip is queued or running | [dispatch](#dispatching-evalsyml) once, then observe | `stopped: evals metric stale` |
| `stale wait <run>` | the same, with run `<run>` for the tip queued or running | observe | `stopped: evals metric stale` |
| exit 3 | a gh error | observe | `stopped: milestone gate unavailable` |

The stale metric matters because right after a milestone PR merges, the latest completed run still
says P == T for the commit before the merge, and planning then would file the milestone twice.
`failed` lifts once the tip moves or a human passes `--resume`, whose `reset` entry ends it (the
ledger state prints no failed tip). `declined` lifts the same way.

**A P == T run never ends a schedule**: none of these ends `nothing to do` or `converged →
observe` (SKILL.md step 5). So a schedule keeps re-invoking autopilot while the milestone is
planned, merged, and built.

## Dispatching evals.yml

On `stale dispatch`, and at most once per run, start the evals workflow on the default branch's
tip (`<default>` is the default branch, the one the gate's `tip:` is on):

```bash
gh workflow run evals.yml --repo "$REPO" --ref <default>
```

Never dispatch `evals-model.yml`: its model-judged evals spend money, so only a human starts them.
Don't wait for the run or sleep: observe and end as the table says. A later run reads the result,
and the schedule keeps running. A failed dispatch (for example, a token that can't run workflows)
is reported, never fatal. The report's `evals:` line says either `dispatched evals.yml on
<default>` or `evals run <run> for the tip is queued or running`.

## Planning

On `plan`, read next.md and follow it by reference. Run its step 1, then step 3 on with the gate's
`tip:`; its step 2 is the gate just run. Ground or not by [Web access](#web-access). Then, in both
modes, run the `auto` procedure with `--pr <M>` on the PR it opened (never `--dry-run`). auto's
merge gate holds a `milestone-*` PR unless both the evals guard and the milestone check
(`octo-genesis-next.sh --check --head`) pass on the reviewed commit. Then append a `kind: run`
entry (SKILL.md step 5: `cycles_used` 1, and `merged` or `held` 1 by auto's result, else 0),
report, and STOP.

If `--next` stops before opening a PR, the entry's counts are all 0. When the stop would recur on
a retry at the same tip, the entry adds the key
`"planning_failed": {"tip": "<the gate's tip>", "reason": "<the genesis: stopped: reason>"}`, so
the next run observes at that tip rather than repeating the failure
([ledger.md](ledger.md#entry-fields)). Only these stops add it: `not a genesis repo`, `settings
repo mismatch`, `milestone invalid`, `milestone check failed`, `milestone branch exists`, and `git
commit failed`. Any other stop leaves the key out, so the next run retries. A network or `gh`
failure (`git fetch failed`, `gh repo view failed`, `git push failed`, `milestone gate failed`,
`gh pr create failed`) may well pass then. Either way the report gives the reason, and the run
ends `autopilot: stopped: milestone planning failed`. next.md removes its own worktree and local
branch when it stops after creating them.

## Reports

- **Planning run.** It opens with the metric (P/T and its source run). Then come the milestone's
  number and title, its PR's URL, and its grounding (sources read, or `ungrounded: no web
  access`). Then come auto's row for the PR and the entry's comment URL. The next action is none
  once merged, else "inspect held PR #<M>".
- **An all-pass run that observes.** It opens with the gate's reason and its `evals:` line, if
  any. Then come research's ranked proposals, its **Unevidenced (not filed)** list, and the
  entry's comment URL. The next action depends on the decision:
  - `open`: "review next-milestone PR #<pr>, then merge it or run `/octoperator:auto --pr <pr>`".
  - `stale`: "re-run once the evals run for the tip completes".
  - `failed`: "fix what stopped planning (the last entry's reason), then push, or re-run with
    `--resume`".
  - `declined`: "push to the default branch or re-run with `--resume` to plan again, or run
    `/octoperator:genesis --next` by hand".
- **Entry summaries.** For example: `Autopilot observe: all evals pass (5/5), next-milestone PR #31
  open.`, or `Autopilot run (semi): all evals pass (5/5), planned milestone 2 in PR #31; merged
  #31.`
