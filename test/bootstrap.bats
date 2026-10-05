#!/usr/bin/env bats
# Environment bootstrap (SPEC §3.2).

load test_helper

setup() { cs_test_setup; }

@test "bootstrap detects the OS, forces LC_ALL=C and picks an absolute awk" {
  cs_load_core
  [[ $CS_OS == windows || $CS_OS == linux ]]
  [ "$LC_ALL" = C ]
  [[ $CS_AWK == /* ]]
  [ -x "$CS_AWK" ]
}

@test "WSL is detected only on linux" {
  cs_load_core
  if [[ $CS_OS == windows ]]; then [ "$CS_WSL" = 0 ]; fi
  [[ $CS_WSL == 0 || $CS_WSL == 1 ]]
}

@test "CS_AWK override is honoured" {
  export CS_AWK=awk
  cs_load_core
  [ "$CS_AWK" = "$(command -v awk)" ]
}

@test "CS_AWK pointing to a missing awk is fatal" {
  run env CS_AWK=no-such-awk-xyz bash -c 'source "$CS_ROOT/lib/core.sh"; cs_bootstrap'
  [ "$status" -eq 1 ]
  [[ $output == *"CS_AWK=no-such-awk-xyz not found"* ]]
}

@test "a missing tool is fatal, named, and comes with an install hint" {
  run env CS_TEST_EXTRA_TOOLS="no-such-tool-a no-such-tool-b" bash -c 'source "$CS_ROOT/lib/core.sh"; cs_bootstrap'
  [ "$status" -eq 1 ]
  [[ $output == *"missing required tools: no-such-tool-a no-such-tool-b"* ]]
  [[ $output == *"sudo apt install"* || $output == *"Git for Windows"* ]]
}

@test "install hint maps tools to apt packages without duplicates" {
  source "$CS_ROOT/lib/core.sh"
  CS_OS=linux
  run cs_install_hint curl jq sha256sum stat find
  [ "$output" = "sudo apt install curl jq coreutils findutils" ]
}

@test "bash version gate accepts >= 4.4 only" {
  source "$CS_ROOT/lib/core.sh"
  ! cs_bash_version_ok 3 2
  ! cs_bash_version_ok 4 3
  cs_bash_version_ok 4 4
  cs_bash_version_ok 5 0
}

@test "CS_HOME honours CLAUDE_SYNC_HOME" {
  cs_load_core
  [ "$CS_HOME" = "$CLAUDE_SYNC_HOME" ]
}

@test "CS_HOME defaults to USERPROFILE on Windows" {
  source "$CS_ROOT/lib/core.sh"
  unset CLAUDE_SYNC_HOME
  CS_OS=windows USERPROFILE='C:\Users\Some One' cs_set_home
  [ "$CS_HOME" = "/c/Users/Some One/.claude-sync" ]
}

@test "saved proxy is exported unless HTTPS_PROXY is already set" {
  mkdir -p "$CLAUDE_SYNC_HOME"
  printf 'proxy=http://proxy.local:3128\n' >"$CLAUDE_SYNC_HOME/config"
  unset HTTPS_PROXY
  cs_load_core
  [ "$HTTPS_PROXY" = "http://proxy.local:3128" ]
}
