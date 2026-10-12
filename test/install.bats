#!/usr/bin/env bats
# install: copy the runtime to ~/.claude-sync/app and write the shim, so the unpacked release can be deleted.

load test_helper

setup() {
  cs_test_setup
  export CS_SCHED_KIND=linux
  # a release-shaped source directory (only what a release contains), outside the repository
  SRC="$BATS_TEST_TMPDIR/release/claude-sync-x"
  mkdir -p "$SRC"
  cp -R "$CS_ROOT/bin" "$CS_ROOT/lib" "$SRC/"
  [ ! -d "$CS_ROOT/launcher" ] || cp -R "$CS_ROOT/launcher" "$SRC/"
}

inst() { bash "$SRC/bin/claude-sync" install "$@"; }

@test "install copies bin, lib and launcher to the app directory and writes the shim" {
  run inst
  [ "$status" -eq 0 ]
  [ -x "$CLAUDE_SYNC_HOME/app/bin/claude-sync" ]
  [ -f "$CLAUDE_SYNC_HOME/app/lib/core.sh" ]
  [ -f "$CLAUDE_SYNC_HOME/app/lib/i18n/vi.sh" ]
  [ -f "$CLAUDE_SYNC_HOME/app/lib/transform.awk" ]
  [ -x "$HOME/.local/bin/claude-sync" ]
  [[ $output == *"installed to"* ]]
  [[ $output == *"claude-sync setup"* ]]
}

@test "install leaves out tests and docs" {
  mkdir -p "$SRC/test" "$SRC/docs"
  : >"$SRC/test/x.bats"
  run inst
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_SYNC_HOME/app/test" ]
  [ ! -e "$CLAUDE_SYNC_HOME/app/docs" ]
}

@test "the shim keeps working after the unpacked release is deleted" {
  run inst
  [ "$status" -eq 0 ]
  rm -rf "$BATS_TEST_TMPDIR/release"
  run "$HOME/.local/bin/claude-sync" --version
  [ "$status" -eq 0 ]
  [[ $output == claude-sync* ]]
}

@test "install again replaces the copy, dropping files a newer release no longer has" {
  run inst
  [ "$status" -eq 0 ]
  : >"$CLAUDE_SYNC_HOME/app/lib/removed_in_new_release.sh"
  run inst
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_SYNC_HOME/app/lib/removed_in_new_release.sh" ]
  [ -f "$CLAUDE_SYNC_HOME/app/lib/core.sh" ]
  [ -z "$(ls -d "$CLAUDE_SYNC_HOME"/app.new.* "$CLAUDE_SYNC_HOME"/app.old.* 2>/dev/null)" ]
}

@test "install run from the installed copy only refreshes the shim" {
  run inst
  [ "$status" -eq 0 ]
  rm -f "$HOME/.local/bin/claude-sync"
  run bash "$CLAUDE_SYNC_HOME/app/bin/claude-sync" install
  [ "$status" -eq 0 ]
  [[ $output == *"Already running"* ]]
  [ -x "$HOME/.local/bin/claude-sync" ]
}

@test "install takes no arguments" {
  run inst extra
  [ "$status" -ne 0 ]
  [ ! -d "$CLAUDE_SYNC_HOME/app" ]
}

@test "install says when the shim directory is not in PATH" {
  run inst
  [ "$status" -eq 0 ]
  [[ $output == *"not in your PATH"* ]]
}
