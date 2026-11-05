# Octoperator gh CLI cookbook

Exact, copy-adaptable `gh` commands for every Octoperator operation. Prefer the helper scripts in
`${CLAUDE_PLUGIN_ROOT}/scripts/` where one exists; the raw commands here exist for transparency and
for cases the scripts do not cover. Replace `OWNER/NAME` with the target repo and
`<owner>`/`<number>` with the project owner and number from settings. Where porcelain prints a URL
(`gh pr create`), derive the number with `NUM=${URL##*/}`; a REST call prints what its `--jq` asks
for.

## REST, not GraphQL

A Claude Code cloud session's proxy refuses GraphQL, with `GitHub GraphQL is not available from
Claude Code sessions; use the REST API (gh api repos/{owner}/{repo}/...)`. Most `gh` porcelain
uses GraphQL under the hood, including every issue and label command, so issues, labels, and
sub-issues go through `gh api repos/OWNER/NAME/...` (REST), never the porcelain. REST works
locally too, so one path serves both. The pull request, merge, and Projects v2 recipes further
down still use porcelain for now (Projects v2 has no REST API at all).

The rules every REST step follows:

- **One call does it → write it directly.** Each step stays one plain `gh api` call (the command
  rule in `skills/implement/SKILL.md`). A step that needs logic (a loop, a search, a dedupe, a
  whole-list sort or count) gets a small `scripts/octo-*.sh` helper instead, REST only, tested
  in `scripts/test/rest.sh` against a stub `gh` that refuses GraphQL and porcelain as the proxy
  does.
- **`-f` for text, `-F` only for numbers.** `-f k=v` sends a raw string. `-F` converts: `@x` reads
  the file `x`, and `123`, `true`, or `null` stop being strings. So titles, bodies, label names,
  and states always take `-f`; `-F` is for the numeric `milestone` and `sub_issue_id` only. Any
  `-f`/`-F` makes the call a `POST`; pass `-X PATCH` (or `PUT`, `DELETE`) for other writes.
- **Arrays** repeat the key with `[]`: `-f 'labels[]=feature' -f 'labels[]=p2'`.
- **Bodies with newlines** are one single-quoted argument, `-f body='…'`, line breaks and all.
  Nothing expands inside single quotes, so backticks, `$`, `\`, and `"` stay literal; write each
  `'` in the text as `'\''`. That keeps any text safe in one plain call, with no `$(cat …)`,
  heredoc, or temp file.
- **Issue lists hold pull requests too.** `GET .../issues` returns PRs as well; drop them with
  `select(.pull_request == null)`. A single read (`GET .../issues/N`) also answers for a PR.
- **Paginate, one line per item.** Lists take `per_page=100` and `--paginate`. `--jq` runs once
  per page, so a filter emits one line per item; anything that needs the whole list at once
  (sort, count, last N) is a query parameter (`sort=created&direction=asc`) or a helper.
  `--slurp` does not combine with `--jq`.
- **No search.** `gh api` has no `--search`, and REST issue search (`/search/issues`) is not
  known to pass the cloud proxy, so filter a list with `--jq` (labels and state are query
  parameters), or use `octo-issue-find.sh` to find a text.
- **REST spells values its own way:** `state` is `open`/`closed`, `state_reason` is
  `completed`/`not_planned`, the web link is `html_url`, a comment's author role is
  `author_association`, and the milestone is its **number**, not its title.
- **Errors.** On an HTTP error `gh api` exits 1, prints the response body on stdout, and prints
  `gh: <message> (HTTP <code>)` on stderr.
- **Labels** come from `octo-labels.sh` (below), or its raw `POST` where a skill may run only
  `gh`, never the porcelain `gh label create --force`. Both create a missing label and leave an
  existing one as it is.

## Resolve repo and defaults

```bash
gh repo view --json nameWithOwner,defaultBranchRef --jq '{repo:.nameWithOwner, default:.defaultBranchRef.name}'
```

## Ensure labels exist (idempotent)

`octo-labels.sh` creates each missing label with the colour and description in
`conventions.md`, and leaves an existing one alone. It prints `created <label>`, `exists <label>`,
or `failed <label>: <error>`, and exits 1 if any create failed:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-labels.sh --repo OWNER/NAME epic feature bug chore docs p0 p1 p2 p3
```

Under it, one `POST` per label; `422` with `already_exists` means the label is there:

```bash
gh api repos/OWNER/NAME/labels -f name=epic -f color=6f42c1 -f description='Large body of work'
```

To check whether a label exists without creating it, list the names:

```bash
gh api "repos/OWNER/NAME/labels?per_page=100" --paginate --jq '.[].name'
```

## Resolve a milestone's number

The REST API takes a milestone's number. Resolve the configured title once; no line means no such
open milestone:

```bash
gh api "repos/OWNER/NAME/milestones?state=open&per_page=100" --paginate \
  --jq '.[] | select(.title == "v0.2") | .number'
