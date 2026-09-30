#!/usr/bin/env bash
#
# gate_declaration_self_test.sh — break this repository's gate declaration on
# purpose, five times, and assert the checker goes red AND names the finding.
#
#   script/gate_declaration_self_test.sh
#
# WHY THIS EXISTS. A gate that has never been observed red is not a gate, and a
# red proof nobody can reproduce is a claim rather than evidence. This repository
# has a rule about exactly this — AGENTS.md: "A tripwire that has never been
# seen red is a check that has never been tested" — and gate.yml's own header
# lists the five breakages it was written against. This script is what makes
# that list re-runnable instead of a story about a Tuesday.
#
# IT NEEDS core's checker, NOT A COPY OF IT.
#
#   $CORE_PATH, or ../core beside this worktree
#
# which is the same seam the contract tier reads, so a developer who has core
# where the suite needs it already has it here. The checker's own verdict is
# never reimplemented: this script asserts on its output, so "the gate is
# red" is a fact about core's `harness/gate_check.py` and not about a grep
# somebody wrote to agree with a hoped-for result.
#
# WHAT IT DOES TO THIS WORKTREE, AND WHY THAT IS SAFE
#
# It deletes `bin/prime`, replaces it with `exit 0`, deletes a test file, and
# edits one number in `gate.yml`. Every one of those files is copied to a
# temporary directory first and restored by a trap on EXIT, INT and TERM, so an
# interrupted run does not leave a worktree with no gate in it. The final
# control re-runs the check afterwards, which is the only thing that actually
# proves the restores worked: a script that reports five reds and leaves the
# tree broken has proved nothing about the declaration.
#
# RUNTIME, AND WHY IT IS SLOW
#
# Measured: 181 seconds end to end on a saturated 8-core host (load average
# 83-107), of which two `--prove` runs are the whole cost. Cases 1 and 5 are
# fast because the gate they break exits in under a second, and case 4 is
# static. The cases are strictly sequential and must stay that way: they mutate
# one worktree, and two `--prove` runs in one checkout race on the same
# per-worker test databases, which is the failure mode AGENTS.md warns about
# under "One checkout, one suite." Run it when the machine has room for it.
#
# THE EXIT CODE IS THE WHOLE CONTRACT
#
#   0   every case went red, named the finding it expected, and the tree came
#       back clean.
#   1   at least one case did not. Either the gate did not notice, or it noticed
#       and said something else, or a restore failed. Both are defects and both
#       are this script's to report rather than to work around.
#
# NOTHING HERE WEAKENS AN ASSERTION, ADDS A SLEEP, OR RAISES A RETRY COUNT.
# Every case is a deletion, a substitution, a number, or a PATH. A gate that can
# only be made red by changing what the suite verifies is not being tested by
# this script; it is being rewritten by it.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"

# --- where is the checker? ----------------------------------------------------
core_path="${CORE_PATH:-$repo_root/../core}"
checker="$core_path/harness/bin/gate-check"
if [ ! -x "$checker" ]; then
  echo "gate_declaration_self_test: $checker is missing or not executable." >&2
  echo "  Point CORE_PATH at a cafaye/core checkout, or put core beside this" >&2
  echo "  worktree. This script does not vendor the checker: a second copy of it" >&2
  echo "  would be a second answer to the question the copy is being asked." >&2
  exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/billing-gate-self-test.XXXXXX")"
saved="$work/saved"
mkdir -p "$saved/bin" "$saved/test/integration"

# Pristine copies, taken once. Restoring from these rather than from git is
# deliberate: `git checkout --` cannot restore a file that is not tracked, and
# this script has to work on a worktree where gate.yml is still new.
cp -p "$repo_root/bin/prime" "$saved/bin/prime"
cp -p "$repo_root/gate.yml" "$saved/gate.yml"
cp -p "$repo_root/test/integration/health_test.rb" "$saved/test/integration/health_test.rb"

restore() {
  cp -p "$saved/bin/prime" "$repo_root/bin/prime"
  cp -p "$saved/gate.yml" "$repo_root/gate.yml"
  cp -p "$saved/test/integration/health_test.rb" "$repo_root/test/integration/health_test.rb"
}
trap 'restore' EXIT INT TERM

passed=0
failed=0

note() { printf '\n--- %s\n' "$1"; }

