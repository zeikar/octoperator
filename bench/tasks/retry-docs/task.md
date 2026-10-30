---
id: retry-docs
kind: docs
difficulty: easy
---
# docs: document retry.sh's settings and exit status in the README

The README shows how to call `retry.sh` but not how to tune it or what it exits with, so users
have to read the script to find out.

Add two sections to `README.md`:

- `## Configuration`, with a Markdown table whose columns are `Variable | Default | Description`
  and which has one row per environment variable:
  - `RETRY_ATTEMPTS`: the maximum number of attempts, default `5`
  - `RETRY_DELAY`: the seconds to wait between attempts, default `2`
- `## Exit status`, with a Markdown table whose columns are `Case | Exit status` and which has
  one row per case:
  - an attempt succeeds: `0`
  - every attempt fails: the exit status of the last attempt
  - called without a command: `2`

## Acceptance criteria

- `README.md` has a `## Configuration` section whose `Variable | Default | Description` table
  gives both environment variables with their defaults
- `README.md` has a `## Exit status` section whose `Case | Exit status` table gives the status
  for success, for every attempt failing (the last attempt's status), and for a call without a
  command
- `retry.sh`'s behavior is unchanged and `make test` passes
