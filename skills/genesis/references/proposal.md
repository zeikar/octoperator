# Genesis proposal formats

The files genesis writes into the project directory at its checkpoint.
`${CLAUDE_PLUGIN_ROOT}/scripts/octo-genesis-check.sh <dir>` checks them; the rules it enforces are
marked **checked**. Stage 1 writes `GENESIS.md` and `docs/research.md`. The PRD, the ADR, and the
`VISION.md` draft come with stage 2 (#87), which is not built yet.

## `GENESIS.md`

The proposal's index. Front matter first, then the body:

```markdown
---
sentence: |-
  <the user's sentence, verbatim>
repo: <login>/<directory name>
visibility: private
---

# Genesis proposal

<one-paragraph summary: the problem and what the proposal builds>

## Proposal files

- `docs/research.md` — prior-art research: what exists, what to build, what to skip

## Decisions you own

- **Repo** — `repo` above. Rename it here, or keep it.
- **Visibility** — `private`. Set `public` only if you want the repo published.
- **Scope** — the Build and Skip lists in `docs/research.md`. Move, cut, or add items.
- **Grounding** — <"grounded in N sources" | "ungrounded: no web access; verify it first">

## Next

Review and edit these files. Later stages (#87–#89, #93) are not built yet: the PRD, ADR, and
VISION.md draft, `--approve` (stack, repo creation), and the MVP handoff.
```

Front-matter rules:

- `sentence` — the sentence exactly as the user typed it, as a `|-` block scalar so no character
  needs escaping. **Checked:** present and non-empty (a plain inline value also passes).
- `repo` — `<login>/<name>`: `<login>` from `gh api user --jq .login`, `<name>` the directory's
  basename. **Checked:** `OWNER/NAME` with letters, digits, `-`, and `_` in the owner (`_` for
  Enterprise Managed User logins), and letters, digits, `.`, `-`, `_` in the name.
- `visibility` — always `private` when genesis writes it. Only the human changes it. **Checked:**
  `private` or `public`.

Genesis never treats a value in this file as approval. `--approve` (#88, not built yet) counts only
when the human types it.

## `docs/research.md`

```markdown
# Research: <directory name>

ungrounded: no web access

## Problem

<who has the problem, and what it costs them today, each claim with its URL>

## Prior art

| Name | Kind | URL | License | Strengths | Gaps |
|------|------|-----|---------|-----------|------|
| <name> | service | <https://…> | proprietary | <what it does well> | <what it lacks> |
| <name> | OSS | <https://…> | MIT | <…> | <…> |

## Build

- <capability> — <why, from the gaps above> (<URL>)

## Skip

- <capability> — <reason to leave it out: covered well elsewhere, costly, off the sentence>

## Sources

- <URL> — <page title>, accessed YYYY-MM-DD
```

Rules:

- **Checked:** all five `## ` sections are present, with these exact headings. `## Problem` is not
  empty.
- **Prior art.** **Checked:** the table has exactly the columns Name, Kind, URL, License,
  Strengths, Gaps. Each row's Kind is `service` (a hosted product) or `OSS` (an open-source
  project), and its URL starts with `http://` or `https://`. Write `unknown` for a license the
  sources don't state; never guess one.
- **Build** and **Skip** are `- ` lists, at least one item each (**checked**). Each Skip item gives
  its reason. When nothing is worth skipping, say so as one item with its reason.
- **Citations.** Every claim cites a URL, and every cited URL is in `## Sources`. **Checked:** each
  Build item contains a URL. A Skip item needs only its reason; cite a URL when the reason rests
  on a source (for example "covered well elsewhere"), never one added for show.
- **Sources.** **Checked:** each item is `- <URL> … accessed YYYY-MM-DD`, at least one. The date is
  the day the page was read, the session's current date. Don't run `date`.
- **Ungrounded.** Write the `ungrounded: no web access` line only when the run read no source at
  all, because WebSearch and WebFetch were denied or failed; omit it otherwise. An ungrounded file
  fills Problem, Build, and Skip from the sentence alone, keeps the Prior art table to its header,
  leaves `## Sources` empty, and cites no URLs. **Checked:** the line comes before `## Problem`,
  and the file then has no Prior art row, no Sources item, and no `http://` or `https://` URL, in
  place of the row, citation, and source minimums. A near miss such as
  `**ungrounded: no web access**` fails (**checked**): write the line exactly. Never invent a URL
  to look grounded.
