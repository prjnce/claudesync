#!/usr/bin/env bats
# GC and the machines command (ticket #23).

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

uline() { printf '{"type":"user","uuid":"u-%s","cwd":"D:\\\\Projects\\\\X"}' "$1"; }

# stray MACHINE DAYS: an object in the machine's area that no manifest knows, created DAYS days ago.
stray() {
  sim_exec "$1" 'echo junk >"$CS_HOME/staging/stray.txt"; CS_LFS_NOW=$(date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%S.000Z) drv_upload "$(cs_drive_state_get machine_folder_id)" "$2" "$CS_HOME/staging/stray.txt" "{\"csKind\":\"seg\",\"csSha\":\"x\"}" >/dev/null' "$2" "$3"
}

trashed() { jq -r --arg n "$1" 'select(.name == $n) | .trashed' "$SIM"/drive/objects/*/meta.json | tr -d '\r'; }

@test "GC: an old unreferenced object goes to the trash; referenced and recent objects stay" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)" "$(uline 2)"
  sim_run A >/dev/null
  stray A 3 old-orphan
  stray A 0 young-orphan
  CS_GC_INTERVAL=0 sim_run A >/dev/null
  [ "$(trashed old-orphan)" = true ]
  [ "$(trashed young-orphan)" = false ]
  [ "$(jq -r 'select(.appProperties.csKind == "seg") | select(.name | startswith("t-")) | .trashed' "$SIM"/drive/objects/*/meta.json | tr -d '\r' | sort -u)" = false ]
  [ "$(trashed manifest.json.gz)" = false ]
  sim_run B >/dev/null
  [ -n "$(sim_find B "$SID")" ]
}

@test "GC runs at most once a day" {
  sim_run A >/dev/null
  stray A 3 first-orphan
  CS_GC_INTERVAL=0 sim_run A >/dev/null
  [ "$(trashed first-orphan)" = true ]
  stray A 3 second-orphan
  sim_run A >/dev/null
  [ "$(trashed second-orphan)" = false ]
}

@test "GC leaves objects that another machine's manifest still references" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  printf '%s
' "$(uline 2)" >>"$SIM/A/claude/projects/$ASLUG/$SID.jsonl"
  sim_run A >/dev/null
  CS_GC_MIN_AGE=0 CS_GC_INTERVAL=0 sim_run B >/dev/null
  CS_GC_MIN_AGE=0 CS_GC_INTERVAL=0 sim_run A >/dev/null
  [ "$(jq -r 'select(.name | startswith("t-")) | .trashed' "$SIM"/drive/objects/*/meta.json | tr -d '\r' | sort -u)" = false ]
}

@test "M6a: an object that vanished while B was downloading is not an error; the next cycle converges" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  sim_run A >/dev/null
  sim_exec B 'cs_lfs_inject download 4 1'
  run sim_run B
  [ "$status" -eq 0 ]
  [[ $output == *'0 installed'* ]]
  run sim_run B
  [[ $output == *'1 installed'* ]]
}

@test "machines list shows the machines; forget keeps the only copy of a version (F12)" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)" "$(uline 2)"
  sim_run A >/dev/null
  run sim_cli B machines list
  [ "$status" -eq 0 ]
  [[ $output == *'A (windows'* || $output == *'A ('* ]]
  run sim_cli B machines forget A --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *'1 version'* ]]
  [ "$(jq -r '.archive | to_entries[0].value | keys[0]' "$SIM/B/home/.claude-sync/state/manifest.json" | tr -d '\r')" = "$SID" ]
  [ "$(jq -r 'select(.name | startswith("arch-")) | .trashed' "$SIM"/drive/objects/*/meta.json | tr -d '\r' | sort -u)" = false ]
  [ "$(jq -r 'select(.appProperties.csMachine == "A-0000-4000-8000-000000000000" and .mimeType == "application/vnd.google-apps.folder") | .trashed' "$SIM"/drive/objects/*/meta.json | tr -d '\r')" = true ]
  run sim_cli B machines forget B --yes
  [ "$status" -ne 0 ]
}

@test "the code never empties the Drive trash" {
  ! grep -rniE 'emptytrash|empty_trash|trash/empty' "$CS_ROOT/lib" "$CS_ROOT/bin"
}

@test "machines table shows - for an empty updated field instead of shifting the columns" {
  cs_load platform store gc
  mkdir -p "$CS_HOME/state/remote"
  printf '{"machine_id":"m1","name":"N","os":"windows","updated":"","sessions":{"a":{}}}
' >"$CS_HOME/state/manifest.json"
  run cs_machines_table
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'm1	N	windows	-	1')" ]
}