```

## Create an issue

```bash
gh api repos/OWNER/NAME/issues \
  -f title='Add OAuth login' \
  -f body='## Context
<why this matters>

## Acceptance criteria
- [ ] ...' \
  -f 'labels[]=feature' -f 'labels[]=p2' \
  -F milestone=3 \
  --jq '"\(.number) \(.html_url)"'
```

It prints `<number> <url>`. Omit `-F milestone` when none is configured. To assign someone, add
`-f 'assignees[]=<login>'` (REST has no `@me`; `gh api user --jq .login` reads yours). Child
issues add `Part of #<epic>` as the first body line.

## Read, list, and change issues

```bash
# One issue (a PR number answers too):
gh api repos/OWNER/NAME/issues/42 \
  --jq '{number, title, body, state, state_reason, url: .html_url, labels: [.labels[].name]}'
# Its comments, oldest first:
gh api "repos/OWNER/NAME/issues/42/comments?per_page=100" --paginate \
  --jq '.[] | "--- \(.user.login) (\(.author_association)) \(.created_at) \(.html_url)\n\(.body)"'
# Open issues, one line each (labels and state filter server-side: &labels=ready,p1):
gh api "repos/OWNER/NAME/issues?state=open&per_page=100" --paginate \
  --jq '.[] | select(.pull_request == null) | "\(.number)\t\(.title)\t\([.labels[].name] | join(","))"'
# Open issues whose title or body contains a text (no regex, no search syntax):
bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-issue-find.sh --repo OWNER/NAME --text 'parses empty input'
# Comment, add labels, replace the body, close:
gh api repos/OWNER/NAME/issues/42/comments -f body='<comment>'
gh api repos/OWNER/NAME/issues/42/labels -f 'labels[]=ready'
gh api -X PATCH repos/OWNER/NAME/issues/42 -f body='<the whole new body>'
gh api -X PATCH repos/OWNER/NAME/issues/42 -f state=closed -f state_reason=not_planned
```

## Epic + sub-issues

Create the epic issue with the `epic` label, then link each child:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-subissue.sh --repo OWNER/NAME --parent 10 --child 11
```

If it exits non-zero, fall back to the epic body's `## Children` checklist: read the body, then
write it back whole with `- [ ] #11` appended to that section:

```bash
gh api repos/OWNER/NAME/issues/10 --jq .body
gh api -X PATCH repos/OWNER/NAME/issues/10 -f body='<the body, with - [ ] #11 added under ## Children>'
```

Underlying REST (what the script does): the child's numeric `id` (not its number), then the link,
with `-F` so the id goes as a number:

```bash
gh api repos/OWNER/NAME/issues/11 --jq .id
gh api repos/OWNER/NAME/issues/10/sub_issues -F sub_issue_id=<id>
```

## Projects v2: add item and set status

Prefer the script (resolves field/option IDs by name). `--status` takes the board's option name —
map the logical status through the `statuses` setting first (see conventions → Projects v2 status
flow); the literal names in these recipes are the defaults:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-project-status.sh \
  --owner <project-owner> --project <number> \
  --url https://github.com/OWNER/NAME/issues/11 --status "In Progress"
```

Underlying `gh project` commands:

```bash
PROJECT_ID=$(gh project view <number> --owner <owner> --format json --jq '.id')
# Status field id + option ids:
gh project field-list <number> --owner <owner> --limit 100 --format json \
  --jq '.fields[] | select(.name=="Status") | {id, options}'
# Add the issue/PR (idempotent: an item already on the board returns its existing id):
ITEM_ID=$(gh project item-add <number> --owner <owner> --url <content-url> --format json --jq '.id')
# Set the Status single-select option:
gh project item-edit --id "$ITEM_ID" --project-id "$PROJECT_ID" \
  --field-id "<status-field-id>" --single-select-option-id "<option-id>"
```

## Create a branch from the default branch

Local (developer is working in the repo — preferred):

```bash
DEFAULT=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
git fetch origin "$DEFAULT"
git switch -c 42-add-oauth-login "origin/$DEFAULT"
```

Remote-only (no local checkout):

```bash
SHA=$(gh api repos/OWNER/NAME/git/ref/heads/$DEFAULT --jq '.object.sha')
gh api repos/OWNER/NAME/git/refs -f ref=refs/heads/42-add-oauth-login -f sha="$SHA"
```

## Open a pull request

```bash
git push -u origin 42-add-oauth-login
URL=$(gh pr create --repo OWNER/NAME --base "$DEFAULT" --head 42-add-oauth-login \
  --title "feat: add OAuth login" \
  --body "$(printf 'Closes #42\n\n## Summary\n- ...\n')" \
  --reviewer alice --reviewer bob)