# verdict <case name> <expected finding> <static|prove> [PATH prefix]
#
# Runs the checker, and asserts THREE things rather than one, because "it went
# red" and "it went red for the reason I broke it" are different claims:
#   * the exit code is 1 (a failure, not a warning and not a crash),
#   * the expected finding id is in the report,
#   * the report is non-empty, so a finding was named rather than implied.
verdict() {
  local name="$1" expect="$2" mode="$3" path_prefix="${4:-}"
  local log="$work/$name.log" rc=0
  if [ "$mode" = "prove" ]; then
    if [ -n "$path_prefix" ]; then
      PATH="$path_prefix:$PATH" "$checker" --prove "$repo_root" >"$log" 2>&1 || rc=$?
    else
      "$checker" --prove "$repo_root" >"$log" 2>&1 || rc=$?
    fi
  else
    if [ -n "$path_prefix" ]; then
      PATH="$path_prefix:$PATH" "$checker" "$repo_root" >"$log" 2>&1 || rc=$?
    else
      "$checker" "$repo_root" >"$log" 2>&1 || rc=$?
    fi
  fi

  # The report, so the reader sees the red rather than being told about it.
  # The gate's own stdout stays in core's log file; the checker deliberately
  # does not echo it, and neither does this script.
  grep -E '^(FAIL|WARN|OK) ' "$log" | sed 's/^/    /' || true

  if [ "$rc" -ne 1 ]; then
    printf '    CASE FAILED: expected exit 1, got %s\n' "$rc" >&2
    failed=$((failed + 1))
    restore
    return
  fi
  if ! grep -qF "$expect" "$log"; then
    printf '    CASE FAILED: exit was 1 but %s was never named\n' "$expect" >&2
    failed=$((failed + 1))
    restore
    return
  fi
  printf '    ok: exit 1, and it named %s\n' "$expect"
  passed=$((passed + 1))
  restore
}

# --- the control --------------------------------------------------------------
# A run of reds proves nothing without this one first. If the declaration is
# already wrong, every case below would "pass" by being red for the wrong
# reason, and the five would be measuring the control's bug.
note "control: the declaration as committed"
rc=0
"$checker" "$repo_root" >"$work/control.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "gate_declaration_self_test: the UNBROKEN declaration is already red (exit $rc)." >&2
  echo "  Nothing below would mean anything. Fix this first." >&2
  sed 's/^/    /' "$work/control.log" >&2
  exit 1
fi
echo "    ok: exit 0, nothing to fix before the cases below"

# --- 1: the false green -------------------------------------------------------
# A repository whose declaration is entirely true about a gate that exits 0
# without running anything. The command exists, it is executable, the mise task
# resolves to it, CI calls it — and the repository is ungated. This is the case
# the format exists for, and it is the only one here that needs no reasoning
# about which finding "should" fire: six of them do.
note "1: bin/prime replaced by a body that is exactly 'exit 0'"
printf '#!/usr/bin/env bash\nexit 0\n' >"$repo_root/bin/prime"
chmod +x "$repo_root/bin/prime"
verdict "case1-exit-zero" "gate.proof-missing" prove

# --- 2: a deleted test file ---------------------------------------------------
# guard's case, and the reason this repository declares TWO numeric floors
# rather than one. `test/integration/health_test.rb` holds 5 tests and is
# referenced by nothing: deleting it takes the run count to 758 and the linted
# file count to 92, so both floors move and both must complain.
#
# In guard, a `pass` floor set with a margin of five stayed GREEN through a
# deletion of exactly five tests, and only the `files` floor caught it. There is
# no margin on either floor here, so this case must be caught twice over — and
# the file this removes deliberately touches no money, so the 100%-coverage
# gate cannot be what makes the run red. A case that went red for a third
# reason would not show what it was written to show.
note "2: rm test/integration/health_test.rb (5 tests, no money, referenced by nothing)"
rm -f "$repo_root/test/integration/health_test.rb"
verdict "case2-deleted-test" "gate.floor" prove

# --- 3: a floor that is a number and not decoration ---------------------------
# Raising the floor one past the measured count. If this does not go red, the
# floors are not being read and the other four cases are passing on the exit
# code alone.
note "3: the suite floor raised from 763 to 764"
sed 's/^      minimum: 763$/      minimum: 764/' \
  "$repo_root/gate.yml" >"$work/gate.yml.raised"
