#!/usr/bin/env bats
# status.json, exit codes, log and offline gate (ticket #24) on simulated machines.

load test_helper
load sim_helper

SID=0b7a1c2e-1111-4222-8333-444455556666

setup() {
  cs_test_setup
  cs_load platform version
  sim_init
  BROOT="$SIM/B/work/X"
  sim_machine A w 'D:\Projects\X'
  sim_machine B p "$BROOT"
  ASLUG=D--Projects-X
  BSLUG=$(cc_slug "$BROOT")
}

uline() { printf '{"type":"user","uuid":"u-%s","cwd":"D:\\\\Projects\\\\X","t":"%s"}' "$1" "${2:-hello}"; }

state_of() { jq -r .state "$SIM/$1/home/.claude-sync/state/status.json" | tr -d '\r'; }

@test "OK: exit 0, status.json has the state and the last run times" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  run sim_run A
  [ "$status" -eq 0 ]
  [ "$(state_of A)" = OK ]
  j="$SIM/A/home/.claude-sync/state/status.json"
  [ -n "$(jq -r .last_run "$j" | tr -d '\r')" ]
  [ -n "$(jq -r .last_ok_pull "$j" | tr -d '\r')" ]
  [ -n "$(jq -r .last_ok_push "$j" | tr -d '\r')" ]
  run sim_cli A status --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output" | tr -d '\r')" = OK ]
  run sim_cli A status
  [[ $output == *'State: OK'* ]]
}

@test "LOGIN_REQUIRED: exit 3 and nothing is changed" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  sim_exec A 'cs_lfs_inject server_time 3 1'
  run sim_run A
  [ "$status" -eq 3 ]
  [ "$(state_of A)" = LOGIN_REQUIRED ]
  run sim_run A
  [ "$status" -eq 0 ]
  [[ $output == *'1 published'* ]]
}

@test "OFFLINE: exit 4 when the network is down at the start" {
  sim_exec A 'cs_lfs_inject server_time 6 1'
  run sim_run A
  [ "$status" -eq 4 ]
  [ "$(state_of A)" = OFFLINE ]
}

@test "ROOT_MISSING: the root folder in the trash stops the run (exit 1)" {
  sim_exec A 'drv_trash "$1"' "$SIM_ROOT_ID"
  run sim_run A
  [ "$status" -eq 1 ]
  [ "$(state_of A)" = ROOT_MISSING ]
}

@test "NEEDS_REPAIR: a session that needs repair gives exit 6 after a complete run" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  sim_exec B 'cs_eng_row_set "$1" p1 "$2" 0 0 0 - x needs_repair' "$SID" "$BSLUG"
  run sim_run B
  [ "$status" -eq 6 ]
  [ "$(state_of B)" = NEEDS_REPAIR ]
}

@test "ERROR: a failed publish gives exit 1; the next run repairs it" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  sim_exec A 'cs_lfs_inject upload 7 1'
  run sim_run A
  [ "$status" -eq 1 ]
  [ "$(state_of A)" = ERROR ]
  run sim_run A
  [ "$status" -eq 0 ]
  [ "$(state_of A)" = OK ]
}

@test "A7: the network drops in the middle of a cycle: OFFLINE, no damage, the next cycle completes" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)" "$(uline 2)"
  sim_exec A 'cs_lfs_inject upload 6 1'
  run sim_run A
  [ "$status" -eq 4 ]
  [ "$(state_of A)" = OFFLINE ]
  run sim_run B
  [[ $output == *'0 installed'* ]]
  run sim_run A
  [ "$status" -eq 0 ]
  run sim_run B
  [[ $output == *'1 installed'* ]]
  [ "$(wc -l <"$(sim_find B "$SID")")" -eq 2 ]
}

@test "a forked session appears in status.json conflicts" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  sim_run A >/dev/null
  sim_write B "$BSLUG" "$SID" '{"type":"user","uuid":"u-x","cwd":"'"$BROOT"'","t":"other"}'
  sim_run B >/dev/null
  [ "$(jq -r '.conflicts[0]' "$SIM/B/home/.claude-sync/state/status.json" | tr -d '\r')" = "$SID" ]
}

@test "the log has no token and no transcript text" {
  sim_write A "$ASLUG" "$SID" "$(uline 1 'SECRET-TRANSCRIPT-TEXT')"
  printf 'ya29.FAKE-ACCESS-TOKEN-1234\n' >"$SIM/A/home/.claude-sync/token.enc"
  sim_run A >/dev/null
  sim_run B >/dev/null
  run grep -rE 'SECRET-TRANSCRIPT-TEXT|FAKE-ACCESS-TOKEN' "$SIM/A/home/.claude-sync/logs" "$SIM/B/home/.claude-sync/logs"
  [ "$status" -eq 1 ]
  [ -s "$SIM/A/home/.claude-sync/logs/claude-sync.log" ]
}

@test "log rotation keeps 5 files" {
  l="$SIM/A/home/.claude-sync/logs/claude-sync.log"
  for i in 1 2 3 4 5 6 7; do
    head -c 600 /dev/zero | tr '\0' x >"$l"
    sim_exec A 'CS_LOG_MAX_BYTES=100 cs_log_rotate'
  done
  [ ! -s "$l" ] || [ ! -e "$l" ]
  ls "$SIM/A/home/.claude-sync/logs"
  [ -f "$l.1" ] && [ -f "$l.4" ] && [ ! -e "$l.5" ]
}

@test "offline gate: no network within the budget -> rc 1; a reachable probe -> rc 0" {
  run sim_exec A 'CS_DRIVE_BACKEND=gdrive CS_PROBE_URL=http://127.0.0.1:9/x CS_OFFLINE_BUDGET=1 CS_OFFLINE_DELAY0=1 cs_eng_online_gate'
  [ "$status" -eq 1 ]
  run sim_exec A 'CS_DRIVE_BACKEND=gdrive; nat() { echo 204; }; cs_eng_online_gate'
  [ "$status" -eq 0 ]
}
