# Autopilot run ledger: entries, validity, convergence, and the evals metric

The rules autopilot applies to its ledger, the open `octoperator-ledger` issue
(`${CLAUDE_PLUGIN_ROOT}/skills/autopilot/SKILL.md` → Run ledger and convergence, which holds the
entry's shape, the commands, and what happens when every eval passes).
`scripts/octo-ledger-state.sh` applies them, and `scripts/octo-evals-metric.sh` reads the metric.

## Entry fields

- `time` — UTC, ISO 8601, read from `gh` just before posting (SKILL.md step 5's recipe).
- `mode` — the run's `--mode`.
- `cycles_used`, `merged`, `held`, `proposals_filed` — the run's counts (all `0` for `observe` and
  `reset` entries).
- `metric` — the evals pass rate, `{"passed": P, "total": T}` ([Evals metric](#evals-metric)), or
  `null` when the repo has no evals workflow or the rate can't be read. A repo genesis didn't
  create, such as Octoperator's own, has none, so its entries keep `null`.
- `cost_usd` — always `null`: autopilot can't read its own spend. A `claude -p --output-format json`
  run reports it as `total_cost_usd`, where a wrapper could pick it up.
- `kind` — `run` (a normal run, or one that planned the next milestone), `observe` (a converged
  run, or an all-pass run that waits, SKILL.md step 3), or `reset` (`--resume`).
- `planning_failed` — optional, and only on a `run` entry whose next-milestone planning stopped
  before opening a PR: `{"tip": "<the 40-digit commit it planned at>", "reason": "<genesis's
  stopped: reason>"}` ([milestone.md → Planning](milestone.md#planning)). The newest valid `run`
  or `reset` entry decides; `observe` entries are passed over, since they plan nothing. When it is
  a `run` entry with this key, `octo-ledger-state.sh` prints its tip and reason as
  `planning-failed:`, and the milestone gate observes while the default branch's tip is still that
  commit. A `reset` entry, or a newer `run` entry without the key, clears it. A malformed value
  counts as absent.

## Valid entries

People comment on the ledger too, and on a public repo anyone can. Count a comment as an entry
only if its `authorAssociation` is `OWNER`, `MEMBER`, or `COLLABORATOR` and its body holds one
fenced `json` block that parses to an object with the nine required keys above (all but
`planning_failed`) and a `kind` from the list. Extra keys don't matter.
Skip every other comment. Entries post under the `gh` login that runs autopilot, so that login
needs one of those roles. A local run under your own login has it; a bot account without one (e.g.
`github-actions[bot]`) does not, and autopilot then skips its own entries and never converges.

## Convergence

A metric is **numeric** when it is an object whose `passed` and `total` are whole numbers with
0 ≤ `passed` ≤ `total` and `total` ≥ 1, and **all-pass** when `passed` equals
`total`; any other value counts as no metric. Compare each valid entry with the previous valid
entry (the next older one, of any kind). The entry **gains**:
- never, when it is an `observe` entry;
- when both have a numeric metric, only if `passed` rose. The count, not the ratio: a new
  must-fail eval lowers the ratio without being a regression, and a merge that moves no eval is
  no progress;
- otherwise (no evals, or a metric on one side only), when `merged` is at least 1.

Walk the valid entries newest first, stopping at the first `reset` or all-pass entry. Autopilot is
**converged** when the walk finds at least N entries before it stops and none of the newest N
gains, where N is the `convergence_runs` setting (default `3`). Fewer than N entries means not
converged. `observe` entries never gain, so once converged, autopilot stays in observe mode until a
human passes `--resume`, or every eval passes (SKILL.md → Run ledger → All evals pass). An all-pass
entry ends the walk because it closes a milestone: once the next one adds failing evals, progress counts from
there, and the runs spent waiting while every eval passed are not held against it.

## Evals metric

A repo has the evals workflow when its default branch holds `.github/workflows/evals.yml`, the file
genesis writes. Autopilot detects it by that path, not by
the workflow's name, which the repo can change and which `Evals (model)` nearly shares. The metric
is read from that workflow's latest completed default-branch run that a `push` or
`workflow_dispatch` in this repo started (never a fork's `pull_request` run): its jobs, then their
check runs' annotations. Only exactly one `notice` annotation titled `evals-metric` whose message
is exactly `passed=<P> total=<T>`, with P ≤ T and T ≥ 1, counts, and only when the run's
conclusion agrees (`run.sh` exits 0 exactly when every eval passes): `success` for P == T,
`failure` for P < T. Anything else leaves `metric` `null` with the reason and never fails the run.
The run's head commit is the `head:` that the milestone gate compares with the default branch's
tip (SKILL.md → Run ledger → All evals pass).