mv "$work/gate.yml.raised" "$repo_root/gate.yml"
if grep -q '^      minimum: 764$' "$repo_root/gate.yml"; then
  verdict "case3-raised-floor" "gate.floor" prove
else
  echo "    CASE COULD NOT RUN: the sed did not find the line to raise." >&2
  echo "    If the declaration's formatting changed, fix this case." >&2
  failed=$((failed + 1))
  restore
fi

# --- 4: a script the proofs name, gone ---------------------------------------
# The static half catches this one; no suite run needed, which is why it is here
# as well as the three that are not cheap. `gate.command-missing` and
# `gate.entrypoint-missing` are the findings, and neither needs the gate to run.
note "4: rm bin/prime (the entrypoint and the command both name it)"
rm -f "$repo_root/bin/prime"
verdict "case4-missing-entrypoint" "gate.entrypoint-missing" static

# --- 5: the wrong toolchain answers -------------------------------------------
# cafaye-rb's case. Before this repository read `.ruby-version` and compared,
# a `ruby` on PATH answering anything but 4.0.1 produced
# `Could not find 'bundler' (4.0.18) (Gem::GemNotFoundException)` and exit 1 —
# red, but a red naming a gem four steps from the toolchain that is wrong.
#
# So this case asserts the MESSAGE and not merely the exit code: the shim below
# answers 3.4.2, and the assertion is that the report names both the pin and the
# answer. A case that only checked "nonzero" would have passed against the old
# bin/prime too, and would therefore have been a test of nothing.
note "5: a ruby first on PATH that answers 3.4.2 instead of 4.0.1"
shim="$work/wrong-ruby"
mkdir -p "$shim"
printf '#!/bin/sh\nprintf 3.4.2\n' >"$shim/ruby"
chmod +x "$shim/ruby"
verdict "case5-wrong-toolchain" "gate.nonzero" prove "$shim"
if grep -qF "gate.nonzero" "$work/case5-wrong-toolchain.log"; then
  # bin/prime's own words are in its log, not the checker's, so ask bin/prime.
  rc=0
  PATH="$shim:$PATH" "$repo_root/bin/prime" >"$work/case5-prime.log" 2>&1 || rc=$?
  if [ "$rc" -eq 127 ] &&
     grep -qF '4.0.1' "$work/case5-prime.log" &&
     grep -qF '3.4.2' "$work/case5-prime.log"; then
    echo "    ok: bin/prime exited 127 naming both 4.0.1 and 3.4.2"
  else
    echo "    CASE FAILED: bin/prime did not refuse the wrong interpreter by name." >&2
    echo "    (exit $rc)" >&2
    sed 's/^/      /' "$work/case5-prime.log" >&2 || true
    failed=$((failed + 1))
  fi
  restore
fi

# --- and the tree came back ----------------------------------------------------
# The only thing that proves the restores worked. Without it, five reds and a
# broken worktree is a script that damages the repository it is testing.
note "control again: the tree after five breakages"
rc=0
"$checker" "$repo_root" >"$work/control2.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "gate_declaration_self_test: the tree did NOT come back clean (exit $rc)." >&2
  sed 's/^/    /' "$work/control2.log" >&2
  failed=$((failed + 1))
else
  echo "    ok: exit 0 — every breakage was reverted"
fi

# git is asked, not trusted: `bin/prime`'s executable bit and gate.yml's exact
# bytes are what a restore has to get right, and a file that is merely present
# is not the same file.
note "control again: the four files are byte-identical to the start"
if git -C "$repo_root" diff --quiet -- bin/prime gate.yml test/integration/health_test.rb 2>/dev/null; then
  echo "    ok: no diff against HEAD in the files this script touched"
else
  # A new file is untracked, and `git diff` says nothing about those. Only an
  # unexpected diff is a problem, so this is reported, not treated as a failure.
  if git -C "$repo_root" ls-files --error-unmatch gate.yml >/dev/null 2>&1; then
    echo "    FAIL: the tree still differs from HEAD after restore" >&2
    git -C "$repo_root" diff --stat -- bin/prime gate.yml test/integration/health_test.rb >&2
    failed=$((failed + 1))
  else
    echo "    ok: gate.yml is not tracked yet, so no diff is expected; files restored"
  fi
fi

printf '\n=== %d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  echo "The declaration is NOT proven red-capable. Logs are in $work" >&2
  exit 1
fi
echo "Logs are in $work"
exit 0
