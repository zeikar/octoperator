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
| `.github/workflows/evals-guard.yml` | its template, plus the stack's setup steps in its `must-fail` job |
| `evals/<id>/scenario.md` | one per `docs/prd.md` scenario |
| `evals/<id>/check.sh` | one per `judge: script` scenario |

- **`run.sh` and `guard.sh`.** Read each template and Write it unchanged. **Checked:** byte for
  byte the template.
- **The workflows.** Read each template and Write it with the one line
  `# genesis: the stack's setup and install steps from ci.yml` replaced by the same setup and
  install steps as `ci.yml` (`actions/setup-node` and `npm install`, …), so a check can run the
  app. Change nothing else: in `evals-guard.yml` that line is in the `must-fail` job only, and the
  other two jobs must stay free of setup steps, since setup runs the PR's code. **Checked:** the
  file is its template line for line, comments and blank lines aside, except where the template
  has that line: only there may lines go, and only lines indented as steps (six spaces or more),
  so no setup step, job key (`permissions:`, `env:`), or job lands anywhere else; `evals.yml`
  triggers on exactly `push` (with `branches: [main]`) and `workflow_dispatch`; and
  `evals-guard.yml` triggers on exactly `pull_request`.
- **One eval per scenario.** **Checked:** each `docs/prd.md` scenario has its `scenario.md`, and
  each `judge: script` scenario has its `check.sh`, which parses (`bash -n`). The check never runs
  it. An eval that fails on the bare skeleton is expected: that failure is what pushes the work
  forward. These first evals never pass through the guard, so nothing has shown they fail: the
  handoff asks the human to confirm that the first `Evals` run on `main` is red, and an eval that
  passes there is a bug in that eval.

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
- Work in a `mktemp -d` directory, and leave `<repo-dir>` as you found it. **Enforced:** `run.sh`
  and the guard compare `<repo-dir>`'s HEAD and `git status --porcelain --ignored -uall` before
  and after each check; a change fails the eval, and `run.sh` stops there. Ignored files count, so
  set `PYTHONDONTWRITEBYTECODE=1` (as bench says), and build into your `mktemp -d` directory.
- Don't depend on the working directory, on `<repo-dir>` being a git repo, or on the environment:
  a check sees only `PATH` and `HOME`.
- Fail before the work is done. Bench's check must fail on its seed; an eval must fail on the
  default branch when it is added (the guard below checks it, but can't fully enforce it).

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
directory above `evals/`, which must be in a git work tree) and skips `judge: model` ones. Each
check runs as bench's validator runs checks: from a neutral `mktemp -d` directory, stdin from
`/dev/null`, in its own process group, killed with every process it started after
`EVALS_CHECK_TIMEOUT` seconds (default 120). It also runs under `env -i PATH=… HOME=…`, and its
process group is killed once it exits, so nothing it left running in that group can write while
a later check runs. A check passes only on exit 0; a timeout, exit 2, or a missing `check.sh` counts as failed,
and so does a symlink in `evals/`, which is never followed (it could count a check outside
`evals/`, or one twice).

A check that changes the repo (its HEAD, or its `git status` with ignored files) fails, and the run
stops there with `evals: aborted: <id> changed the repo it judges …`, no summary, and no metric:
the evals after it would judge a different repo, and one could pass for that reason alone. Under
GitHub Actions the run also stops before any check, the same way, when `evals/` differs from the
commit (`git status --ignored -- evals`, so an ignored file there counts): the setup before it
ran the product's code. Locally it doesn't, since a new eval is untracked while it is being
written.

It ends with:

```text
evals: <passed>/<total> passed (<skipped> skipped)
::notice title=evals-metric::passed=<passed> total=<total>
```

`<total>` counts the script evals. The notice is printed only under GitHub Actions
(`GITHUB_ACTIONS=true`). It exits 1 when any script eval fails, so the workflow run fails. Under
GitHub Actions a failed check's output is printed between `::stop-commands::<token>` and
`::<token>::`, with a random token, so a check (or product code it runs) can't print a
workflow command such as a forged `evals-metric` notice.

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
  permissions, in three jobs. Each checks out the full history and runs the **base branch's**
  `evals/guard.sh` from git's objects (`git show "$BASE_SHA:evals/guard.sh"`, run with `bash -c`,
  under `GIT_NO_REPLACE_OBJECTS=1`; a job with no such file at the base fails), so a PR can't
  change the guard that judges it. The base is the base branch's tip as the job's checkout fetched
  it (`origin/$GITHUB_BASE_REF`), not the event's `base.sha`, which a re-run replays:
  - **`evals-guard append-only`**: `--diff-only`. No setup step, so no PR code runs in it.
  - **`evals-guard must-fail`**: the stack's setup (which runs PR code: `npm install` runs the
    root `package.json`'s install scripts), then `--run-new`, which runs each new check and
    uploads its exit code, and the base it used, as an artifact.
  - **`evals-guard verdict`**: no setup; downloads the artifact and runs `--verdict`. When its
    own fetch of the base differs from the one must-fail used (the base moved between the jobs),
    it fails if the PR changes `evals/` or the root `.gitattributes` (from the merge base to the
    head, as the guard reads them), so both judged the same base; any other PR gives the guard
    nothing to judge on either base, so it passes rather than waiting for a re-run.

  The append-only and verdict jobs print the base they judged against as an
  `::notice title=evals-guard-base::<sha>` annotation, which `auto` reads.

## The guard

