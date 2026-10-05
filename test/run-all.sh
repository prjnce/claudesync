#!/usr/bin/env bash
# Local stand-in for the CI matrix (.github/workflows/test.yml). Jobs run in parallel; each job's output
# is printed in full when it finishes, then a summary.
#   Git Bash: bats (gawk) here, and inside WSL: bats (gawk), bats (mawk), shellcheck.
#   Linux/WSL: bats (gawk), bats (mawk), shellcheck.
# Usage: test/run-all.sh [--local] [bats args...]
#   --local          only run the jobs for the current OS (used for the WSL leg)
# Env: CS_TEST_WSL_DISTRO (default Ubuntu2404), CS_TEST_WSL_USER (default $USERNAME / $USER)
set -Eeuo pipefail
shopt -s inherit_errexit

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
bats="$root/test/vendor/bats-core/bin/bats"
local_only=0
if [[ ${1:-} == --local ]]; then
  local_only=1
  shift
fi
logdir=$(mktemp -d)
names=()
pids=()

# job NAME CMD...: start CMD in the background, output to its own log.
job() {
  local name=$1
  shift
  names+=("$name")
  ("$@") >"$logdir/${#names[@]}.log" 2>&1 &
  pids+=($!)
}

shellcheck_all() {
  cd "$root" && shellcheck -x bin/claude-sync lib/*.sh test/*.bash test/run-all.sh
}

case $OSTYPE in
  msys* | cygwin*)
    job "git-bash (gawk)" "$bats" "$@" "$root/test"
    if ((!local_only)); then
      distro=${CS_TEST_WSL_DISTRO:-Ubuntu2404}
      user=${CS_TEST_WSL_USER:-${USERNAME:-$USER}}
      winroot=$(cygpath -w "$root")
      job "wsl $distro" env MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
        wsl.exe -d "$distro" -u "$user" --cd "$winroot" --exec bash test/run-all.sh --local "$@"
    fi
    ;;
  linux*)
    job "linux (gawk)" env CS_AWK=gawk "$bats" "$@" "$root/test"
    if command -v mawk >/dev/null 2>&1; then
      job "linux (mawk)" env CS_AWK=mawk "$bats" "$@" "$root/test"
    else
      printf 'mawk not installed: skipping mawk job\n'
    fi
    if command -v shellcheck >/dev/null 2>&1; then
      job "shellcheck" shellcheck_all
    else
      printf 'shellcheck not installed: skipping\n'
    fi
    ;;
esac

fail=0
summary=
for i in "${!pids[@]}"; do
  if wait "${pids[i]}"; then r=PASS; else r=FAIL; fail=1; fi
  printf '\n=== %s ===\n' "${names[i]}"
  tr -d '\r' <"$logdir/$((i + 1)).log"
  printf '=== %s: %s ===\n' "${names[i]}" "$r"
  summary+="  ${names[i]}: $r"$'\n'
done
rm -rf -- "$logdir"
printf '\nSummary:\n%s' "$summary"
exit "$fail"
