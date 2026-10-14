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

# pack_members: every file name inside every pack object of the Drive
pack_members() {
  local m d
  for m in $(grep -l '"csKind":"pack"' "$SIM"/drive/objects/*/meta.json); do
    d=$(dirname "$m")
    tar -tzf "$d/content"
  done
}
kinds() { jq -r --arg k "$1" 'select(.appProperties.csKind == $k) | .name' "$SIM"/drive/objects/*/meta.json | tr -d '\r' | grep -c . || true; }

@test "files of the never-sync list are not uploaded" {
  a_fixture
  sim_run A >/dev/null
  members=$(pack_members)
  echo "$members"
  [ "$(printf '%s\n' "$members" | grep -c .)" -eq 4 ]
  ! printf '%s\n' "$members" | grep -qE 'superseded|compact|ccr-tip'
  [ ! -e "$BCC/projects/$BSLUG/$SID.ccr-tip.json" ]
}

@test "many small files travel in one pack: one object, one download on the other machine, contents and modes intact" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  mkdir -p "$ACC/file-history/$SID" "$ACC/projects/$ASLUG/$SID/tool-results"
  for i in $(seq 1 30); do printf 'content %s\n' "$i" >"$ACC/file-history/$SID/h$i@v1"; done
  printf '#!/bin/sh\n' >"$ACC/projects/$ASLUG/$SID/tool-results/run.sh"
  chmod 755 "$ACC/projects/$ASLUG/$SID/tool-results/run.sh"
  sim_run A >/dev/null
  [ "$(kinds pack)" -eq 1 ]
  [ "$(kinds file)" -eq 0 ]
  [ "$(pack_members | grep -c .)" -eq 31 ]
  [ "$(jq -r '.sessions[].files | length' "$SIM/A/home/.claude-sync/state/manifest.json" | tr -d '\r')" -eq 31 ]
  sim_run B >/dev/null
  for i in 1 15 30; do [ "$(cat "$BCC/file-history/$SID/h$i@v1")" = "content $i" ]; done
  [ "$(stat -c %a "$BCC/projects/$BSLUG/$SID/tool-results/run.sh")" = "$(stat -c %a "$ACC/projects/$ASLUG/$SID/tool-results/run.sh")" ]
  for m in A B A B; do
    run sim_run "$m"
    [[ $output == *'0 installed, 0 published'* ]] || { echo "$m: $output"; return 1; }
  done
  [ "$(kinds pack)" -eq 1 ]
}

@test "a changed file in a pack goes up on its own and replaces the old one on the other machine" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  mkdir -p "$ACC/file-history/$SID"
  for i in 1 2 3; do printf 'v1 %s\n' "$i" >"$ACC/file-history/$SID/h$i@v1"; done
  sim_run A >/dev/null
  sim_run B >/dev/null
  printf 'v2 2\n' >"$ACC/file-history/$SID/h2@v1"
  sim_run A >/dev/null
  [ "$(kinds file)" -eq 1 ]
  sim_run B >/dev/null
  [ "$(cat "$BCC/file-history/$SID/h2@v1")" = 'v2 2' ]
  [ "$(cat "$BCC/file-history/$SID/h3@v1")" = 'v1 3' ]
}

@test "files above the pack size limit are uploaded one by one, small ones still packed" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  mkdir -p "$ACC/file-history/$SID"
  head -c 2000 /dev/zero | tr '\0' b >"$ACC/file-history/$SID/big@v1"
  for i in 1 2 3; do printf 's%s\n' "$i" >"$ACC/file-history/$SID/s$i@v1"; done
  CS_PACK_FILE_MAX=100 sim_run A >/dev/null
  [ "$(kinds file)" -eq 1 ]
  [ "$(kinds pack)" -eq 1 ]
  sim_run B >/dev/null
  [ "$(wc -c <"$BCC/file-history/$SID/big@v1" | tr -d ' ')" -eq 2000 ]
  [ "$(cat "$BCC/file-history/$SID/s2@v1")" = s2 ]
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

