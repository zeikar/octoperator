---
id: csvcut-docs
kind: docs
difficulty: medium
---
# docs: say which kinds of CSV input csvcut supports

Users keep asking whether `csvcut.py` can handle their files: exports with quoted fields, files
saved on Windows, columns picked by number. The README doesn't say, so they find out by trying.

Add a `## Supported input` section to `README.md` with a Markdown table whose columns are
`Feature | Supported` (a third `Notes` column is fine). The table has exactly these six rows, in
any order:

- Select columns by header name
- Select columns by position (`-f 2`)
- A delimiter other than a comma (`-d`)
- Quoted fields that contain the delimiter
- Quoted fields that contain a line break
- Windows (CRLF) line endings

Each `Supported` cell is `yes` or `no`, and says what `csvcut.py` does today. This issue is
documentation only: don't change how `csvcut.py` behaves. Support for anything marked `no` can be
proposed in a separate issue.

## Acceptance criteria

- `README.md` has a `## Supported input` section with a `Feature | Supported` table of exactly
  the six rows above
- Every `Supported` cell is `yes` or `no` and matches what the current code does
- `csvcut.py`'s behavior is unchanged and `make test` passes
