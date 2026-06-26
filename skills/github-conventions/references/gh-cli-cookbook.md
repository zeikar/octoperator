# Octoperator gh CLI cookbook

Exact, copy-adaptable `gh` commands for every Octoperator operation. Prefer the helper scripts in
`${CLAUDE_PLUGIN_ROOT}/scripts/` for the GraphQL/Projects-v2 operations; the raw commands here exist
for transparency and for cases the scripts do not cover. Replace `OWNER/NAME` with the target repo
and `<owner>`/`<number>` with the project owner and number from settings.

Throughout, capture the URL `gh` prints and derive the number with `NUM=${URL##*/}`.

## Resolve repo and defaults

```bash
gh repo view --json nameWithOwner,defaultBranchRef --jq '{repo:.nameWithOwner, default:.defaultBranchRef.name}'
```

## Ensure labels exist (idempotent)

`--force` creates the label or updates it if present.

```bash
gh label create epic    --repo OWNER/NAME --color 6f42c1 --description "Large body of work" --force
gh label create feature --repo OWNER/NAME --color 0e8a16 --description "New capability" --force
gh label create bug     --repo OWNER/NAME --color d73a4a --description "Defect" --force
gh label create chore   --repo OWNER/NAME --color fbca04 --description "Maintenance" --force
gh label create docs    --repo OWNER/NAME --color 0075ca --description "Documentation" --force
for p in p0 p1 p2 p3; do gh label create "$p" --repo OWNER/NAME --color ededed --force; done
```

## Create an issue

```bash
URL=$(gh issue create --repo OWNER/NAME \
  --title "Add OAuth login" \
  --body "$(cat <<'EOF'
## Context
<why this matters>

## Acceptance criteria
- [ ] ...
EOF
)" \
  --label feature --label p2 \
  --milestone "v0.2" \
  --assignee @me)
NUM=${URL##*/}
echo "Created #$NUM → $URL"
```

Omit `--milestone`/`--assignee` when not configured. Child issues add `Part of #<epic>` as the first
body line.

## Epic + sub-issues

Create the epic issue with the `epic` label, then link each child:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-subissue.sh --repo OWNER/NAME --parent 10 --child 11 \
  || echo "- [ ] #11" >> epic-children.md   # fallback: append to the epic body checklist
```

Underlying GraphQL (what the script does):

```bash
PID=$(gh api graphql -f query='query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){issue(number:$num){id}}}' \
      -F o=OWNER -F n=NAME -F num=10 --jq '.data.repository.issue.id')
CID=$(gh api graphql -f query='query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){issue(number:$num){id}}}' \
      -F o=OWNER -F n=NAME -F num=11 --jq '.data.repository.issue.id')
gh api graphql -H "GraphQL-Features: sub_issues" \
  -f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){issue{number}}}' \
  -F p="$PID" -F c="$CID"
```

## Projects v2: add item and set status

Prefer the script (resolves field/option IDs by name):

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-project-status.sh \
  --owner <project-owner> --project <number> \
  --url https://github.com/OWNER/NAME/issues/11 --status "In Progress"
```

Underlying `gh project` commands:

```bash
PROJECT_ID=$(gh project view <number> --owner <owner> --format json --jq '.id')
# Status field id + option ids:
gh project field-list <number> --owner <owner> --format json \
  --jq '.fields[] | select(.name=="Status") | {id, options}'
# Add the issue/PR (skip if already an item — check item-list first):
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
# Gate signal: merge only when mergeStateStatus is CLEAN (OPEN + not draft + mergeable +
# required checks green + not blocked/behind). GitHub computes it async — re-query on UNKNOWN.
gh pr view <pr#> --repo OWNER/NAME \
  --json state,isDraft,mergeStateStatus,closingIssuesReferences

# When the gate passes (CLEAN) — regular merge commit (preserves full history) + delete branch:
gh pr merge <pr#> --repo OWNER/NAME --merge --delete-branch

# After merge: move the linked issue's board item to Done (board-optional).
bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-project-status.sh --owner <owner> --project <number> \
  --url <issue-url> --status "Done"
```

Merge ONLY when `state` is `OPEN`, `isDraft` is `false`, and `mergeStateStatus` is **`CLEAN`**. Any
other state — `DIRTY` (conflicts), `BLOCKED` (protection/required checks unmet), `BEHIND` (needs
update), `UNSTABLE` (a check failing/pending), `UNKNOWN` (still computing) — means do NOT merge; report
the reason. `gh pr checks <pr#>` is informational only (it conflates required and optional checks), not
the gate. `--merge` keeps every commit; do not substitute `--squash` or `--rebase`. The PR's
`Closes #N` auto-closes the issue.

## Sync queries (read-only)

```bash
gh issue list --repo OWNER/NAME --state open  --json number,title,labels,milestone,assignees
gh pr   list  --repo OWNER/NAME --state open  --json number,title,headRefName,isDraft,reviewDecision,mergeable
gh pr   list  --repo OWNER/NAME --state merged --limit 20 --json number,title,closingIssuesReferences,mergedAt
gh project item-list <number> --owner <owner> --format json
gh api repos/OWNER/NAME/milestones --jq '.[] | {title, open_issues, closed_issues, due_on}'
```

## Reconcile drift (sync-status auto-reconcile)

For each merged PR whose `closingIssuesReferences` issue is not yet `Done` on the board, move it:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/octo-project-status.sh --owner <owner> --project <number> \
  --url <issue-url> --status "Done"
```

Apply the same pattern for: open PR → ensure `In Review`; issue with a branch but no PR → ensure
`In Progress`. Always echo each change made.
