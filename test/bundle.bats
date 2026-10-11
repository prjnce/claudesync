#!/usr/bin/env bats
# Bundle files, subagent transcripts, file-history (ticket #21).

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
  ACC="$SIM/A/claude"
  BCC="$SIM/B/claude"
}

uline() { printf '{"type":"user","uuid":"u-%s","cwd":"D:\\\\Projects\\\\X"}' "$1"; }
aglin() { printf '{"type":"user","uuid":"g-%s","cwd":"D:\\\\Projects\\\\X\\\\apps"}' "$1"; }

# a_fixture: the session on A with a subagent, tool results, a cast, file-history and files that must never travel.
a_fixture() {
  sim_write A "$ASLUG" "$SID" "$(uline 1)" "$(uline 2)"
  local d="$ACC/projects/$ASLUG/$SID"
  mkdir -p "$d/subagents" "$d/tool-results" "$ACC/file-history/$SID"
  printf '%s
' "$(aglin 1)" "$(aglin 2)" >"$d/subagents/agent-a1.jsonl"
  printf '{"agentType":"x"}
' >"$d/subagents/agent-a1.meta.json"
  printf 'result one
' >"$d/tool-results/t1.txt"
  printf 'cast
' >"$ACC/projects/$ASLUG/$SID.cast"
  printf 'echo hi
' >"$ACC/file-history/$SID/abcd1234abcd1234@v1"
  chmod 755 "$ACC/file-history/$SID/abcd1234abcd1234@v1"
  printf 'x
' >"$d/notes.superseded-2"
  printf 'x
' >"$d/tool-results/a.compact.tmp.1"
  printf 'x
' >"$ACC/projects/$ASLUG/$SID.ccr-tip.json"
}

@test "A1: subagent transcript, tool results, cast and file-history from A are all there on B (path translated, mode kept)" {
  a_fixture
  sim_run A >/dev/null
  run sim_run B
  echo "$output"
  [[ $output == *'1 installed'* ]]
  d="$BCC/projects/$BSLUG/$SID"
  [ "$(cat "$d/tool-results/t1.txt")" = 'result one' ]
  [ -f "$d/subagents/agent-a1.meta.json" ]
  [ "$(wc -l <"$d/subagents/agent-a1.jsonl")" -eq 2 ]
  grep -qF "\"cwd\":\"$BROOT/apps\"" "$d/subagents/agent-a1.jsonl"
  [ "$(cat "$BCC/projects/$BSLUG/$SID.cast")" = cast ]
  [ "$(stat -c %a "$BCC/file-history/$SID/abcd1234abcd1234@v1")" = "$(stat -c %a "$ACC/file-history/$SID/abcd1234abcd1234@v1")" ]
  for m in A B A B; do
    run sim_run "$m"
    [[ $output == *'0 installed, 0 published'* ]] || { echo "$m: $output"; return 1; }
  done
}

@test "files of the never-sync list are not uploaded" {
  a_fixture
  sim_run A >/dev/null
  names=$(jq -r 'select(.appProperties.csKind == "file") | .name' "$SIM"/drive/objects/*/meta.json | tr -d '\r')
  echo "$names"
  [ "$(printf '%s
' "$names" | grep -c .)" -eq 4 ]
  ! printf '%s
' "$names" | grep -qE 'superseded|compact|ccr-tip'
  [ ! -e "$BCC/projects/$BSLUG/$SID.ccr-tip.json" ]
}

@test "M7: a tool result that Claude on B cleaned up is not downloaded again; a new version of it is" {
  a_fixture
  sim_run A >/dev/null
  sim_run B >/dev/null
  rm "$BCC/projects/$BSLUG/$SID/tool-results/t1.txt"
  for m in B A B; do sim_run "$m" >/dev/null; done
  [ ! -e "$BCC/projects/$BSLUG/$SID/tool-results/t1.txt" ]
  printf 'result two
' >"$ACC/projects/$ASLUG/$SID/tool-results/t1.txt"
  sim_run A >/dev/null
  sim_run B >/dev/null
  [ "$(cat "$BCC/projects/$BSLUG/$SID/tool-results/t1.txt")" = 'result two' ]
  for m in A B A B; do
    run sim_run "$m"
    [[ $output == *'0 installed, 0 published'* ]] || { echo "$m: $output"; return 1; }
  done
}

@test "a crash after the bundle was unpacked and before the transcript was renamed is finished by the next run" {
  a_fixture
  sim_run A >/dev/null
  CS_TEST_CRASH_AFTER_BUNDLE=1 run sim_run B
  [ "$status" -eq 99 ]
  [ -z "$(sim_find B "$SID")" ]
  [ -f "$BCC/projects/$BSLUG/$SID/tool-results/t1.txt" ]
  run sim_run B
  [[ $output == *'1 installed'* ]]
  [ "$(wc -l <"$(sim_find B "$SID")")" -eq 2 ]
}

@test "subagent transcripts travel as appends in both directions" {
  a_fixture
  sim_run A >/dev/null
  sim_run B >/dev/null
  printf '%s
' "$(aglin 3)" >>"$ACC/projects/$ASLUG/$SID/subagents/agent-a1.jsonl"
  sim_run A >/dev/null
  sim_run B >/dev/null
  fb="$BCC/projects/$BSLUG/$SID/subagents/agent-a1.jsonl"
  [ "$(wc -l <"$fb")" -eq 3 ]
  printf '{"type":"user","uuid":"g-4","cwd":"%s"}
' "$BROOT" >>"$fb"
  sim_run B >/dev/null
  sim_run A >/dev/null
  [ "$(wc -l <"$ACC/projects/$ASLUG/$SID/subagents/agent-a1.jsonl")" -eq 4 ]
  for m in A B A B; do
    run sim_run "$m"
    [[ $output == *'0 installed, 0 published'* ]] || { echo "$m: $output"; return 1; }
  done
}
