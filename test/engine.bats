#!/usr/bin/env bats
# Engine tracer (ticket #17): append-only sync between simulated machines over a shared localfs Drive.
# A is Windows-like (root D:\Projects\X), B is Linux (root is a real dir), C is Windows-like.

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

aline() { printf '{"type":"user","cwd":"D:\\\\Projects\\\\X%s","n":%s,"t":"xin chào %s"}' "${2:-}" "$1" "$1"; }

@test "A -> B: a new session appears on B in the right project dir with translated cwd and A's mtime" {
  sim_write A "$ASLUG" "$SID" "$(aline 1)" "$(aline 2 '\\apps')" "$(aline 3)"
  touch -d @1790000000 "$SIM/A/claude/projects/$ASLUG/$SID.jsonl"
  run sim_run A
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *'0 installed, 1 published'* ]]
  run sim_run B
  echo "$output"
  [[ $output == *'1 installed, 0 published'* ]]
  f="$SIM/B/claude/projects/$BSLUG/$SID.jsonl"
  [ -f "$f" ]
  [ "$(wc -l <"$f")" -eq 3 ]
  grep -qF "\"cwd\":\"$BROOT\"" "$f"
  grep -qF "\"cwd\":\"$BROOT/apps\"" "$f"
  [ "$(stat -c %Y "$f")" = 1790000000 ]
  [ "$(sim_canon B "$f")" = "$(sim_canon A "$SIM/A/claude/projects/$ASLUG/$SID.jsonl")" ]
}

@test "appends travel both ways (A2) and only new segments are downloaded" {
  sim_write A "$ASLUG" "$SID" "$(aline 1)" "$(aline 2)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  sim_write A "$ASLUG" "$SID" "$(aline 3)"
  sim_run A >/dev/null
  run sim_run B
  [[ $output == *'1 installed'* ]]
  fb="$SIM/B/claude/projects/$BSLUG/$SID.jsonl"
  [ "$(wc -l <"$fb")" -eq 3 ]
  [ "$(ls "$SIM/B/home/.claude-sync/cache/segs" | wc -l)" -eq 2 ]
  printf '{"type":"assistant","cwd":"%s","n":4}\n' "$BROOT" >>"$fb"
  run sim_run B
  [[ $output == *'1 published'* ]]
  run sim_run A
  [[ $output == *'1 installed'* ]]
  fa="$SIM/A/claude/projects/$ASLUG/$SID.jsonl"
  [ "$(wc -l <"$fa")" -eq 4 ]
  [ "$(tail -n 1 "$fa")" = '{"type":"assistant","cwd":"D:\\Projects\\X","n":4}' ]
  [ "$(sim_canon A "$fa")" = "$(sim_canon B "$fb")" ]
}

@test "three machines taking turns converge without reinstall or republish loops (C1)" {
  sim_machine C w 'E:\Work\X'
  sim_write A "$ASLUG" "$SID" "$(aline 1)"
  for round in 1 2 3; do
    sim_run A >/dev/null
    sim_run B >/dev/null
    sim_run C >/dev/null
    fb=$(sim_find B "$SID")
    printf '{"type":"user","cwd":"%s","n":"b%s"}\n' "$BROOT" "$round" >>"$fb"
    sim_run B >/dev/null
    sim_run C >/dev/null
    sim_run A >/dev/null
  done
  # Quiet state: nobody installs or publishes anything any more.
  for m in A B C A B C; do
    run sim_run "$m"
    [[ $output == *'0 installed, 0 published'* ]] || { echo "$m: $output"; return 1; }
  done
  a=$(sim_canon A "$(sim_find A "$SID")")
  [ "$a" = "$(sim_canon B "$(sim_find B "$SID")")" ]
  [ "$a" = "$(sim_canon C "$(sim_find C "$SID")")" ]
  [ "$(wc -l <<<"$a")" -eq 4 ]
}

