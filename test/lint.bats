#!/usr/bin/env bats
# Repository hygiene. Git never converts line endings here (.gitattributes: * -text),
# so a CRLF script would reach Linux as-is and fail with "bash\r: No such file or directory".

load test_helper

@test "scripts, awk programs, tests and workflows contain no CR bytes" {
  local f bad=()
  while IFS= read -r -d '' f; do
    [ "$(tr -cd '\r' <"$f" | wc -c)" -eq 0 ] || bad+=("${f#"$CS_ROOT"/}")
  done < <(find "$CS_ROOT/bin" "$CS_ROOT/lib" "$CS_ROOT/test" "$CS_ROOT/.github" \
    -path "$CS_ROOT/test/fixtures" -prune -o -path "$CS_ROOT/test/tmp" -prune -o \
    -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.bats' -o -name '*.awk' -o -name '*.yml' \
    -o -path "$CS_ROOT/bin/*" -o -path '*/bats-core/libexec/*' -o -path '*/bats-core/bin/*' \) -print0)
  if ((${#bad[@]})); then
    printf 'CRLF found in: %s\n' "${bad[@]}"
    return 1
  fi
}

@test "executables are committed with mode 100755 (Windows checkouts cannot set it)" {
  command -v git >/dev/null && git -C "$CS_ROOT" rev-parse --git-dir >/dev/null 2>&1 || skip "not a git checkout"
  local bad
  bad=$(git -C "$CS_ROOT" ls-files -s -- bin test/run-all.sh test/vendor/bats-core/bin test/vendor/bats-core/libexec |
    awk '$1 != "100755" { print $4 }')
  [ -z "$bad" ] || { printf 'not executable in git: %s\n' $bad; return 1; }
}

@test "test names are plain ASCII (bats on the Windows runner cannot look up other names)" {
  run bash -c 'LC_ALL=C grep -n "^@test.*[^ -~]" "$1"/test/*.bats' _ "$CS_ROOT"
  [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "entrypoints use the portable bash shebang" {
  for f in "$CS_ROOT/bin/claude-sync" "$CS_ROOT/test/run-all.sh"; do
    [ "$(head -n 1 "$f")" = '#!/usr/bin/env bash' ]
  done
}