NUM=${URL##*/}
```

Add `--draft` when the branch has no commits beyond base. Then add the PR to the board:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-project-status.sh --owner <owner> --project <number> --url "$URL" --status "In Review"
```

## Post a review

```bash
gh pr review <pr#> --repo OWNER/NAME --comment        --body "<review markdown>"
gh pr review <pr#> --repo OWNER/NAME --approve         --body "LGTM"
gh pr review <pr#> --repo OWNER/NAME --request-changes --body "<blocking findings>"
```

GitHub forbids approving your own PR. For a self-authored PR, use `--comment` and state the verdict in
the body. Detect authorship:

```bash
ME=$(gh api user --jq '.login')
AUTHOR=$(gh pr view <pr#> --repo OWNER/NAME --json author --jq '.author.login')
```

Inline line comments (advanced) require the REST review API with a `comments[]` array
(`gh api repos/OWNER/NAME/pulls/<pr#>/reviews ...`). Default to a single summary review whose body
uses `path:line` references — reliable and sufficient.

## Merge a pull request (regular merge — preserve history)

Check the merge gate, then merge with a **regular merge commit** (never `--squash`/`--rebase`):

```bash
# First wait (bounded) for running checks to settle — pending checks read as UNSTABLE/BLOCKED.
# Exit code is informational only; the gate below decides.
gh pr checks <pr#> --repo OWNER/NAME --watch --fail-fast --interval 30

# Gate: the latest review's intended verdict is not request_changes, headRefOid is the commit that
# review covered, and mergeStateStatus is CLEAN (OPEN + not draft + mergeable + required checks
# green + not blocked/behind). GitHub computes it async — re-query on UNKNOWN.
gh pr view <pr#> --repo OWNER/NAME \
  --json headRefOid,state,isDraft,mergeStateStatus,closingIssuesReferences

# When the gate passes — regular merge commit (preserves full history) + delete branch, pinned to the
# reviewed commit so a later push cannot merge unreviewed:
gh pr merge <pr#> --repo OWNER/NAME --merge --delete-branch --match-head-commit <reviewed-sha>
# On a non-zero exit, re-read the state: the merge may have landed and only the branch delete
# failed. MERGED → success (report the error as cleanup); anything else → the merge failed.
gh pr view <pr#> --repo OWNER/NAME --json state --jq '.state'

# After merge: move the linked issue's board item to Done (board-optional).
bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-project-status.sh --owner <owner> --project <number> \
  --url <issue-url> --status "Done"
```

Merge ONLY when the latest review's intended verdict is not `request_changes` and covered the current
`headRefOid`, `state` is `OPEN`, `isDraft` is `false`, and `mergeStateStatus` is **`CLEAN`**. Any
other state — `DIRTY` (conflicts), `BLOCKED` (protection/required checks unmet), `BEHIND` (needs
update), `UNSTABLE` (a check failing/pending), `UNKNOWN` (still computing) — means do NOT merge; report
the reason. `gh pr checks <pr#>` is informational only (it conflates required and optional checks), not
the gate — `--watch` uses it only to wait, so give that call a bounded timeout and, if checks are still
pending when it expires, let the gate hold the PR. When `approval_paths` is set, `auto` first
holds any PR whose changed files match it, and it holds any PR that changes `VISION.md` outside
its Roadmap body (see `skills/auto/SKILL.md`, step 5). `--merge` keeps
every commit; do not substitute `--squash` or `--rebase`. The PR's `Closes #N` auto-closes the
issue; `auto` then runs `scripts/octo-after-merge.sh`, which closes it when GitHub didn't and
closes the epic once its last child is closed.

## Sync queries (read-only)

```bash
gh api "repos/OWNER/NAME/issues?state=open&per_page=100" --paginate --jq '.[] | select(.pull_request == null)
  | {number, title, labels: [.labels[].name], milestone: .milestone.title, assignees: [.assignees[].login]}'
gh pr   list  --repo OWNER/NAME --state open  --json number,title,headRefName,isDraft,reviewDecision,mergeable
gh pr   list  --repo OWNER/NAME --state merged --limit 20 --json number,title,closingIssuesReferences,mergedAt
gh project item-list <number> --owner <owner> --format json
gh api repos/OWNER/NAME/milestones --jq '.[] | {title, open_issues, closed_issues, due_on}'
```

## Reconcile drift (sync auto-reconcile)

For each merged PR whose `closingIssuesReferences` issue is not yet `Done` on the board, move it:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-project-status.sh --owner <owner> --project <number> \
  --url <issue-url> --status "Done"
```

Apply the same pattern for: open PR → ensure `In Review`; issue with a branch but no PR → ensure
`In Progress`. Always echo each change made.
