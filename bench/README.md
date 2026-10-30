# Benchmark tasks

Fixture tasks with known-good outcomes, used to measure whether `/octoperator:auto` produces
correct results (epic #66). Each task is a GitHub issue to file against a small seed repo, plus a
hidden check that decides, without any model, whether the merged result is correct.

Everything here is offline: nothing calls `claude`, `gh`, or the network. Running the tasks
through `auto` is the job of a separate, opt-in harness.

## Layout

Each task lives in `bench/tasks/<id>/`:

| Path             | What it is                                                      |
|------------------|-----------------------------------------------------------------|
| `task.md`        | Metadata, then the title and body of the issue to file          |
| `seed/`          | The starting contents of the repo the agent works on            |
| `check.sh`       | The hidden oracle. Never copied into the agent's repo           |
| `solution.patch` | A known-good reference fix, applied to `seed/` with `git apply` |

`<id>` is lowercase kebab-case and must equal the `id` in `task.md`.

## `task.md`

YAML-style front matter, then the issue: a `# <title>` line followed by the body.

```markdown
---
id: vsort-numeric
kind: bug
difficulty: easy
---
# fix: vsort puts 1.10.0 before 1.9.0

`vsort.py` compares version parts as text, ...

## Acceptance criteria

- ...
```

- **Front matter.** Line 1 is `---`, and the block ends at the next `---` line. In between, one
  `key: value` per line, with lowercase keys. Required keys:
  - `id`: the task directory's name
  - `kind`: the issue's type label, one of `feature`, `bug`, `chore`, or `docs`
  - `difficulty`: `easy`, `medium`, or `hard`

  Other keys are allowed and ignored by the validator.
- **Title.** The first non-blank line after the front matter is `# <title>`. The title is
  everything after `# `.
- **Body.** Everything after the title line, with leading and trailing blank lines trimmed, is the
  issue body. It must not be empty. Write it like a real issue: the problem, then acceptance
  criteria. Never mention the check.

## `seed/`

A small, self-contained repo of a few files that does not depend on Octoperator:

- Its tests run with `make test`, which is how `implement` finds the test command.
- Use only bash, POSIX tools, and the Python 3 standard library.
- `make test` passes on the seed. The issue's work is what is missing, not a broken build.

## `check.sh`

`bash check.sh <repo-dir>` checks a checked-out repo, such as the merged default branch, and exits
0 only when the issue's outcome is correct (1 on fail, 2 on bad arguments). It prints one `FAIL:`
line per problem.

- Check **behavior, not implementation**, so any reasonable correct fix passes. Run the code on
  hidden inputs instead of matching source text. For docs tasks, check that the required facts
  appear in the right file, without depending on exact wording.
- Run the repo's own tests too (`make test`), so a fix that breaks them fails.
- Use only bash, POSIX tools, and the Python 3 standard library. Work in a `mktemp -d` directory,
  and don't leave files in `<repo-dir>`. For example, set `PYTHONDONTWRITEBYTECODE=1`.
- Don't depend on the working directory or on `<repo-dir>` being a git repo.
- Fail on `seed/`, and pass once `solution.patch` is applied.

## `solution.patch`

A `git diff` from `seed/` to a correct result, with `a/` and `b/` path prefixes relative to the
seed root. It includes the tests a good PR would add. One way to make it:

```bash
cp -R bench/tasks/<id>/seed/. /tmp/sol && cd /tmp/sol && git init -q && git add -A \
  && git -c user.name=bench -c user.email=bench@example.invalid commit -qm seed
# ... make the fix ...
git diff > /path/to/bench/tasks/<id>/solution.patch
```

## Validating

```bash
bash bench/validate.sh                 # every task
bash bench/validate.sh vsort-numeric   # just one
bash bench/test/selftest.sh            # proves validate.sh catches broken tasks
```

`validate.sh` checks each task's layout and `task.md` format. Then, on throwaway copies of `seed/`
in a `mktemp -d` directory, it checks that the seed's `make test` passes, that `check.sh`
**fails** on the seed, that `solution.patch` applies, and that both `make test` and `check.sh`
**pass** with it. It reports every task and exits non-zero if any task is broken. Each
`make test` and `check.sh` run is killed, along with every process it started, after
`BENCH_CHECK_TIMEOUT` seconds (default 120).
CI runs both scripts on ubuntu and macOS.

## Tasks

| ID              | Kind    | Difficulty | Seed and work                                      |
|-----------------|---------|------------|----------------------------------------------------|
| `wordfreq-top`  | feature | easy       | Python word counter: add a `--top N` option        |
| `vsort-numeric` | bug     | easy       | Python version sorter compares parts as text       |
| `retry-docs`    | docs    | easy       | Bash retry wrapper: document env vars, exit status |
