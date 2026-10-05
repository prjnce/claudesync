#!/usr/bin/env bash
# Local stand-in for the CI matrix (.github/workflows/test.yml).
#   Git Bash: bats (gawk), then the same suite inside WSL with gawk and with mawk, plus shellcheck in WSL.
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
fail=0

job() {
  local name=$1
  shift
  printf '\n=== %s ===\n' "$name"
  if "$@"; then
    printf '=== %s: PASS ===\n' "$name"
  else
    printf '=== %s: FAIL ===\n' "$name"
    fail=1
  fi
}

shellcheck_all() {
  (cd "$root" && shellcheck -x bin/claude-sync lib/*.sh test/*.bash test/run-all.sh)
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

exit "$fail"
