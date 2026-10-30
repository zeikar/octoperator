#!/usr/bin/env bash
# retry.sh — run a command until it succeeds or the attempts run out.
set -u

attempts="${RETRY_ATTEMPTS:-5}"
delay="${RETRY_DELAY:-2}"

if [ $# -eq 0 ]; then
  echo "usage: retry.sh COMMAND [ARG...]" >&2
  exit 2
fi

n=1
while :; do
  "$@"
  status=$?
  if [ "$status" -eq 0 ] || [ "$n" -ge "$attempts" ]; then
    exit "$status"
  fi
  echo "retry.sh: attempt $n/$attempts failed (exit $status), retrying in ${delay}s" >&2
  n=$((n + 1))
  sleep "$delay"
done