@test "placement: an existing slug dir that differs in case is reused (P1); a missing subdir maps to its nearest ancestor (P7)" {
  sim_machine C w 'D:\Projects\X'
  mkdir -p "$SIM/C/claude/projects/d--projects-x"
  sim_write A "$ASLUG" "$SID" "$(aline 1)"
  sim_run A >/dev/null
  sim_run C >/dev/null
  [ "$(sim_find C "$SID")" = "$SIM/C/claude/projects/d--projects-x/$SID.jsonl" ]
  # Launched in a subdirectory that exists only on A: B places it under its root.
  S2=0b7a1c2e-2222-4222-8333-444455556666
  sim_write A D--Projects-X-apps-tmp "$S2" "$(aline 1 '\\apps\\tmp')"
  sim_run A >/dev/null
  sim_run B >/dev/null
  [ "$(sim_find B "$S2")" = "$SIM/B/claude/projects/$BSLUG/$S2.jsonl" ]
  mkdir -p "$BROOT/apps"
  S3=0b7a1c2e-3333-4222-8333-444455556666
  sim_write A D--Projects-X-apps-tmp "$S3" "$(aline 1 '\\apps\\tmp')"
  sim_run A >/dev/null
  sim_run B >/dev/null
  [ "$(sim_find B "$S3")" = "$SIM/B/claude/projects/$(cc_slug "$BROOT/apps")/$S3.jsonl" ]
}

@test "a failed upload leaves nothing half done; the next run publishes once, without duplicate objects" {
  sim_write A "$ASLUG" "$SID" "$(aline 1)"
  sim_exec A 'cs_lfs_inject upload 7 1'
  run sim_run A
  [[ $output == *'0 published'* ]]
  run sim_run B
  [[ $output == *'0 installed'* ]]
  run sim_run A
  [[ $output == *'1 published'* ]]
  sim_run B >/dev/null
  [ "$(sim_find B "$SID" | wc -l)" -eq 1 ]
  [ "$(grep -l "\"csSid\":\"$SID\"" "$SIM"/drive/objects/*/meta.json | wc -l)" -eq 1 ]
}

@test "a second run while one holds the lock exits 5 (busy)" {
  (
    exec 9>>"$SIM/A/home/.claude-sync/sync.lock"
    cs_lock_fd 9 0
    sleep 3
  ) 3>&- &
  holder=$!
  sleep 0.7
  run sim_run A
  wait "$holder"
  [ "$status" -eq 5 ]
}

@test "every session id has exactly one file under projects/ on every machine (A5)" {
  sim_machine C w 'D:\Projects\X'
  for i in 1 2 3; do sim_write A "$ASLUG" "0b7a1c2e-000$i-4222-8333-444455556666" "$(aline "$i")"; done
  sim_run A >/dev/null
  sim_run B >/dev/null
  sim_run C >/dev/null
  sim_run B >/dev/null
  for m in A B C; do
    [ -z "$(find "$SIM/$m/claude/projects" -name '*.jsonl' -printf '%f\n' | sort | uniq -d)" ]
    [ "$(find "$SIM/$m/claude/projects" -name '*.jsonl' | wc -l)" -eq 3 ]
  done
}

@test "sessions of projects not mapped on the receiving machine are not installed" {
  sim_exec B 'cs_tsv_delete projects p1 "$1"' "$BROOT"
  sim_write A "$ASLUG" "$SID" "$(aline 1)"
  sim_run A >/dev/null
  run sim_run B
  [[ $output == *'0 installed'* ]]
  [ -z "$(sim_find B "$SID")" ]
}

@test "unmapped local sessions are never published" {
  sim_write A D--Elsewhere "$SID" '{"type":"user","cwd":"D:\\Elsewhere"}'
  run sim_run A
  [[ $output == *'0 published'* ]]
}

@test "dry run lists the plan and changes nothing" {
  sim_write A "$ASLUG" "$SID" "$(aline 1)"
  run sim_run A --dry-run
  [[ $output == *"publish $SID"* ]]
  [ -z "$(ls "$SIM/drive/objects" | head -n 1)" ] || [ "$(grep -l csSid "$SIM"/drive/objects/*/meta.json 2>/dev/null | wc -l)" -eq 0 ]
}

# --- ticket #18 slice 1: initialisation without a base (SPEC §12.2) ---------------------------------------

bline() { printf '{"type":"user","cwd":"%s%s","n":%s,"t":"xin chào %s"}' "$BROOT" "${2:-}" "$1" "$1"; }

