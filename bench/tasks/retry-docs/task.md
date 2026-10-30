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
- `## Exit status`, saying in your own words that `retry.sh` exits with the exit status of the
  last attempt (0 as soon as an attempt succeeds)

## Acceptance criteria

- `README.md` has a `## Configuration` section whose `Variable | Default | Description` table
  gives both environment variables with their defaults
- `README.md` has a `## Exit status` section stating that `retry.sh` exits with the status of
  the last attempt
- `retry.sh`'s behavior is unchanged and `make test` passes
