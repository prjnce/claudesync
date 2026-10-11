#!/usr/bin/env bats
# CLI dispatch and exit codes (SPEC §20).

load test_helper

setup() { cs_test_setup; }

@test "--version prints the version and exits 0" {
  run cli --version
  [ "$status" -eq 0 ]
  [[ $output == "claude-sync "* ]]
}

@test "no arguments prints usage and exits 0" {
  run cli
  [ "$status" -eq 0 ]
  [[ $output == *"usage: claude-sync"* ]]
}

@test "help lists the main commands" {
  run cli help
  [ "$status" -eq 0 ]
  for c in setup login sync run status repair doctor uninstall; do
    [[ $output == *"$c"* ]]
  done
}

@test "unknown command exits 2 (usage error)" {
  run cli frobnicate
  [ "$status" -eq 2 ]
  [[ $output == *"unknown command: frobnicate"* ]]
}

@test "an unknown subcommand is a usage error (exit 2)" {
  run cli service nonsense
  [ "$status" -eq 2 ]
  [[ $output == *"Usage: claude-sync service"* ]]
}

@test "works when invoked through a relative path from another directory" {
  cd "$BATS_TEST_TMPDIR"
  run bash "$CS_ROOT/bin/claude-sync" --version
  [ "$status" -eq 0 ]
}
