#!/usr/bin/env bats
# `claude-sync reset`: forget the local sync bookkeeping so that the next run uploads everything again.

load test_helper
load sim_helper
bats_require_minimum_version 1.5.0

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
  AH="$SIM/A/home/.claude-sync"
}

uline() { printf '{"type":"user","uuid":"u-%s","cwd":"D:\\\\Projects\\\\X"}' "$1"; }

manifests_of_a() {
  grep -l '"csKind":"manifest"' "$SIM"/drive/objects/*/meta.json | xargs grep -l 'A-0000-4000-8000-000000000000' | wc -l
}

@test "reset clears the sync bookkeeping and keeps config, login data and projects; Drive is untouched" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)" "$(uline 2)"
  sim_run A >/dev/null
  objects=$(find "$SIM/drive/objects" -name meta.json | wc -l)
  [ -f "$AH/state/manifest.json" ]
  [ -n "$(ls "$AH/state/entries")" ]
  grep -q . "$AH/state/sessions.tsv"
  run sim_cli A reset --yes
  [ "$status" -eq 0 ]
  [[ $output == *'Local sync state cleared'* ]]
  [ ! -e "$AH/state/manifest.json" ]
  [ -z "$(ls "$AH/state/entries")" ]
  [ ! -s "$AH/state/sessions.tsv" ] || [ "$(grep -vc '^#' "$AH/state/sessions.tsv")" -eq 0 ]
  grep -q '^machine_id=' "$AH/config"
  grep -q 'p1' "$AH/state/projects.tsv"
  [ "$(jq -r '.machine_folder_id // "none"' "$AH/state/drive.json" | tr -d '\r')" = none ]
  [ "$(jq -r '.manifest_id // "none"' "$AH/state/drive.json" | tr -d '\r')" = none ]
  [ "$(jq -r '.root_id' "$AH/state/drive.json" | tr -d '\r')" != null ]
  [ "$(find "$SIM/drive/objects" -name meta.json | wc -l)" -eq "$objects" ]
  [ -f "$SIM/A/claude/projects/$ASLUG/$SID.jsonl" ]
}

@test "after a reset the next run uploads everything again and reuses the manifest object (never a second one)" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)" "$(uline 2)"
  sim_run A >/dev/null
  [ "$(manifests_of_a)" -eq 1 ]
  sim_cli A reset --yes >/dev/null
  run sim_run A
  [ "$status" -eq 0 ]
  [[ $output == *'1 published'* ]]
  [ "$(manifests_of_a)" -eq 1 ]
  run sim_run B
  [[ $output == *'1 installed'* ]]
  [ "$(sim_canon B "$(sim_find B "$SID")")" = "$(sim_canon A "$SIM/A/claude/projects/$ASLUG/$SID.jsonl")" ]
  sim_write A "$ASLUG" "$SID" "$(uline 3)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  [ "$(wc -l <"$(sim_find B "$SID")")" -eq 3 ]
  for m in A B A B; do
    run sim_run "$m"
    [[ $output == *'0 installed, 0 published'* ]] || { echo "$m: $output"; return 1; }
  done
}

@test "after a reset, sessions that another machine already has on Drive are recognised, not uploaded twice" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)" "$(uline 2)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  objects=$(find "$SIM/drive/objects" -name meta.json | wc -l)
  sim_cli A reset --yes >/dev/null
  run sim_run A
  [ "$status" -eq 0 ]
  [[ $output == *'0 published'* ]]
  [ "$(manifests_of_a)" -eq 1 ]
  [ "$(sim_canon B "$(sim_find B "$SID")")" = "$(sim_canon A "$SIM/A/claude/projects/$ASLUG/$SID.jsonl")" ]
  sim_write A "$ASLUG" "$SID" "$(uline 3)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  [ "$(wc -l <"$(sim_find B "$SID")")" -eq 3 ]
  for m in A B A B; do
    run sim_run "$m"
    [[ $output == *'0 installed, 0 published'* ]] || { echo "$m: $output"; return 1; }
  done
}

@test "reset asks first (no answer = no), and refuses while a sync is running" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  sim_run A >/dev/null
  run bash -c 'printf "n\n" | CLAUDE_SYNC_HOME="$1" CLAUDE_SYNC_LANG=en bash "$CS_ROOT/bin/claude-sync" reset' _ "$AH"
  [ "$status" -ne 0 ]
  [ -f "$AH/state/manifest.json" ]
  mapfile -t e < <(sim_env A)
  (env "${e[@]}" bash -c 'exec 9>>"$CLAUDE_SYNC_HOME/sync.lock"; source "$CS_ROOT/lib/core.sh"; cs_bootstrap; source "$CS_ROOT/lib/platform.sh"; cs_lock_fd 9 0 && sleep 8' 3>&- &)
  sleep 2
  run sim_cli A reset --yes
  [ "$status" -eq 5 ]
  [ -f "$AH/state/manifest.json" ]
}
