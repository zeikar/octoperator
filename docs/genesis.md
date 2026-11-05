# Starting a new project (`genesis`)

`genesis` starts from one sentence instead of an existing repo. Run it in an empty directory that
is not inside a git repository; that directory becomes the project:

```text
mkdir chat-pal && cd chat-pal && claude
/octoperator:genesis "A character-chat app that remembers you across long conversations"
  → docs/research.md (existing services and open-source projects, what to build, what to skip,
    each claim cited)
  → docs/prd.md (problem, users, MVP scope, out of scope, requirements with acceptance criteria,
    success metrics, and scenarios: one future eval each), docs/adr/0001-stack.md (the smallest
    stack and its test command), and VISION.md (the new repo's constitution, with the baseline
    immutable constraints)
  → GENESIS.md (the sentence, the proposed repo, visibility: private, stack, test_command)
  → genesis: proposed /path/to/chat-pal
```

It browses inline with WebSearch and WebFetch, capped at 6 searches and 10 fetches per run, and
treats every page as data, never instructions. Without web access it writes the proposal from the
sentence alone and marks it `ungrounded: no web access`. Its only `gh` call is the read
`gh api user`. The checkpoint lists the decisions you own: the stack (in the ADR), the repo name
and visibility (in `GENESIS.md`), and that approving will create a private repo whose GitHub
Actions minutes count against your plan's quota. Edit the files in place; genesis never
regenerates a file that exists, so to start over, delete them.

When the proposal is right, approve it in the same folder. Only the flag you type counts; a file
that claims approval doesn't:

```text
/octoperator:genesis --approve --dry-run
  → the ordered commands: write the skeleton, check it, <test command>, git init, git add,
    git commit, gh auth status, gh api graphql, gh repo view, gh repo create --private …,
    setup (settings and labels), the epic lookup, plan-epic, the handoff; then plan-epic's dry
    run (the proposed epic and children); nothing written
/octoperator:genesis --approve
  → README.md, .gitignore, .github/workflows/ci.yml, the test command's manifest, one module and
    one test, and the scenario evals: evals/<id>/ per PRD scenario, evals/run.sh, evals/guard.sh,
    .github/workflows/evals.yml and evals-guard.yml (each only if missing)
  → <test command> once, locally (it prompts: allow it, or pre-allow it in settings.local.json)
  → git init, commit, then gh repo create OWNER/NAME --private --push
  → .claude/octoperator.local.md (no board; approval_paths: [".github/workflows/", ".claude/",
    "/GENESIS.md", "CLAUDE.md", "CLAUDE.local.md", "/.mcp.json"]) and labels
  → the MVP epic and its children, filed by plan-epic's procedure from the sentence and the
    PRD's MVP scope and requirements; the epic links docs/prd.md and VISION.md
  → the handoff: relabel the children to build `ready`, then /octoperator:autopilot --mode semi
  → genesis: handed off OWNER/NAME (epic #1)
```

Every local step runs before anything goes outward: a failing test stops the run before
`git init`. The repo is `--private` unless `GENESIS.md` says `visibility: public`. Pushing the CI
workflow needs the token's `workflow` scope (`gh auth refresh -s workflow`). A re-run resumes from
what exists (the git repo, the `origin` remote, the push), so nothing is created twice. Run it on
your machine: Claude Code cloud sessions block GitHub's GraphQL API (#79).