`bash evals/guard.sh [--diff-only] <base> <head>` looks at the PR's own changes: `git diff --raw
--no-renames` from the merge base of `<base>` and `<head>` to `<head>`, under `evals/` and to the
root `.gitattributes`. An eval the default branch gained after the PR branched is not one the PR
deletes.

**The append-only rule** (`--diff-only`, the `append-only` job). It reads git objects only and
runs nothing from the PR. It fails when:

- the PR modifies (its mode included), deletes, renames, or changes the type of any file under
  `evals/`, `run.sh` and `guard.sh` included (a rename shows as a delete);
- the PR adds a symlink or a submodule anywhere under `evals/`, a file directly under `evals/`
  (outside an eval directory), or a path holding a control character;
- the PR changes the root `.gitattributes`, or adds a `.gitattributes` under `evals/`: either
  changes how git checks the evals out (`export-subst`, `ident`, `eol`, …), so a check could read
  differently on the guard's tree than on `main`;
- the PR adds a file to an eval directory that already exists;
- a new eval's `scenario.md` is missing, or its front matter lacks `id: <id>` (kebab-case),
  `judge: script` or `judge: model`, or `requirement: R<n>`;
- a new `judge: script` eval has no `check.sh`, or one that doesn't parse.

**Must-fail-first** (`--run-new`, then `--verdict`). Bench's validator requires each check to fail
on its seed; the guard requires each new `judge: script` eval to fail on the default branch. Each
new check runs on its own fresh tree, built to look like `main` will after the merge, minus the
PR's product code: a `git clone --shared` checkout of the base (not `git archive`, so no
`export-*` attribute applies) with every new eval directory laid over it, committed on top of the
base so it has a `.git` and a clean status, and the workspace's ignored directories
(`node_modules/`, a virtualenv, …) linked in, so a check finds the dependencies setup installed.
It runs as `run.sh` runs it. The verdict fails a new script eval whose check passes (exit 0),
times out, or changes its tree, or that has no result. A new `judge: model` eval is
format-checked only.

The linked directories are the head's: if the stack's setup also builds the head (`dist/`), a
check that runs that build passes on the base tree, and the guard holds the PR. Keep builds out of
setup, or build inside the check's `mktemp -d` directory.

With no flag, the guard does all of it in one process, which is how to run it locally.

### What is enforced, and what isn't

- **Enforced: the append-only rule.** Its job runs no PR code, so the PR can't forge its verdict;
  `.github/workflows/` is in `approval_paths`, so the PR can't change the workflow without a human;
  and `auto` merges only when that job and the verdict job passed on the reviewed commit, against
  the base branch's current tip (`scripts/octo-evals-guard.sh`). It reads only this PR's newest
  run of `.github/workflows/evals-guard.yml` on that commit, never another workflow's or another
  PR's job of the same name. A `[skip ci]` head commit runs no workflow, so `auto` holds it as
  `evals guard did not pass`. No eval is modified, deleted, or renamed, and no symlink or
  top-level file is added, without a human.
- **Advisory: must-fail-first.** The `must-fail` job runs PR code before the checks (setup), and a
  hosted runner gives that code passwordless `sudo`. It can forge the uploaded exit codes, swap
  `git` or `bash` on the `PATH`, or plant replace refs, so a PR that sets out to can make the
  verdict pass. Within the job, the guard closes the obvious tells: it is parsed whole before any
  check runs (a check can't rewrite it mid-run), it ignores replace refs, and each check gets a
  fresh tree with `.git`, its own directory, and a clean environment.
- **Not closed mechanically.** A check can still tell the guard's tree from `main`: by timing,
  randomness, the git history (`HEAD`'s parent, the clone's `origin`), or its path. A check can
  also rewrite an untracked or ignored file in place (the linked dependency directories included),
  which `git status` doesn't see, or start a daemon that leaves its process group. **The reviewer
  still reads each new `check.sh`**: it must test the scenario, the same way on any tree.
- **Not closed mechanically: `evals.yml`'s setup.** On `main`, the stack's setup runs merged
  product code before `run.sh` (a `postinstall` in `package.json`, …). It could rewrite a check on
  disk, and the guard saw only a `package.json` change. Under Actions, `run.sh` stops before any
  check when `git status --ignored -- evals` isn't clean, ignored files included, but code that
  rewrites `run.sh` itself, or hides the change from git by other means (`skip-worktree`, a
  rewritten index, a `git` on the `PATH`), gets past that, so the reviewer reads a change to an
  install-time script as closely as a new check.
- **Stale guard.** `pull_request` runs don't re-run when `main` moves, so an eval judged against an
  older base may already pass on today's. When the PR changes anything under `evals/` or the root
  `.gitattributes` (the only paths the guard reads), `auto` holds a guard run against an older
  base as `evals guard stale`; re-run all the guard's jobs from the Actions tab, which fetches the
  current tip. A PR that changes neither has an empty diff for the guard on any base, so `auto`
  doesn't check its base, and PRs merged one after another don't each wait for a human. That
  relies on the guard reading nothing else: a later `guard.sh` that judges more paths needs the
  helper's list to grow with it.

A failing guard job makes the PR `UNSTABLE`, so `auto` holds it. Weakening an eval, or changing the
runner or the guard, then takes a human.

**Append-only additions merge automatically.** `approval_paths` holds the guard workflow, not
`evals/`: genesis's settings list `.github/workflows/`, which covers
`.github/workflows/evals-guard.yml` and `evals.yml`, so `auto` never merges a change to either
without a human. `evals/` stays out, so a PR that only adds must-fail evals merges like any other,
once `auto`'s evals-guard gate sees both guard checks pass.
The new repo's `VISION.md` says the same in its quality bar: the passing count never drops, and
evals only grow.