@test "F2: B has no state but an older copy of the same session -> it is brought up to date, not forked or republished" {
  sim_write A "$ASLUG" "$SID" "$(aline 1)" "$(aline 2)" "$(aline 3)"
  sim_run A >/dev/null
  sim_write B "$BSLUG" "$SID" "$(bline 1)" "$(bline 2)"
  run sim_run B
  echo "$output"
  [[ $output == *'1 installed, 0 published'* ]]
  f=$(sim_find B "$SID")
  [ "$(sim_find B "$SID" | wc -l)" -eq 1 ]
  [ "$(wc -l <"$f")" -eq 3 ]
  [ "$(sim_canon B "$f")" = "$(sim_canon A "$SIM/A/claude/projects/$ASLUG/$SID.jsonl")" ]
  for m in A B A B; do
    run sim_run "$m"
    [[ $output == *'0 installed, 0 published'* ]] || { echo "$m: $output"; return 1; }
  done
}

@test "initialisation: an identical copy adopts the base silently, later appends flow as appends" {
  sim_write A "$ASLUG" "$SID" "$(aline 1)" "$(aline 2)"
  sim_run A >/dev/null
  sim_write B "$BSLUG" "$SID" "$(bline 1)" "$(bline 2)"
  run sim_run B
  [[ $output == *'0 installed, 0 published'* ]]
  sim_write A "$ASLUG" "$SID" "$(aline 3)"
  sim_run A >/dev/null
  run sim_run B
  [[ $output == *'1 installed, 0 published'* ]]
  [ "$(wc -l <"$(sim_find B "$SID")")" -eq 3 ]
}

@test "initialisation: a local copy longer than the remote one publishes only its tail" {
  sim_write A "$ASLUG" "$SID" "$(aline 1)" "$(aline 2)"
  sim_run A >/dev/null
  sim_write B "$BSLUG" "$SID" "$(bline 1)" "$(bline 2)" "$(bline 3)"
  run sim_run B
  [[ $output == *'0 installed, 1 published'* ]]
  run sim_run A
  [[ $output == *'1 installed, 0 published'* ]]
  [ "$(wc -l <"$SIM/A/claude/projects/$ASLUG/$SID.jsonl")" -eq 3 ]
  [ "$(sim_canon A "$SIM/A/claude/projects/$ASLUG/$SID.jsonl")" = "$(sim_canon B "$(sim_find B "$SID")")" ]
}

@test "initialisation: unrelated content under the same id is neither installed nor published" {
  sim_write A "$ASLUG" "$SID" "$(aline 1)" "$(aline 2)"
  sim_run A >/dev/null
  sim_write B "$BSLUG" "$SID" "$(bline 7)" "$(bline 8)"
  before=$(cat "$(sim_find B "$SID")")
  run sim_run B
  [[ $output == *'0 installed, 0 published'* ]]
  [ "$(cat "$(sim_find B "$SID")")" = "$before" ]
  [[ $(sim_exec B 'cs_tsv_get sessions "$1"' "$SID") == *conflict* ]]
}

# --- ticket #18 slice 2: rewrite and the decision table (SPEC §12.3, §12.6) -------------------------------

uline() { printf '{"type":"%s","uuid":"u-%s","cwd":"D:\\\\Projects\\\\X","n":%s}' "${2:-user}" "$1" "$1"; }

@test "a local rewrite publishes a new chain; the other machine replaces its copy; then everything is quiet" {
  fa="$SIM/A/claude/projects/$ASLUG/$SID.jsonl"
  sim_write A "$ASLUG" "$SID" "$(uline 1)" "$(uline 2)" "$(uline 3)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  printf '%s\n' "$(uline 1)" "$(uline 3)" "$(uline 4)" >"$fa"
  run sim_run A
  echo "$output"
  [[ $output == *'0 installed, 1 published'* ]]
  run sim_run B
  [[ $output == *'1 installed, 0 published'* ]]
  fb=$(sim_find B "$SID")
  [ "$(wc -l <"$fb")" -eq 3 ]
  ! grep -q '"n":2' "$fb"
  [ "$(sim_canon B "$fb")" = "$(sim_canon A "$fa")" ]
  for m in A B A B; do
    run sim_run "$m"
    [[ $output == *'0 installed, 0 published'* ]] || { echo "$m: $output"; return 1; }
  done
}