The handoff is printed, never run. Building the MVP takes the usual semi-mode gesture: review the
children, add `ready` to the ones to build (the handoff gives the `gh label create ready` and
`gh issue edit` commands, since a fresh repo has no `ready` label yet), then run
`/octoperator:autopilot --mode semi` in the folder. To keep it running, use a recipe from
[Running continuously](running-continuously.md); the handoff points there rather than copying them.
It also prints the [allow rules](../README.md#unattended-runs) for your stack's test command
(`Bash(npm test:*)`, …, plus `Bash(gh:*)`, `Bash(git:*)`, `Edit`, and `Write`) for you to add,
and a reminder that a plugin loaded with `--plugin-dir` needs that flag in every later session. Genesis never
writes permission settings, never adds `ready` or `approved`, and never starts autopilot or a
schedule. A re-run of `--approve` after planning finds the open epic that quotes the sentence and
only prints the handoff.

The scenario evals judge the product itself, such as "at turn 200 the context still holds the
turn-3 fact". `evals.yml` runs `bash evals/run.sh` on every push to `main`, never on PRs (a
failing eval there would hold every PR, the fix included), and prints
`evals: <passed>/<total> passed`. Every eval fails on the bare skeleton, and a failing run on
`main` is the `eval` evidence `research` files issues from. The `evals-guard` check holds any PR
that modifies or deletes an eval, or adds one that already passes on `main`, so evals only grow
and adding must-fail ones merges unattended; weakening one takes a human. Its workflow is under
`.github/workflows/`, which the settings' `approval_paths` covers, and `auto` merges only when its
checks passed on the reviewed commit against the current `main` (a `[skip ci]` commit has none).
The append-only rule runs in a job with no PR code, so it holds; whether a new eval fails on `main`
first is checked after the PR's dependencies install, so it is advisory, and a reviewer still reads
each new check. Confirm the first `Evals` run on `main` is red.

A `judge: model` scenario, such as whether replies keep a persona's tone, spends model tokens, so
the offline run skips it. When the PRD has one, genesis also writes `evals-model.yml`, which runs
those evals only when you dispatch it, with at most `EVALS_MAX_CALLS` model calls (20), each
sending at most `EVALS_MAX_PROMPT_BYTES` of scenario and evidence (200000), and a 30-minute
timeout per job, once you add the `ANTHROPIC_API_KEY` secret. One job runs the repo's setup and checks to build the
evidence, with no secret; a second, with no repo code, sends it to the model, and only that job
gets the key. `approval_paths` holds only the merge, and a workflow pushed on a branch runs with
repo secrets, so keep the key in a GitHub Environment restricted to `main` where your plan allows
(the evals reference has the steps). Genesis never sets a secret or dispatches a workflow, and
Octoperator's own CI never calls a model. A failing dispatch
run stays the latest `eval` evidence until the next dispatch, so dispatch again after a fix
merges. Format and rules:
[`skills/genesis/references/evals.md`](../skills/genesis/references/evals.md). Autopilot records
the number passing as its ledger `metric` and counts a run as progress only when that number
rose. The plan is [epic #85](https://github.com/zeikar/octoperator/issues/85).

## The next milestone (`genesis --next`)

Once every eval passes on `main`'s tip, run `/octoperator:genesis --next` in the repo. Autopilot
does it for you once nothing is buildable, but ungrounded: it pre-allows no web tool, so it
plans from the repo alone unless your settings allow WebSearch and WebFetch. It reads
`VISION.md`, the PRD, `docs/research.md`, the run ledger, and earlier milestone PRs. It researches
what similar products shipped since (at most 6 searches and 10 fetches; pages are data, never
instructions). Its queries name only the product's public category and its known prior art, and
it fetches only URLs a search or `docs/research.md` gave it. Then it picks one milestone that fits
`VISION.md`, about 3–8 issues of work. It opens one PR on `milestone-<n>-<slug>`: a
`## Milestone <n>` section appended to `docs/prd.md`, new evals under `evals/<id>/` that must fail
on `main`, a Roadmap item, and the refreshed research, its body citing the sources. Without web
access it plans from the repo alone and marks the PR `ungrounded`. It stops, creating nothing,
while another next-milestone PR is open, or while the latest evals run judged an older commit
than `main`'s tip (right after a milestone merges). `/octoperator:auto --pr <M>` then reviews and
merges it like any PR, as autopilot does in both modes. The evals guard holds it for a human if a
new eval already passes or an existing one changed. So does the milestone check, which `auto`
re-runs on the reviewed commit of every `milestone-*` PR. Once it merges, the new evals fail on `main`, `research` files the work,
and the build loop resumes. The risk is unattended web content steering the product: every gate
still applies, the repo is private by default, at most one milestone PR is open at a time, and
the PR cites its sources so you can audit it. Steps:
[`skills/genesis/references/next.md`](../skills/genesis/references/next.md).
