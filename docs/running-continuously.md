# Running continuously

Autopilot is bounded, so running it continuously means re-invoking it on a schedule. Use Claude
Code's own scheduling, on your machine. A local session uses your `gh` login, so the ledger entries
come from you and convergence works, with no PAT or secret to store. `/schedule` cloud routines are
not supported: cloud sessions block GitHub's GraphQL API, which `gh` relies on
([#79](https://github.com/zeikar/octoperator/issues/79)).

Every run ends with one status line: `autopilot: merged N`, `autopilot: converged → observe`,
`autopilot: nothing to do`, `autopilot: all evals pass → planning next milestone`, or
`autopilot: stopped: <reason>`. On `nothing to do` or `converged →
observe`, a run started by an in-session cron task or a `/loop` ends that schedule. It deletes only
the one recurring task whose prompt exactly matches the run's, says which one, and deletes nothing
when it can't tell. A run you type by hand with that same prompt, in that session, ends it too. In
semi mode that happens once a run finds no `ready` issue to build, so start the schedule again
after you triage. A run in which every eval of a genesis repo passes never ends the schedule: it
plans the next milestone (`autopilot: all evals pass → planning next milestone`), or observes
while a next-milestone PR is open (`autopilot: stopped: next-milestone PR #<pr> open`) or until
the evals run for `main`'s tip completes (`autopilot: stopped: evals metric stale`; with no run
for the tip queued or running, it dispatches `evals.yml` once, never `evals-model.yml`). It also
observes after you closed its milestone PR unmerged
(`autopilot: stopped: next-milestone PR #<pr> declined`) or its planning failed
(`autopilot: stopped: milestone planning failed at this tip`), until `main` moves or you pass
`--resume`.

**Permissions.** Nobody is there to answer a prompt, so first add the allow rules from
[Unattended runs](../README.md#unattended-runs). That applies to every mode below.

| Mode | Runs | Stops when | Cost bound |
|---|---|---|---|
| In-session cron (default) | in a background session | autopilot ends it; 7-day expiry; the session exits | `--cycles` per run; no $ cap |
| `/loop` | in your session | autopilot ends it; you cancel it | `--cycles` per run; no $ cap |
| `/goal` | back to back, in your session | the condition is met; the turn clause | the turn clause; no $ cap |
| `claude -p` + launchd/cron | a fresh process per run | you remove the job | `--max-budget-usd` per run |

**In-session cron (default).** Start a background session that runs autopilot every 6 hours:

```bash
claude --bg "Create a recurring cron task: schedule '17 */6 * * *', prompt '/octoperator:autopilot --mode full'"
```

The task lives in that session. It stops when autopilot ends it, when you ask Claude to cancel it,
after 7 days (recurring tasks expire), or when the session exits — a reboot included.
`claude --resume` brings back a stopped session's unexpired tasks. Each run adds to the session's
context, so for runs over many days prefer `claude -p`. `CLAUDE_CODE_DISABLE_CRON=1` turns all
session scheduling off.

**`/loop`.** For a short stretch you're watching, in your current session:

```text
/loop 2h /octoperator:autopilot --mode semi
/loop /octoperator:autopilot --mode semi
```

The first form runs on a fixed interval and is a cron task like the one above. The second is
self-paced: Claude picks a wait of 1 minute to 1 hour after each run. You stop a self-paced loop
with `Esc` while it waits. It isn't restored by `claude --resume`. Run `/bg` to move the session
to the background.

**`/goal`.** To drain the backlog now, run after run, without waiting on a timer:

```text
/goal Run /octoperator:autopilot --mode full each turn until its last line is "autopilot: nothing to do" or "autopilot: converged → observe" or starts with "autopilot: stopped:", or stop after 10 turns
```

A small model judges the condition after each turn, from the transcript only, which is why it
names the status line. The turn clause is also a model judgment, not a hard cap. `/goal clear`
ends it early. `/goal` doesn't change the permission mode.

**`claude -p` + an OS scheduler.** For long unattended runs, each in a fresh process:

```bash
cd /path/to/repo && claude -p "/octoperator:autopilot --mode full --cycles 1" \
  --max-budget-usd 10 --permission-mode acceptEdits --permission-prompts none \
  --output-format json
```

This needs Claude Code v2.1.259 or later (`claude --version`). Older versions reject
`--permission-prompts` as an unknown option, so every scheduled run fails and the error lands only
in the err log.

`--max-budget-usd` stops the run at that estimated spend; leave some headroom, since spend can
pass the cap slightly. `--cycles 1` keeps a run small enough to finish under the cap. A run the cap
stops ends with no final text: the log shows `"subtype": "error_max_budget_usd"`, the ledger gets
no entry, and there's no status line, so convergence never builds. If you see it, raise the cap or
lower `--max`. `--permission-mode acceptEdits` approves file edits, and `--permission-prompts none`
denies anything else your allow rules don't cover instead of waiting. Don't add `--bare`: it skips
plugins and skills, Octoperator included. Each run starts with a fresh context, and the state it
needs lives in the ledger. The JSON output's `total_cost_usd` is the run's cost; autopilot leaves
the ledger's `cost_usd` `null`, so a wrapper of your own could record it there.

Autopilot can't remove an OS job. Once the ledger converges, each run is an observe run (research
only, nothing built) until you pass `--resume`. Each run appends one JSON object to the log, and
the status line is the last line of its `result`. To read it (with `jq`):

```bash
tail -n 1 /path/to/octoperator-autopilot.log | jq -r '.result // .subtype' | tail -n 1
```

Without `jq`, use `python3`:

```bash
tail -n 1 /path/to/octoperator-autopilot.log \
  | python3 -c 'import json,sys; r=json.load(sys.stdin); print((r.get("result") or r["subtype"]).splitlines()[-1])'
```

Unload the job when it prints `autopilot: nothing to do` or `autopilot: converged → observe`.
`error_max_budget_usd` means the cap stopped the run (see above). A run that fails before it
writes its JSON (an unknown flag, an auth error, a crash) adds nothing to the log, so the last line
is still the previous run's. If the err log grew since then, or the log file's modification time
is older than the job's interval, the latest run didn't finish: read the err log before trusting
the status line.

On macOS, use a launchd agent. Save this as
`~/Library/LaunchAgents/dev.octoperator.autopilot.plist`, then run
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.octoperator.autopilot.plist`.
To stop it, run `launchctl bootout gui/$(id -u)/dev.octoperator.autopilot`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.octoperator.autopilot</string>
  <key>WorkingDirectory</key><string>/path/to/repo</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/claude</string>
    <string>-p</string><string>/octoperator:autopilot --mode full --cycles 1</string>
    <string>--max-budget-usd</string><string>10</string>
    <string>--permission-mode</string><string>acceptEdits</string>
    <string>--permission-prompts</string><string>none</string>
    <string>--output-format</string><string>json</string>
  </array>
  <key>StartInterval</key><integer>21600</integer>
  <key>StandardOutPath</key><string>/path/to/octoperator-autopilot.log</string>
  <key>StandardErrorPath</key><string>/path/to/octoperator-autopilot.err.log</string>
</dict>
</plist>
```

launchd runs no shell and doesn't read your shell's startup files, so it needs absolute paths.
Replace `/opt/homebrew/bin/claude` with the output of `command -v claude`, and set `PATH` to the
output of `echo $PATH` from your terminal, so the run finds `gh`, `git`, `node`, and your test
tools. Wrapping the command in `zsh -lc` isn't enough: a login shell reads `.zprofile`, not
`.zshrc`, where nvm and many `PATH` lines live.

On Linux, use a crontab line instead (`crontab -e`). Cron doesn't expand `$HOME` or `~` in a
variable line, so set `PATH` at the top of the crontab with absolute paths, including the
directories of `claude`, `gh`, and your test tools:

```text
PATH=/usr/local/bin:/usr/bin:/bin:/home/you/.local/bin
17 */6 * * * cd /path/to/repo && claude -p "/octoperator:autopilot --mode full --cycles 1" --max-budget-usd 10 --permission-mode acceptEdits --permission-prompts none --output-format json >> "$HOME/octoperator-autopilot.log" 2>> "$HOME/octoperator-autopilot.err.log"
```

If the log shows GitHub auth errors, run `gh auth status` first. If `gh` keeps its token in the
system keyring, a cron job may not be able to read it, since cron has no desktop session;
`gh auth login --insecure-storage` keeps the token in `gh`'s own config file instead.