@test "only the mtime changed: the DB follows, nothing is published (F9)" {
  fa="$SIM/A/claude/projects/$ASLUG/$SID.jsonl"
  sim_write A "$ASLUG" "$SID" "$(uline 1)" "$(uline 2)"
  sim_run A >/dev/null
  n=$(find "$SIM/drive" -type f | wc -l)
  touch -d @1790000123 "$fa"
  run sim_run A
  [[ $output == *'0 installed, 0 published'* ]]
  [ "$(find "$SIM/drive" -type f | wc -l)" -eq "$n" ]
  [ "$(sim_exec A 'cs_tsv_field sessions local_mtime "$1"' "$SID")" = 1790000123 ]
}

@test "a rewrite that drops many chat lines is not accepted by the receiver (SPEC 12.4)" {
  fa="$SIM/A/claude/projects/$ASLUG/$SID.jsonl"
  sim_write A "$ASLUG" "$SID" "$(uline 1)" "$(uline 2)" "$(uline 3)" "$(uline 4)" "$(uline 5)" "$(uline 6)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  fb=$(sim_find B "$SID")
  before=$(cat "$fb")
  printf '%s\n' "$(uline 1)" >"$fa"
  sim_run A >/dev/null
  run sim_run B
  [[ $output == *'0 installed'* ]]
  [ "$(cat "$fb")" = "$before" ]
}

@test "both machines changed the session: nothing is overwritten and the session is marked conflict (forks: #20)" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  sim_write A "$ASLUG" "$SID" "$(uline 2)"
  fb=$(sim_find B "$SID")
  printf '{"type":"user","uuid":"u-b","cwd":"%s"}\n' "$BROOT" >>"$fb"
  sim_run A >/dev/null
  run sim_run B
  [[ $output == *'0 installed, 0 published'* ]]
  [[ $(sim_exec B 'cs_tsv_get sessions "$1"' "$SID") == *conflict* ]]
  [ "$(wc -l <"$fb")" -eq 2 ]
}

# --- ticket #18 slice 3: retention and restore (SPEC §12.9) -----------------------------------------------

sim_cli() { # NAME ARGS...
  local n=$1
  shift
  local -a e
  mapfile -t e < <(sim_env "$n")
  env "${e[@]}" bash "$CS_ROOT/bin/claude-sync" "$@"
}

@test "L12: a session older than B's retention is not installed, is listed, and restore installs it" {
  now=$(date +%s)
  sim_write A "$ASLUG" "$SID" "$(uline 1)" "$(uline 2)"
  touch -d "@$((now - 45 * 86400))" "$SIM/A/claude/projects/$ASLUG/$SID.jsonl"
  sim_run A >/dev/null
  run sim_run B
  [[ $output == *'0 installed'* ]]
  [ -z "$(sim_find B "$SID")" ]
  grep -q "^$SID" "$SIM/B/home/.claude-sync/state/retention_skipped"
  run sim_cli B restore "$SID"
  echo "$output"
  [ "$status" -eq 0 ]
  f=$(sim_find B "$SID")
  [ "$(wc -l <"$f")" -eq 2 ]
  m=$(stat -c %Y "$f")
  ((m > now - 86400 - 120 && m < now - 86400 + 120))
  run sim_run B
  [[ $output == *'0 installed, 0 published'* ]]
  run sim_cli B restore "$SID"
  [ "$status" -ne 0 ]
}

@test "a user who deletes a session on B loses nothing on A and B does not download it again (until a newer version)" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)" "$(uline 2)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  rm -f "$(sim_find B "$SID")"
  for m in B A B; do
    run sim_run "$m"
    [[ $output == *'0 installed, 0 published'* ]] || { echo "$m: $output"; return 1; }
  done
  [ -z "$(sim_find B "$SID")" ]
  [ "$(wc -l <"$SIM/A/claude/projects/$ASLUG/$SID.jsonl")" -eq 2 ]
  [ "$(sim_exec B 'cs_tsv_field sessions status "$1"' "$SID")" = local_absent_user ]
  sim_write A "$ASLUG" "$SID" "$(uline 3)"
  sim_run A >/dev/null
  run sim_run B
  [[ $output == *'1 installed'* ]]
  [ "$(wc -l <"$(sim_find B "$SID")")" -eq 3 ]
}

