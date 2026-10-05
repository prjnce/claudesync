#!/usr/bin/env bats
# claude: config dir, scan, launch cwd, registry, retention, settings, never-sync (ticket #08).

load test_helper

setup() {
  cs_test_setup
  cs_load platform claude
  export CS_CLAUDE_DIR="$BATS_TEST_TMPDIR/claude"
  P="$CS_CLAUDE_DIR/projects"
  mkdir -p "$P"
}

w() { mkdir -p "${1%/*}"; printf '%s\n' "${@:2}" >"$1"; }

native_pid() { if cs_is_windows; then cat "/proc/$1/winpid"; else printf '%s\n' "$1"; fi; }

# --- config dir -------------------------------------------------------------------------------

@test "config dir: CS_CLAUDE_DIR > CLAUDE_CONFIG_DIR > home" {
  [ "$(cs_claude_dir)" = "$CS_CLAUDE_DIR" ]
  unset CS_CLAUDE_DIR
  CLAUDE_CONFIG_DIR=/x/cfg run cs_claude_dir
  [ "$output" = /x/cfg ]
  run cs_claude_dir
  if cs_is_windows; then
    [ "$output" = "$(cs_win_to_posix "$USERPROFILE")/.claude" ]
  else
    [ "$output" = "$HOME/.claude" ]
  fi
}

@test "config dir: Windows-form CLAUDE_CONFIG_DIR is converted; empty value is an error" {
  unset CS_CLAUDE_DIR
  if cs_is_windows; then
    CLAUDE_CONFIG_DIR='C:\Users\u\cfg' run cs_claude_dir
    [ "$output" = /c/Users/u/cfg ]
  fi
  CLAUDE_CONFIG_DIR= run cs_claude_dir
  [ "$status" -eq 1 ]
}

@test "CLAUDE_CODE_PROJECT_DIR_NAME is honoured only with CLAUDE_CONFIG_DIR and a valid name" {
  CLAUDE_CODE_PROJECT_DIR_NAME=mine run cs_claude_slug '/home/u/x'
  [ "$output" = -home-u-x ]
  CLAUDE_CONFIG_DIR=/c CLAUDE_CODE_PROJECT_DIR_NAME=mine run cs_claude_slug '/home/u/x'
  [ "$output" = mine ]
  CLAUDE_CONFIG_DIR=/c CLAUDE_CODE_PROJECT_DIR_NAME=COM1 run cs_claude_slug '/home/u/x'
  [ "$output" = -home-u-x ]
  CLAUDE_CONFIG_DIR=/c CLAUDE_CODE_PROJECT_DIR_NAME='a.b' run cs_claude_slug '/home/u/x'
  [ "$output" = -home-u-x ]
}

# --- scan, junk, duplicates ---------------------------------------------------------------------

make_tree() {
  w "$P/D--Projects-X/s1.jsonl" '{"cwd":"D:\\Projects\\X"}'
  w "$P/D--Projects-X/s1/subagents/agent-a.jsonl" '{}'
  w "$P/D--Projects-X/s1.jsonl.superseded-1" '{}'
  w "$P/D--Projects-X/s2.jsonl" '{"cwd":"D:\\Projects\\X"}' '{"type":"user"}'
  w "$P/-home-u-y/s3.jsonl" '{"cwd":"/home/u/y"}'
  w "$P/D--Projects-X.bak-20260925/s1.jsonl" '{"cwd":"/mnt/d/Projects/X"}'
  w "$P/D--Projects-X.bak-20260925/s2.jsonl" '{"cwd":"/mnt/d/Projects/X"}'
  touch -d @1790000000 "$P/D--Projects-X/s1.jsonl"
}

@test "scan lists top-level transcripts only, with size and mtime" {
  make_tree
  run cs_claude_scan
  [ "${#lines[@]}" -eq 5 ]
  printf '%s\n' "$output" | grep -qx "$(printf 'D--Projects-X\ts1\t%s\t1790000000' "$(stat -c %s "$P/D--Projects-X/s1.jsonl")")"
  ! printf '%s\n' "$output" | grep -q agent-a
  ! printf '%s\n' "$output" | grep -q superseded
}

@test "junk dirs and duplicate ids are reported" {
  make_tree
  run cs_claude_junk_dirs
  [ "$output" = D--Projects-X.bak-20260925 ]
  run cs_claude_dup_ids
  [ "${#lines[@]}" -eq 2 ]
  [[ ${lines[0]} == s1$'\t'* && ${lines[0]} == *D--Projects-X.bak-20260925* ]]
}

@test "empty or missing projects dir is not an error" {
  rm -rf "$P"
  [ -z "$(cs_claude_scan)" ]
  [ -z "$(cs_claude_junk_dirs)" ]
}

# --- launch cwd (P9) ----------------------------------------------------------------------------

