#!/usr/bin/env bats
# Open sessions, throttle, live.json (ticket #19).

load test_helper
load sim_helper

SID=0b7a1c2e-1111-4222-8333-444455556666

setup() {
  cs_test_setup
  cs_load platform version
  sim_init
  SIM_SLEEP_PIDS=()
  BROOT="$SIM/B/work/X"
  sim_machine A w 'D:\Projects\X'
  sim_machine B p "$BROOT"
  ASLUG=D--Projects-X
  BSLUG=$(cc_slug "$BROOT")
}

teardown() { kill "${SIM_SLEEP_PIDS[@]}" 2>/dev/null || true; }

uline() { printf '{"type":"user","uuid":"u-%s","cwd":"D:\\\\Projects\\\\X"}' "$1"; }
bline() { printf '{"type":"user","uuid":"u-%s","cwd":"%s"}' "$1" "$BROOT"; }
sj() { jq -c "$2" "$SIM/$1/home/.claude-sync/state/status.json" | tr -d '\r'; }

@test "H3: a session open on B is not replaced while A writes on; closing it lets the next cycle install" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  sim_open B "$SID"
  sim_write A "$ASLUG" "$SID" "$(uline 2)" "$(uline 3)"
  sim_run A >/dev/null
  run sim_run B
  [[ $output == *'0 installed'* ]]
  [ "$(wc -l <"$(sim_find B "$SID")")" -eq 1 ]
  [ "$(sj B ".behind[\"$SID\"].lines")" = 2 ]
  [ "$(sj B ".behind[\"$SID\"].machine")" = '"A"' ]
  [ "$(sim_exec B 'cs_tsv_field sessions status "$1"' "$SID")" = behind ]
  sim_close B "$SID"
  run sim_run B
  [[ $output == *'1 installed'* ]]
  [ "$(wc -l <"$(sim_find B "$SID")")" -eq 3 ]
  [ "$(sj B '.behind | length')" = 0 ]
}

@test "an open session publishes appends at most once per throttle_live_min; closing it publishes at once" {
  sim_write B "$BSLUG" "$SID" "$(bline 1)"
  sim_open B "$SID"
  run sim_run B
  [[ $output == *'0 installed, 1 published'* ]]
  sim_write B "$BSLUG" "$SID" "$(bline 2)"
  run sim_run B
  [[ $output == *'0 installed, 0 published'* ]]
  sim_close B "$SID"
  run sim_run B
  [[ $output == *'0 installed, 1 published'* ]]
}

@test "throttle_live_min=0 publishes every cycle while open (M8: only the tail is uploaded)" {
  sim_exec B 'cs_config_set throttle_live_min 0'
  sim_write B "$BSLUG" "$SID" "$(bline 1)" "$(bline 2)" "$(bline 3)"
  sim_open B "$SID"
  sim_run B >/dev/null
  segs() { grep -l '"csKind":"seg"' "$SIM"/drive/objects/*/meta.json | wc -l; }
  n=$(segs)
  sim_write B "$BSLUG" "$SID" "$(bline 4)"
  run sim_run B
  [[ $output == *'0 installed, 1 published'* ]]
  [ "$(segs)" -eq $((n + 1)) ]
  [ "$(jq -r '.sessions[].segs | length' "$SIM/B/home/.claude-sync/state/manifest.json" | tr -d '\r')" = 2 ]
  [ "$(jq -r '.sessions[].segs[1].len' "$SIM/B/home/.claude-sync/state/manifest.json" | tr -d '\r')" -lt "$(jq -r '.sessions[].segs[0].len' "$SIM/B/home/.claude-sync/state/manifest.json" | tr -d '\r')" ]
}

@test "H4: a session rewritten while open is not published until it is closed" {
  sim_write B "$BSLUG" "$SID" "$(bline 1)" "$(bline 2)" "$(bline 3)"
  sim_run B >/dev/null
  sim_open B "$SID"
  printf '%s
' "$(bline 1)" >"$(sim_find B "$SID")"
  run sim_run B
  [[ $output == *'0 installed, 0 published'* ]]
  sim_close B "$SID"
  run sim_run B
  [[ $output == *'0 installed, 1 published'* ]]
}

@test "live.json: other machines see the open session; it disappears when closed; stale files are ignored (F8)" {
  sim_write B "$BSLUG" "$SID" "$(bline 1)"
  sim_open B "$SID"
  sim_run B >/dev/null
  [ "$(grep -l '"csKind":"live"' "$SIM"/drive/objects/*/meta.json | wc -l)" -eq 1 ]
  sim_run A >/dev/null
  [ "$(sj A ".live_elsewhere[\"$SID\"].machine")" = '"B"' ]
  CS_LFS_NOW=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%S.000Z) sim_run A >/dev/null
  [ "$(sj A '.live_elsewhere | length')" = 0 ]
  sim_close B "$SID"
  sim_run B >/dev/null
  sim_run A >/dev/null
  [ "$(sj A '.live_elsewhere | length')" = 0 ]
}