@test "a session gone because Claude swept it (older than the threshold) is local_absent_retention" {
  now=$(date +%s)
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  touch -d "@$((now - 20 * 86400))" "$SIM/A/claude/projects/$ASLUG/$SID.jsonl"
  sim_run A >/dev/null
  sim_run B >/dev/null
  [ -n "$(sim_find B "$SID")" ]
  printf '{"cleanupPeriodDays":10}\n' >"$SIM/B/claude/settings.json"
  rm -f "$(sim_find B "$SID")"
  sim_run B >/dev/null
  [ "$(sim_exec B 'cs_tsv_field sessions status "$1"' "$SID")" = local_absent_retention ]
  [ -n "$(sim_find A "$SID")" ]
}

# --- ticket #18 slice 4: relocate (SPEC §8.3, §8.5) -------------------------------------------------------

# a_move_to DIRNAME RELOCATED_CWD: Claude on A moves the session to another projects/ dir and appends a relocated line.
a_move_to() {
  local src="$SIM/A/claude/projects/$ASLUG/$SID.jsonl" dst="$SIM/A/claude/projects/$1"
  mkdir -p "$dst"
  mv "$src" "$dst/$SID.jsonl"
  printf '%s
' "{\"type\":\"relocated\",\"relocatedCwd\":\"$2\"}" >>"$dst/$SID.jsonl"
}

@test "M11: /cd to another folder of the project moves the file on B too (copy, verify, rename; old copy removed)" {
  mkdir -p "$BROOT/apps"
  sim_write A "$ASLUG" "$SID" "$(uline 1)" "$(uline 2)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  [ -f "$SIM/B/claude/projects/$BSLUG/$SID.jsonl" ]
  a_move_to D--Projects-X-apps 'D:\\Projects\\X\\apps'
  run sim_run A
  [[ $output == *'0 installed, 1 published'* ]]
  run sim_run B
  echo "$output"
  [[ $output == *'1 installed, 0 published'* ]]
  NEW="$SIM/B/claude/projects/$(cc_slug "$BROOT/apps")/$SID.jsonl"
  [ -f "$NEW" ]
  [ ! -e "$SIM/B/claude/projects/$BSLUG/$SID.jsonl" ]
  [ "$(sim_find B "$SID" | wc -l)" -eq 1 ]
  [ "$(wc -l <"$NEW")" -eq 3 ]
  grep -qF "\"relocatedCwd\":\"$BROOT/apps\"" "$NEW"
  for m in A B A B; do
    run sim_run "$m"
    [[ $output == *'0 installed, 0 published'* ]] || { echo "$m: $output"; return 1; }
  done
}

@test "P8b: /cd out of every project: the session keeps syncing and stays where it was on B" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  a_move_to D--Elsewhere 'E:\\Elsewhere'
  run sim_run A
  [[ $output == *'0 installed, 1 published'* ]]
  run sim_run B
  [[ $output == *'1 installed, 0 published'* ]]
  [ -f "$SIM/B/claude/projects/$BSLUG/$SID.jsonl" ]
  [ "$(wc -l <"$SIM/B/claude/projects/$BSLUG/$SID.jsonl")" -eq 2 ]
  printf '%s
' "$(uline 9)" >>"$SIM/A/claude/projects/D--Elsewhere/$SID.jsonl"
  run sim_run A
  [[ $output == *'0 installed, 1 published'* ]]
  run sim_run B
  [[ $output == *'1 installed, 0 published'* ]]
  [ "$(wc -l <"$SIM/B/claude/projects/$BSLUG/$SID.jsonl")" -eq 3 ]
  for m in A B; do
    run sim_run "$m"
    [[ $output == *'0 installed, 0 published'* ]] || { echo "$m: $output"; return 1; }
  done
}
