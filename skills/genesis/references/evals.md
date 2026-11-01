# Genesis scenario evals

Product-level tests that judge the product itself, not one function: in the character-chat app,
that the context built at turn 200 still holds a fact the user stated at turn 3. They give the new
repo an evidence source after the MVP. A failing run on the default branch is `eval` evidence for
`research`, and the number passing is the metric that shows the product moving.

`/octoperator:genesis --approve` writes them at stage 3, with the skeleton, before the first
commit. `${CLAUDE_PLUGIN_ROOT}/scripts/octo-genesis-check.sh --skeleton <dir>` checks them; the
rules it enforces are marked **checked**. Nothing here runs a model: `judge: model` scenarios exist
in the format, and a later stage (#91) adds the runner a human dispatches for them.

## Files

What stage 3 writes into the new repo, each only when missing:

| Path | From |
|---|---|
| `evals/run.sh` | `${CLAUDE_PLUGIN_ROOT}/skills/genesis/templates/evals/run.sh`, verbatim |
| `evals/guard.sh` | `${CLAUDE_PLUGIN_ROOT}/skills/genesis/templates/evals/guard.sh`, verbatim |
| `.github/workflows/evals.yml` | its template, plus the stack's setup steps |
| `.github/workflows/evals-guard.yml` | its template, plus the stack's setup steps |
| `evals/<id>/scenario.md` | one per `docs/prd.md` scenario |
| `evals/<id>/check.sh` | one per `judge: script` scenario |

- **`run.sh` and `guard.sh`.** Read each template and Write it unchanged. **Checked:** byte for
  byte the template.
- **The workflows.** Read each template and Write it with the one line
  `# genesis: the stack's setup and install steps from ci.yml` replaced by the same setup and
  install steps as `ci.yml` (`actions/setup-node` and `npm install`, …), so a check can run the
  app. Change nothing else. **Checked:** every line of the template except comments and blank
  lines, in order; `evals.yml` triggers on exactly `push` (with `branches: [main]`) and
  `workflow_dispatch`; and `evals-guard.yml` triggers on exactly `pull_request`.
- **One eval per scenario.** **Checked:** each `docs/prd.md` scenario has its `scenario.md`, and
  each `judge: script` scenario has its `check.sh`, which parses (`bash -n`). The check never runs
  it. An eval that fails on the bare skeleton is expected: that failure is what pushes the work
  forward.

## In the PRD: `## Scenarios`

The PRD's last section, required (**checked** by the proposal check, `octo-genesis-check.sh
<dir>`). Format: `references/proposal.md`. Each scenario has its id as a `### ` heading, then one
`- requirement: R<n>` line naming the requirement it covers, one `- judge: script` or
`- judge: model` line, and the scenario text. At least one is `judge: script`, or the metric has
nothing to count.

Prefer `judge: script`: write a scenario a script can decide, such as one that runs the app with a
stub model and checks what it built. Use `judge: model` only when no script can judge it, such as
whether the replies keep a tone.

## `evals/<id>/scenario.md`

```markdown
---
id: recall-turn-3
judge: script
requirement: R1
---

At turn 200 of a conversation with a stub model, the context still holds the turn-3 fact.
```

- **Checked:** the front matter has the lines `id: <id>`, `judge: script` or `judge: model`, and
  `requirement: R<n>`, exactly as the PRD's scenario says, then the scenario's text. Write the
  PRD's text as it is.
- `<id>` is lowercase kebab-case and names the directory, as bench's task ids do.

## `evals/<id>/check.sh`

`bash evals/<id>/check.sh <repo-dir>` judges a checkout of the repo. These rules are
[bench's check rules](../../../bench/README.md#checksh), reused as they are:

- Exit 0 only when the scenario holds, 1 when it fails, 2 on bad arguments. Print one `FAIL:` line
  per problem.
- Check **behavior, not implementation**: run the code on the check's own inputs instead of
  matching source text, so any correct build passes.
- Work in a `mktemp -d` directory, and leave no files in `<repo-dir>`.
- Don't depend on the working directory or on `<repo-dir>` being a git repo.
- Fail before the work is done. Bench's check must fail on its seed; an eval must fail on the
  default branch when it is added (the guard below enforces it).

What differs from bench, and why:

- **No seed, no `solution.patch`.** The repo is the seed, and the MVP epic's issues are the work.
- **The stack's runtime, not only bash and Python.** A check runs the product, so it may use the
  runtime CI set up (`node`, `go`, …). It installs nothing itself.
- **No `make test` inside the check.** CI already runs the test command on every push and PR.
- **Its inputs live beside it**, in `evals/<id>/`, never in the repo's own tree: the guard keeps
  `evals/` append-only, which protects nothing outside it.

## Why not `octo-bench.sh`

`scripts/octo-bench.sh` measures Octoperator itself: it creates throwaway GitHub repos, files the
task as an issue, runs `/octoperator:auto` with a live model, spends real money, and deletes the
repos after. An eval judges one product in its own repo, offline, on every push to the default
branch, so it needs none of that. Genesis reuses bench's **format** (a task with a hidden check)
and its **must-fail-first** rule, not its harness.

## `evals/run.sh`

`bash evals/run.sh [repo-dir]` runs every `judge: script` eval against the repo (default: the
directory above `evals/`) and skips `judge: model` ones. Each check runs as bench's validator runs
checks: from a neutral `mktemp -d` directory, stdin from `/dev/null`, in its own process group,
killed with every process it started after `EVALS_CHECK_TIMEOUT` seconds (default 120). A check
passes only on exit 0; a timeout, exit 2, or a missing `check.sh` counts as failed.

It ends with:

```text
evals: <passed>/<total> passed (<skipped> skipped)
::notice title=evals-metric::passed=<passed> total=<total>
```

`<total>` counts the script evals. The notice is printed only under GitHub Actions
(`GITHUB_ACTIONS=true`). It exits 1 when any script eval fails, so the workflow run fails.

## The workflows and their triggers

- **`evals.yml`** runs `bash evals/run.sh` on `push` to `main` and on `workflow_dispatch`. It never
  runs on `pull_request`. `auto`'s merge gate holds a PR whose checks aren't green (`UNSTABLE`),
  and every eval fails until its work lands, so a `pull_request` trigger would hold every PR,
  the one that makes the eval pass included. The cost is that a regression shows up after the
  merge, on the default branch, as a failing run.
- **Evidence.** `research` reads the latest completed run of each workflow on the default branch
  and files from a failing one (its `eval` evidence type). That is `evals.yml`'s run, so research
  needs no change.
- **`evals-guard.yml`** runs on `pull_request`, never `pull_request_target`, with read-only
  permissions. It checks out the full history and runs the **base branch's** `evals/guard.sh`
  (`git show "$BASE_SHA:evals/guard.sh"`), so a PR can't change the guard that judges it.

## The guard

`bash evals/guard.sh <base> <head>` looks at the PR's own changes under `evals/`: `git diff
--name-status --no-renames` from the merge base of `<base>` and `<head>` to `<head>`. An eval the
default branch gained after the PR branched is not one the PR deletes. It fails when:

- the PR modifies, deletes, or renames any file under `evals/`, `run.sh` and `guard.sh` included
  (a rename shows as a delete);
- the PR adds a file to an eval directory that already exists;
- a new eval's `scenario.md` is missing, or its front matter lacks `id: <id>` (kebab-case),
  `judge: script` or `judge: model`, or `requirement: R<n>`;
- a new `judge: script` eval has no `check.sh`, or one that doesn't parse;
- a new `judge: script` eval's `check.sh` **passes** on the base, or times out there. Bench's
  validator requires each check to fail on its seed; the guard requires each new eval to fail on
  the default branch. It runs the head's copy of the check against a `git archive` of the base,
  sandboxed as `run.sh` runs checks. The base copy has the runtime CI set up, but not the
  head's installed dependencies (`node_modules/`, …). A check that needs them fails there for
  that reason alone, so the guard can't tell whether it already passes: keep a check to the
  runtime and the code it runs where you can.

A new `judge: model` eval is format-checked only. A failing guard makes the PR `UNSTABLE`, so
`auto` holds it. Weakening an eval, or changing the runner or the guard, then takes a human.

**Append-only additions merge automatically.** `approval_paths` holds the guard workflow, not
`evals/`: genesis's settings list `.github/workflows/`, which covers
`.github/workflows/evals-guard.yml` and `evals.yml`, so `auto` never merges a change to either
without a human. `evals/` stays out, so a PR that only adds must-fail evals merges like any other.
The new repo's `VISION.md` says the same in its quality bar: the passing count never drops, and
evals only grow.
