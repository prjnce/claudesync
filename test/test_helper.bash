# shellcheck shell=bash
# Shared setup for bats tests: isolated HOME / CLAUDE_SYNC_HOME per test, helpers to run the CLI.

CS_ROOT=$(cd -- "$BATS_TEST_DIRNAME/.." && pwd -P)
export CS_ROOT

cs_test_setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export CLAUDE_SYNC_HOME="$HOME/.claude-sync"
  mkdir -p "$HOME"
  unset CS_CORE_LOADED CS_TEST_EXTRA_TOOLS CS_VERBOSE
}

# cs_load_core: source lib/core.sh into the test shell and bootstrap it.
cs_load_core() {
  # shellcheck source=lib/core.sh
  source "$CS_ROOT/lib/core.sh"
  cs_bootstrap
}

# cli ARGS...: run bin/claude-sync (use with bats `run`).
cli() {
  bash "$CS_ROOT/bin/claude-sync" "$@"
}