# --- a subagent transcript that both machines already have and that has no base yet (SPEC §12.2 for subagents) ---

# b_main: the same main transcript as a_fixture, already on B (cwd in B's folder).
b_main() {
  sim_write B "$BSLUG" "$SID" "$(printf '{"type":"user","uuid":"u-1","cwd":"%s"}' "$BROOT")" "$(printf '{"type":"user","uuid":"u-2","cwd":"%s"}' "$BROOT")"
}
# b_agent N...: B's own subagent transcript with the given lines (cwd in B's folder)
b_agent() {
  local d="$BCC/projects/$BSLUG/$SID/subagents" n
  mkdir -p "$d"
  : >"$d/agent-a1.jsonl"
  for n in "$@"; do printf '{"type":"user","uuid":"g-%s","cwd":"%s/apps"}\n' "$n" "$BROOT" >>"$d/agent-a1.jsonl"; done
}
blog() { cat "$SIM/B/home/.claude-sync/logs/claude-sync.log"; }
settled() {
  local m
  for m in A B A B; do
    run sim_run "$m"
    [[ $output == *'0 installed, 0 published'* ]] || { echo "$m: $output"; return 1; }
  done
}

@test "subagent without a base: an identical copy on both machines adopts the base, later appends flow both ways" {
  a_fixture
  sim_run A >/dev/null
  b_main
  b_agent 1 2
  sim_run B >/dev/null
  if blog | grep -q 'deferred'; then return 1; fi
  settled
  printf '{"type":"user","uuid":"g-3","cwd":"%s/apps"}\n' "$BROOT" >>"$BCC/projects/$BSLUG/$SID/subagents/agent-a1.jsonl"
  sim_run B >/dev/null
  sim_run A >/dev/null
  [ "$(wc -l <"$ACC/projects/$ASLUG/$SID/subagents/agent-a1.jsonl")" -eq 3 ]
  settled
}

@test "subagent without a base: a local copy longer than the remote one publishes only its tail" {
  a_fixture
  sim_run A >/dev/null
  b_main
  b_agent 1 2 3
  sim_run B >/dev/null
  if blog | grep -q 'deferred'; then return 1; fi
  sim_run A >/dev/null
  [ "$(wc -l <"$ACC/projects/$ASLUG/$SID/subagents/agent-a1.jsonl")" -eq 3 ]
  grep -qF 'g-3' "$ACC/projects/$ASLUG/$SID/subagents/agent-a1.jsonl"
  settled
}

@test "subagent without a base: a local copy that is a prefix of the remote one is brought up to date" {
  a_fixture
  sim_run A >/dev/null
  b_main
  b_agent 1
  sim_run B >/dev/null
  if blog | grep -q 'deferred'; then return 1; fi
  fb="$BCC/projects/$BSLUG/$SID/subagents/agent-a1.jsonl"
  [ "$(wc -l <"$fb")" -eq 2 ]
  grep -qF "\"cwd\":\"$BROOT/apps\"" "$fb"
  settled
}

@test "subagent without a base: unrelated content on both machines is left alone and reported" {
  a_fixture
  sim_run A >/dev/null
  b_main
  b_agent 7 8
  before=$(cat "$BCC/projects/$BSLUG/$SID/subagents/agent-a1.jsonl")
  sim_run B >/dev/null
  sim_run B >/dev/null
  blog | grep -q 'agent-a1 of .* differs from .* deferred'
  [ "$(cat "$BCC/projects/$BSLUG/$SID/subagents/agent-a1.jsonl")" = "$before" ]
  [ "$(wc -l <"$ACC/projects/$ASLUG/$SID/subagents/agent-a1.jsonl")" -eq 2 ]
  grep -qF 'g-1' "$ACC/projects/$ASLUG/$SID/subagents/agent-a1.jsonl"
}
