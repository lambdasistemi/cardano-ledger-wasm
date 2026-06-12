#!/usr/bin/env bash
# Mechanical gate for lambdasistemi/cardano-ledger-wasm#86 (W1).
# Mirrors CI: wasm build + flake check + dev-shell wasm build + format + hlint.
#
# Usage:
#   ./gate.sh                 run the full mechanical gate
#   ./gate.sh commit_gate SHA check one commit's message shape
#   ./gate.sh finalization_audit PR specs/<...>/tasks.md
set -euo pipefail

commit_gate() {
  local sha="${1:?usage: commit_gate <sha>}"
  local subject body
  subject=$(git show -s --format=%s "$sha")
  body=$(git show -s --format=%b "$sha" | sed '/^[[:space:]]*$/d')

  case "$subject" in
    [Ww][Ii][Pp]*|draft*|Draft*|tmp*|Tmp*|temp*|Temp*|fixup!*|squash!*)
      echo "bad subject: $subject"; return 1 ;;
  esac

  printf '%s\n' "$subject" \
    | grep -Eq '^(feat|fix|docs|test|refactor|perf|build|ci|chore|style|revert)(\([^)]+\))?!?: .+' \
    || { echo "subject is not an approved Conventional Commit"; return 1; }

  [ -n "$body" ] || { echo "commit body is empty"; return 1; }

  case "$subject" in
    chore*|docs*|build*|ci*|style*|revert*) ;;
    *)
      printf '%s\n' "$body" \
        | grep -Eq '^Tasks:[[:space:]]*T[0-9]+([[:space:]]*,[[:space:]]*T[0-9]+)*[[:space:]]*$' \
        || { echo "commit body missing 'Tasks: T###[, T###]' trailer"; return 1; }
      ;;
  esac
}

finalization_audit() {
  local pr="${1:?usage: finalization_audit <pr-number> [tasks.md]}"
  local task_file="${2:-}"
  local base_ref base fail=0
  local task_files=()
  base_ref=$(gh pr view "$pr" --json baseRefName -q .baseRefName)
  git fetch origin "$base_ref" >/dev/null
  base=$(git merge-base "origin/$base_ref" HEAD)
  while read -r sha; do
    if ! commit_gate "$sha" >/dev/null 2>&1; then
      printf '%s\t%s\n' "${sha:0:7}" "$(git show -s --format=%s "$sha")"
      fail=1
    fi
  done < <(git rev-list --reverse "$base..HEAD")
  [ "$fail" -eq 0 ] || return 1
  if [ -z "$task_file" ]; then
    mapfile -t task_files < <(git diff --name-only "$base..HEAD" -- 'specs/*/tasks.md')
    if [ "${#task_files[@]}" -ne 1 ]; then
      echo "usage: finalization_audit <pr-number> <current specs/.../tasks.md>"
      return 1
    fi
    task_file="${task_files[0]}"
  fi
  [ -n "$task_file" ] || { echo "missing current ticket tasks.md"; return 1; }
  if grep -nE '^\s*-\s*\[ \]\s*T[0-9]+' "$task_file"; then
    echo "FAIL: open tasks remain in tasks.md"
    return 1
  fi
  echo "OK: every commit passes the message gate; $task_file is complete."
}

run_gate() {
  echo "== git diff --check =="
  git diff --check
  echo "== nix build .#cardano-ledger-wasm (wasm32-wasi artifact) =="
  nix build --quiet .#cardano-ledger-wasm
  echo "== nix flake check (wasm artifact + smoke checks) =="
  nix flake check --quiet
  echo "== nix develop -c just dev-build (offline wasm32-wasi cabal build) =="
  nix develop --quiet -c just dev-build
  echo "== nix run .#format-check (fourmolu) =="
  nix run --quiet .#format-check
  echo "== nix run .#hlint =="
  nix run --quiet .#hlint
  echo "GATE OK"
}

case "${1:-run}" in
  run) run_gate ;;
  commit_gate) shift; commit_gate "$@" ;;
  finalization_audit) shift; finalization_audit "$@" ;;
  *) echo "unknown subcommand: $1" >&2; exit 2 ;;
esac