@test "launch cwd: first top-level cwd, skipping lines without cwd and broken lines" {
  w "$BATS_TEST_TMPDIR/t.jsonl" \
    '{"type":"summary","summary":"x"}' \
    '{"cwd":"/broken' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"cwd":"/nested"}}]},"cwd":"/top"}' \
    '{"cwd":"/later"}'
  [ "$(cs_launch_cwd "$BATS_TEST_TMPDIR/t.jsonl")" = /top ]
}

@test "launch cwd: nested cwd alone does not count" {
  w "$BATS_TEST_TMPDIR/t.jsonl" \
    '{"type":"assistant","wireIngestContext":{"x":{"cwd":"/d/Projects/X"}}}' \
    '{"type":"user","cwd":"D:\\Projects\\X"}'
  [ "$(cs_launch_cwd "$BATS_TEST_TMPDIR/t.jsonl")" = 'D:\Projects\X' ]
}

@test "launch cwd: the last compact relocated line wins, anywhere in the file" {
  w "$BATS_TEST_TMPDIR/t.jsonl" \
    '{"cwd":"/a"}' \
    '{"type":"relocated","sessionId":"s","relocatedCwd":"/b"}' \
    '{"cwd":"/b"}' \
    '{"type":"relocated","sessionId":"s","relocatedCwd":"/c"}' \
    '{"type": "relocated", "relocatedCwd": "/spaced-is-ignored-by-claude"}'
  [ "$(cs_launch_cwd "$BATS_TEST_TMPDIR/t.jsonl")" = /c ]
}

@test "launch cwd: CRLF transcript and cwd beyond the first 50 candidate lines" {
  printf '{"cwd":"D:\\\\X"}\r\n{"type":"user"}\r\n' >"$BATS_TEST_TMPDIR/crlf.jsonl"
  [ "$(cs_launch_cwd "$BATS_TEST_TMPDIR/crlf.jsonl")" = 'D:\X' ]
  { for i in $(seq 1 60); do printf '{"cwd":broken%d\n' "$i"; done; printf '{"cwd":"/real"}\n'; } >"$BATS_TEST_TMPDIR/late.jsonl"
  [ "$(cs_launch_cwd "$BATS_TEST_TMPDIR/late.jsonl")" = /real ]
}

@test "launch cwd: no cwd at all returns 1" {
  w "$BATS_TEST_TMPDIR/t.jsonl" '{"type":"summary"}'
  run cs_launch_cwd "$BATS_TEST_TMPDIR/t.jsonl"
  [ "$status" -eq 1 ]
}

# --- registry -----------------------------------------------------------------------------------

@test "pid domain has Claude's format for this OS" {
  run cs_claude_pid_domain
  if cs_is_windows; then
    [[ $output =~ ^win32:[a-z0-9._-]+$ ]]
  else
    [[ $output =~ ^linux:[0-9a-f]*:pid:\[[0-9]+\]$ ]]
  fi
}

@test "procStart comparison follows Claude's rule" {
  cs_proc_start_same 134356359535852191 134356359535852191
  ! cs_proc_start_same 134356359535852191 134356359535852192
  cs_proc_start_same 134356359535852191 639000000000000000 # FILETIME vs .NET ticks: different units
  cs_proc_start_same 103708721 103708721
  ! cs_proc_start_same 103708721 103708722
}

@test "live sessions: only live pid + matching procStart + our domain (or none) count" {
  sleep 60 3>&- &
  local spid=$! npid start dom
  npid=$(native_pid "$spid")
  start=$(cs_proc_start_ids "$npid" | cut -f2)
  dom=$(cs_claude_pid_domain)
  local s="$CS_CLAUDE_DIR/sessions"
  mkdir -p "$s"
  printf '{"pid":%s,"sessionId":"live-1","procStart":"%s","pidDomain":"%s","status":"busy","cwd":"D:\\\\X"}' "$npid" "$start" "$dom" >"$s/$npid.json"
  printf '{"pid":%s,"sessionId":"no-domain","procStart":"%s","status":"idle","cwd":"/x"}' "$npid" "$start" >"$s/a.json"
  printf '{"pid":%s,"sessionId":"reused-pid","procStart":"1","pidDomain":"%s","status":"idle"}' "$npid" "$dom" >"$s/b.json"
  printf '{"pid":%s,"sessionId":"other-host","procStart":"%s","pidDomain":"win32:elsewhere"}' "$npid" "$start" >"$s/c.json"
  printf '{"pid":4294967,"sessionId":"dead","procStart":"1","pidDomain":"%s"}' "$dom" >"$s/d.json"
  printf '{"pid":%s,"sessionId":"half-wri' "$npid" >"$s/e.json"
  run cs_claude_live_sessions
  kill "$spid"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$(printf 'live-1\t%s\tbusy\tD:\\X' "$npid")" ] || [ "${lines[1]}" = "$(printf 'live-1\t%s\tbusy\tD:\\X' "$npid")" ]
  printf '%s\n' "$output" | grep -q '^no-domain'
}

