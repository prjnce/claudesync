#!/usr/bin/env bats
# Claude Code hooks (ticket #27): install/uninstall of settings.json entries and the two handlers.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  cs_test_setup
  export CS_CLAUDE_DIR="$HOME/.claude"
  export CS_SCHED_KIND=linux
  mkdir -p "$CS_CLAUDE_DIR" "$CLAUDE_SYNC_HOME/state"
  # a stub systemctl so that kick never touches the machine
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$STUBS/systemctl"
  chmod +x "$STUBS/systemctl"
  export PATH="$STUBS:$PATH"
}

cs() { bash "$CS_ROOT/bin/claude-sync" "$@"; }
settings() { cat "$CS_CLAUDE_DIR/settings.json"; }

# status JSON helper: status '<json>'
status() { printf '%s\n' "$1" >"$CLAUDE_SYNC_HOME/state/status.json"; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

@test "install twice does not duplicate; entries carry the marker; no CR; a backup is kept" {
  printf '{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}\n' >"$CS_CLAUDE_DIR/settings.json"
  run cs hooks install
  [ "$status" -eq 0 ]
  run cs hooks install
  [ "$status" -eq 0 ]
  [ "$(jq '.hooks.SessionStart | length' "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" -eq 1 ]
  [ "$(jq '.hooks.UserPromptSubmit | length' "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" -eq 1 ]
  [ "$(jq '.hooks.SessionEnd | length' "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" -eq 1 ]
  [ "$(jq -r '.hooks.SessionStart[0].matcher' "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" = 'startup|resume' ]
  [ "$(jq -r '.hooks.SessionStart[0].hooks[0].timeout' "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" = 2 ]
  jq -r '.hooks[][].hooks[].command' "$CS_CLAUDE_DIR/settings.json" | grep -c '#claude-sync' | grep -qx 3
  ! grep -q "$(printf '\r')" "$CS_CLAUDE_DIR/settings.json"
  [ "$(jq -r .theme "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" = dark ]
  [ -n "$(ls "$CLAUDE_SYNC_HOME/backups" | grep '^settings.json')" ]
  # the Stop hook of the user is still there and there is no hook of ours on Stop
  [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" = 'echo mine' ]
}

@test "uninstall removes only our entries and keeps the user's own hooks and settings" {
  printf '{"theme":"dark","hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"echo mine"}]}]}}\n' >"$CS_CLAUDE_DIR/settings.json"
  cs hooks install >/dev/null
  run cs hooks uninstall
  [ "$status" -eq 0 ]
  [ "$(jq -c '.hooks' "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" = '{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"echo mine"}]}]}' ]
  [ "$(jq -r .theme "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" = dark ]
  # with nothing else left the hooks key goes away
  printf '{"a":1}\n' >"$CS_CLAUDE_DIR/settings.json"
  cs hooks install >/dev/null
  cs hooks uninstall >/dev/null
  [ "$(jq -c . "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" = '{"a":1}' ]
}

@test "session-start: silent when everything is fine; one message per problem otherwise" {
  status "{\"state\":\"OK\",\"last_ok_pull\":\"$(now_iso)\",\"boot_time\":\"2020-01-01T00:00:00Z\",\"behind\":{},\"live_elsewhere\":{},\"waiting_map\":[]}"
  run bash -c 'echo "{\"session_id\":\"s1\",\"cwd\":\"/x\"}" | bash "$CS_ROOT/bin/claude-sync" hook session-start'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  status '{"state":"LOGIN_REQUIRED","last_ok_pull":"2020-01-01T00:00:00Z","boot_time":"2020-01-01T00:00:00Z","behind":{"s1":{"machine":"PC-B","lines":42,"since":"2026-10-11T10:00:00Z"}},"live_elsewhere":{"s1":{"machine":"PC-C"}},"waiting_map":[]}'
  run bash -c 'echo "{\"session_id\":\"s1\",\"cwd\":\"/x\"}" | bash "$CS_ROOT/bin/claude-sync" hook session-start'
  [ "$status" -eq 0 ]
  msg=$(jq -r .systemMessage <<<"$output" | tr -d '\r')
  [[ $msg == *'login'* ]]
  [[ $msg == *'PC-B'* && $msg == *'42'* ]]
  [[ $msg == *'PC-C'* ]]
  [[ $msg == *'last successful sync'* ]]
  [ -e "$CLAUDE_SYNC_HOME/pending" ]
}

@test "session-start: a folder that is a candidate for a waiting project gets the exact map command, once a day" {
  status "{\"state\":\"OK\",\"last_ok_pull\":\"$(now_iso)\",\"boot_time\":\"2020-01-01T00:00:00Z\",\"behind\":{},\"live_elsewhere\":{}}"
  mkdir -p "$HOME/projects/TransFlowX"
  printf '#kind\tkey\talias\tmachines\tremote_roots\tsessions\tbytes\tfirst_seen\tnotified_sessions\tcandidates\tdecision\n' >"$CLAUDE_SYNC_HOME/state/pending_map.tsv"
  printf 'remote\tp1\tTransFlow\tA\tD:/x\t3\t100\t1\t0\t%s|name|43\tpending\n' "$HOME/projects/TransFlowX" >>"$CLAUDE_SYNC_HOME/state/pending_map.tsv"
  inp="{\"session_id\":\"s1\",\"cwd\":\"$HOME/projects/TransFlowX\"}"
  run bash -c 'printf "%s" "$INP" | bash "$CS_ROOT/bin/claude-sync" hook session-start' INP="$inp"
  export INP="$inp"
  run bash -c 'printf "%s" "$INP" | bash "$CS_ROOT/bin/claude-sync" hook session-start'
  [ "$status" -eq 0 ]
  msg=$(jq -r .systemMessage <<<"$output" | tr -d '\r')
  [[ $msg == *"claude-sync projects map TransFlow \"$HOME/projects/TransFlowX\""* ]]
  # the second start in the same day says nothing about it
  run bash -c 'printf "%s" "$INP" | bash "$CS_ROOT/bin/claude-sync" hook session-start'
  [ -z "$output" ]
}

@test "session-start on a folder that is no candidate only reminds once a day to run projects map" {
  status "{\"state\":\"OK\",\"last_ok_pull\":\"$(now_iso)\",\"boot_time\":\"2020-01-01T00:00:00Z\",\"behind\":{},\"live_elsewhere\":{}}"
  printf '#kind\tkey\talias\tmachines\tremote_roots\tsessions\tbytes\tfirst_seen\tnotified_sessions\tcandidates\tdecision\n' >"$CLAUDE_SYNC_HOME/state/pending_map.tsv"
  printf 'remote\tp1\tTransFlow\tA\tD:/x\t3\t100\t1\t0\t-\tpending\n' >>"$CLAUDE_SYNC_HOME/state/pending_map.tsv"
  export INP='{"session_id":"s1","cwd":"/somewhere/else"}'
  run bash -c 'printf "%s" "$INP" | bash "$CS_ROOT/bin/claude-sync" hook session-start'
  [[ $(jq -r .systemMessage <<<"$output") == *'claude-sync projects map'* ]]
  run bash -c 'printf "%s" "$INP" | bash "$CS_ROOT/bin/claude-sync" hook session-start'
  [ -z "$output" ]
}

@test "prompt-guard: a behind session is blocked (exit 2) with the message; warn lets it through; off is silent" {
  status '{"state":"OK","behind":{"s1":{"machine":"PC-B","lines":3,"since":"2026-10-11T10:00:00Z"}}}'
  export INP='{"session_id":"s1","prompt":"hi"}'
  run -2 bash -c 'printf "%s" "$INP" | bash "$CS_ROOT/bin/claude-sync" hook prompt-guard'
  [[ $output == *'PC-B'* ]]
  [ -e "$CLAUDE_SYNC_HOME/pending" ]
  cs config set guard warn >/dev/null
  run bash -c 'printf "%s" "$INP" | bash "$CS_ROOT/bin/claude-sync" hook prompt-guard'
  [ "$status" -eq 0 ]
  [[ $(jq -r .systemMessage <<<"$output") == *'PC-B'* ]]
  cs config set guard off >/dev/null
  run bash -c 'printf "%s" "$INP" | bash "$CS_ROOT/bin/claude-sync" hook prompt-guard'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cs config set guard block >/dev/null
  run bash -c 'echo "{\"session_id\":\"other\"}" | bash "$CS_ROOT/bin/claude-sync" hook prompt-guard'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session-start stays fast with 500 sessions in the DB" {
  status "{\"state\":\"OK\",\"last_ok_pull\":\"$(now_iso)\",\"boot_time\":\"2020-01-01T00:00:00Z\",\"behind\":{},\"live_elsewhere\":{}}"
  {
    printf '#sid\tproject_id\tdir\tlocal_size\tlocal_mtime\tinstalled_len\tinstalled_sha\tbase\tbase_segs_ref\tstatus\tflags\tupdated\n'
    for i in $(seq 1 500); do printf 's%s\tp1\td\t1\t1\t1\t-\tb\t-\tsynced\t-\t1\n' "$i"; done
  } >"$CLAUDE_SYNC_HOME/state/sessions.tsv"
  export INP='{"session_id":"s1","cwd":"/x"}'
  start=$(date +%s%N)
  run bash -c 'printf "%s" "$INP" | bash "$CS_ROOT/bin/claude-sync" hook session-start'
  end=$(date +%s%N)
  [ "$status" -eq 0 ]
  ((end - start < 2000000000)) || { echo "took $(((end - start) / 1000000)) ms"; false; }
}
