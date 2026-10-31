#!/usr/bin/env bash
# check.sh — hidden oracle for bench task envparse-extract.
#
# Usage:
#   check.sh REPO_DIR
#
# Passes when REPO_DIR has an envparse.py whose parse(text) returns what the seed's parse_env
# returns on a set of hidden .env texts (edge cases included); when envcheck.py and envdump.py
# still print the same output and exit with the same status on hidden files; when both tools
# really use envparse.parse (run with envparse.parse replaced by a stub, each tool reports the
# stub's settings, which no copy of the parser could produce); and when `make test` passes.
# Exits 0 on pass, 1 on fail, 2 on bad arguments.
set -uo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  "") echo "Usage: check.sh REPO_DIR" >&2; exit 2 ;;
esac
repo="$1"
for f in envcheck.py envdump.py; do
  [ -f "$repo/$f" ] || { echo "FAIL: $repo/$f not found"; exit 1; }
done

tmp="$(mktemp -d)" && [ -n "$tmp" ] || { echo "check: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
export PYTHONDONTWRITEBYTECODE=1

failed=0
fail() { failed=1; echo "FAIL: $1"; }

# One FAIL line per problem. (Not inside $(…): bash 3.2 misparses a here-doc with quotes inside
# a command substitution.)
python3 - "$repo" "$tmp" >"$tmp/result" <<'PY' || fail "check crashed"
import json
import os
import subprocess
import sys

repo, tmp = sys.argv[1], sys.argv[2]


def reference(text):
    """The seed's parse_env, verbatim."""
    env = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key, value = key.strip(), value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        env[key] = value
    return env


TEXTS = [
    "", "A=1\nB=2", "  A = 1  \n", "export   A=1", "exportA=1", "export A", 'A="x"', "A='x'",
    "A=\"x'", 'A="', "A=''", 'A="""', "URL=postgres://u:p@h/db?x=1", "A=b # c", "# A=1",
    "   # A=1\nB=2", "=value", "A=1\r\nB=2\r\n", "A=1\nA=2", "noequals\nA=1", "A= spaced value ",
    'A=" padded "', "NAME=Zoë", "A==b", "A=1\n\n\nB=\n", "  export B='q' \n",
]

# 1. envparse.parse matches the seed's parser.
if not os.path.isfile(os.path.join(repo, "envparse.py")):
    print("FAIL: envparse.py not found")
else:
    probe = (
        "import json, sys\n"
        "sys.path.insert(0, sys.argv[1])\n"
        "import envparse\n"
        "texts = json.load(sys.stdin)\n"
        "print(json.dumps([envparse.parse(t) for t in texts]))\n"
    )
    run = subprocess.run([sys.executable, "-c", probe, repo], input=json.dumps(TEXTS),
                         capture_output=True, text=True, cwd=tmp)
    if run.returncode != 0:
        print(f"FAIL: envparse.parse crashed: {run.stderr.strip().splitlines()[-1:]}")
    else:
        for text, got in zip(TEXTS, json.loads(run.stdout)):
            if got != reference(text):
                print(f"FAIL: envparse.parse({text!r}) gave {got!r}, wanted {reference(text)!r}")


# 2. The tools behave as before.
def tool(*args):
    run = subprocess.run([sys.executable, *args], capture_output=True, text=True, cwd=repo)
    return run.returncode, run.stdout


SAMPLE = ("# app settings\nexport DB_URL='postgres://db/app?ssl=1'\nNAME = \"My App\"\n"
          "EMPTY=\nPORT=8080\nPORT=9090\njunk line\n")
path = os.path.join(tmp, "app.env")
with open(path, "w", encoding="utf-8") as fh:
    fh.write(SAMPLE)
env = reference(SAMPLE)
cases = [
    (("envdump.py", path), (0, "".join(f"{k}={env[k]}\n" for k in sorted(env)))),
    (("envdump.py", path, "--json"), (0, json.dumps(env, sort_keys=True) + "\n")),
    (("envdump.py", "--json", path), (0, json.dumps(env, sort_keys=True) + "\n")),
    (("envdump.py",), (2, "")),
    (("envcheck.py", path, "DB_URL", "PORT"), (0, "ok\n")),
    (("envcheck.py", path, "NAME", "EMPTY", "SECRET"), (1, "missing: EMPTY\nmissing: SECRET\n")),
    (("envcheck.py", path), (2, "")),
]
for args, want in cases:
    got = tool(*args)
    if got != want:
        print(f"FAIL: {' '.join(args)} (with a sample .env) gave {got!r}, wanted {want!r}")


# 3. Both tools get their settings from envparse.parse: with it stubbed, they see the stub's.
STUB = (
    "import runpy, sys\n"
    "sys.path.insert(0, sys.argv[1])\n"
    "import envparse\n"
    "envparse.parse = lambda text: {'FROM_ENVPARSE': 'yes'}\n"
    "sys.argv = sys.argv[2:]\n"
    "runpy.run_path(sys.argv[0], run_name='__main__')\n"
)
if os.path.isfile(os.path.join(repo, "envparse.py")):
    for args, want in [(("envdump.py", path), "FROM_ENVPARSE=yes\n"),
                       (("envcheck.py", path, "FROM_ENVPARSE"), "ok\n")]:
        run = subprocess.run([sys.executable, "-c", STUB, repo, *args], capture_output=True,
                             text=True, cwd=repo)
        if run.stdout != want:
            print(f"FAIL: {args[0]} does not get its settings from envparse.parse (with parse "
                  f"stubbed it printed {run.stdout!r}, wanted {want!r})")
PY
[ -s "$tmp/result" ] && { failed=1; cat "$tmp/result"; }

(cd "$repo" && make test) >"$tmp/test.log" 2>&1 || {
  fail "make test failed:"; tail -n 20 "$tmp/test.log"; }

[ "$failed" -eq 0 ] && echo "PASS: envparse-extract"
[ "$failed" -eq 0 ]