@test "live sessions: no registry dir means nothing is open" {
  [ -z "$(cs_claude_live_sessions)" ]
}

# --- retention, settings ------------------------------------------------------------------------

@test "retention: default 30; user settings; project local overrides project and user" {
  [ "$(cs_claude_retention_days)" = 30 ]
  w "$CS_CLAUDE_DIR/settings.json" '{"cleanupPeriodDays":3650}'
  [ "$(cs_claude_retention_days)" = 3650 ]
  w "$BATS_TEST_TMPDIR/proj/.claude/settings.json" '{"cleanupPeriodDays":10}'
  [ "$(cs_claude_retention_days "$BATS_TEST_TMPDIR/proj")" = 10 ]
  w "$BATS_TEST_TMPDIR/proj/.claude/settings.local.json" '{"cleanupPeriodDays":0}'
  [ "$(cs_claude_retention_days "$BATS_TEST_TMPDIR/proj")" = 0 ]
}

@test "settings set: backup, other keys kept, no CR, bad input refused" {
  cs_store_dirs() { mkdir -p "$CLAUDE_SYNC_HOME/backups"; }
  cs_store_dirs
  w "$CS_CLAUDE_DIR/settings.json" '{"model":"opus","hooks":{"x":1}}'
  cs_claude_settings_set cleanupPeriodDays 3650
  [ "$(jq -r .cleanupPeriodDays "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" = 3650 ]
  [ "$(jq -r .model "$CS_CLAUDE_DIR/settings.json" | tr -d '\r')" = opus ]
  [ "$(tr -cd '\r' <"$CS_CLAUDE_DIR/settings.json" | wc -c)" -eq 0 ]
  [ "$(ls "$CLAUDE_SYNC_HOME/backups" | grep -c '^settings.json\.')" -eq 1 ]
  run cs_claude_settings_set x 'not json'
  [ "$status" -eq 1 ]
  printf '[1,2]' >"$CS_CLAUDE_DIR/settings.json"
  run cs_claude_settings_set x 1
  [ "$status" -eq 1 ]
  [ "$(cat "$CS_CLAUDE_DIR/settings.json")" = '[1,2]' ]
}

# --- never sync (SPEC §4.3) ----------------------------------------------------------------------

@test "never-sync list blocks registry, credentials, caches and Claude temp files" {
  for p in sessions/123.json sessions/123.abc.key session-env/s/x shell-snapshots/a ide/1.lock cache/x state/y \
    backups/z .credentials.json .claude.json .last-cleanup projects/P/.session-aliases \
    projects/P/memory/team/a.md projects/P/memory/.memory-sync.json memory/personal/a.md \
    projects/P/s.ccr-tip.json projects/P/s.precompact.json projects/P/s.jsonl.compact.tmp.1 \
    projects/P/s.jsonl.superseded-17 projects/P/s.jsonl.orphaned-1 projects/P/s.jsonl.csync-tmp \
    ../etc/passwd /etc/passwd projects/../../x; do
    cs_claude_never_sync "$p" || { echo "should be blocked: $p"; return 1; }
  done
}

@test "never-sync list lets session data, memory and plans through" {
  for p in projects/P/s.jsonl projects/P/s/subagents/agent-1.jsonl projects/P/s/tool-results/x.txt \
    projects/P/s.cast projects/P/memory/MEMORY.md file-history/s/abc@v1 plans/foo.md tasks/s/1.json uploads/s/a.png; do
    ! cs_claude_never_sync "$p" || { echo "should pass: $p"; return 1; }
  done
}

# --- report and CLI ------------------------------------------------------------------------------

@test "projects report: one row per dir with count, bytes and newest session's launch cwd" {
  make_tree
  touch -d @1790000000 "$P/D--Projects-X/s2.jsonl"
  touch -d @1790000100 "$P/D--Projects-X/s1.jsonl"
  run cs_claude_projects_report
  [ "${#lines[@]}" -eq 3 ]
  printf '%s\n' "$output" | grep -q "$(printf '^D--Projects-X\t2\t')"
  printf '%s\n' "$output" | grep -q "$(printf '^-home-u-y\t1\t[0-9]*\t/home/u/y$')"
}

@test "doctor flags junk dirs and duplicate ids with exit 1; clean tree exits 0" {
  make_tree
  run cli doctor
  [ "$status" -eq 1 ]
  [[ $output == *"projects/D--Projects-X.bak-20260925"* ]]
  [[ $output == *"2 session ids exist in more than one project dir"* ]]
  rm -rf "$P/D--Projects-X.bak-20260925"
  run cli doctor
  [ "$status" -eq 0 ]
  [[ $output == *"3 sessions in 2 project dirs"* ]]
}

@test "projects list prints a table" {
  make_tree
  run cli projects dirs
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == SESSIONS* ]]
  [[ $output == *"/home/u/y"* ]]
}
