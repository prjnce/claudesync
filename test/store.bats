#!/usr/bin/env bats
# store: TSV tables, known sets, journal (ticket #07).

load test_helper

setup() {
  cs_test_setup
  cs_load platform store
  cs_store_init
}

row() { local IFS=$'\t'; printf '%s\n' "$*"; }

@test "init creates the tree; deleting state/ and re-running rebuilds it empty" {
  for d in state/known state/remote state/base/mem journal cache/manifests staging backups conflicts logs; do
    [ -d "$CLAUDE_SYNC_HOME/$d" ]
  done
  rm -rf "$CLAUDE_SYNC_HOME/state"
  cs_store_init
  [ -d "$CLAUDE_SYNC_HOME/state/known" ]
  [ -z "$(cs_tsv_rows sessions)" ]
}

@test "staging is on the same volume as a directory next to it" {
  mkdir -p "$HOME/.claude"
  cs_store_same_volume "$HOME/.claude"
}

@test "upsert inserts, replaces in place, and get/field read it back" {
  cs_tsv_upsert objects a/1 F1 s1 10 done "" t1
  cs_tsv_upsert objects a/2 F2 s2 20 uploading "https://up/x" t2
  cs_tsv_upsert objects a/1 F1 s1b 11 done "" t3
  run cs_tsv_rows objects
  [ "${lines[0]}" = "$(row a/1 F1 s1b 11 done '' t3)" ]
  [ "${lines[1]}" = "$(row a/2 F2 s2 20 uploading https://up/x t2)" ]
  [ "$(cs_tsv_field objects size a/2)" = 20 ]
  [ "$(cs_tsv_field objects resumable_uri a/1)" = "" ]
  run cs_tsv_get objects a/3
  [ "$status" -eq 1 ]
}

@test "file starts with a header line naming the columns" {
  cs_tsv_upsert forks s1 v1 f1 t
  [ "$(head -n 1 "$CLAUDE_SYNC_HOME/state/forks.tsv")" = "$(printf '#sid\tlosing_version\tfork_sid\tcreated')" ]
}

@test "composite keys: projects has one row per (project_id, cwd_root)" {
  cs_tsv_upsert projects p1 'D:\Projects\TransFlow' TransFlow 'D:\Projects\TransFlow' m 1 ""
  cs_tsv_upsert projects p1 /mnt/d/Projects/TransFlow TransFlow /mnt/d/Projects/TransFlow m 1 ""
  cs_tsv_upsert projects p1 /mnt/d/Projects/TransFlow TransFlow2 /mnt/d/Projects/TransFlow m 1 k1
  [ "$(cs_tsv_rows projects | wc -l)" -eq 2 ]
  [ "$(cs_tsv_field projects alias p1 /mnt/d/Projects/TransFlow)" = TransFlow2 ]
  cs_tsv_delete projects p1 'D:\Projects\TransFlow'
  [ "$(cs_tsv_rows projects | wc -l)" -eq 1 ]
}

@test "a key that is a prefix of another key does not match" {
  cs_tsv_upsert forks s1 v12 f t
  run cs_tsv_get forks s1 v1
  [ "$status" -eq 1 ]
}

@test "batch upsert: one pass, last duplicate wins, new rows appended in order" {
  cs_tsv_upsert forks s0 v0 f0 t0
  { row s1 v1 f1 t1; row s2 v2 f2 t2; row s1 v1 f1x t3; row s0 v0 f0x t4; } | cs_tsv_upsert_many forks
  run cs_tsv_rows forks
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "$(row s0 v0 f0x t4)" ]
  [ "${lines[1]}" = "$(row s1 v1 f1x t3)" ]
  [ "${lines[2]}" = "$(row s2 v2 f2 t2)" ]
}

@test "fields with tab or newline, and wrong field counts, are rejected" {
  run cs_tsv_upsert forks s1 $'v\t1' f t
  [ "$status" -eq 1 ]
  run cs_tsv_upsert forks s1 $'v\n1' f t
  [ "$status" -eq 1 ]
  run cs_tsv_upsert forks s1 v1 f
  [ "$status" -eq 1 ]
  [ ! -s "$CLAUDE_SYNC_HOME/state/forks.tsv" ] || [ "$(cs_tsv_rows forks | wc -l)" -eq 0 ]
}

@test "empty fields survive a round trip, including the last column" {
  cs_tsv_upsert sessions s1 "" "" 1 2 3 "" "" "" synced "" ""
  local -a f
  cs_tsv_split "$(cs_tsv_get sessions s1)" f
  [ "${#f[@]}" -eq 12 ]
  [ "${f[9]}" = synced ]
  [ "${f[11]}" = "" ]
}

@test "a file with a foreign header is refused (schema mismatch)" {
  printf '#something\telse\n' >"$CLAUDE_SYNC_HOME/state/forks.tsv"
  run cs_tsv_rows forks
  [ "$status" -eq 1 ]
  [[ $output == *"schema mismatch"* ]]
}

@test "unknown table is an error" {
  run cs_tsv_rows nope
  [ "$status" -eq 1 ]
}

@test "concurrent writers under the sync lock lose no rows" {
  local i pids=()
  for i in $(seq 1 10); do
    (
      cs_lock_acquire "$CLAUDE_SYNC_HOME/sync.lock" 60
      cs_tsv_upsert forks "s$i" v f t
    ) 3>&- &
    pids+=($!)
  done
  for i in "${pids[@]}"; do wait "$i"; done
  [ "$(cs_tsv_rows forks | wc -l)" -eq 10 ]
}

@test "known set is append-only and deduplicated" {
  cs_known_add 0b7a-sid abc123
  cs_known_add 0b7a-sid abc123
  cs_known_add 0b7a-sid def456
  [ "$(wc -l <"$CLAUDE_SYNC_HOME/state/known/0b7a-sid")" -eq 2 ]
  cs_known_has 0b7a-sid def456
  ! cs_known_has 0b7a-sid abc12
  run cs_known_add '../x' abc
  [ "$status" -eq 1 ]
}

@test "journal: begin/end, pending order, op name, invalid payload" {
  a=$(cs_journal_begin install '{"sid":"s1"}')
  b=$(cs_journal_begin repair-move '{"sid":"s2"}')
  run cs_journal_pending
  [ "${lines[0]}" = "$a" ]
  [ "${lines[1]}" = "$b" ]
  [ "$(cs_journal_op "$b")" = repair-move ]
  cs_journal_end "$a"
  [ "$(cs_journal_pending)" = "$b" ]
  run cs_journal_begin install 'not json'
  [ "$status" -eq 1 ]
}

@test "journal: entries left by a killed process are listed, abandon removes only csync-tmp files" {
  local tmpf="$HOME/target.jsonl.csync-tmp" keep="$HOME/target.jsonl"
  : >"$tmpf"
  : >"$keep"
  (
    source "$CS_ROOT/lib/core.sh"
    source "$CS_ROOT/lib/store.sh"
    cs_bootstrap
    cs_journal_begin install "{\"tmp\":[\"$tmpf\",\"$keep\"]}" >/dev/null
    sleep 30
  ) >/dev/null 2>&1 3>&- &
  local pid=$! i
  for i in $(seq 1 100); do # the journal entry must exist before the kill (slow machines)
    [[ -n $(ls "$CLAUDE_SYNC_HOME"/journal/*.json 2>/dev/null) ]] && break
    sleep 0.2
  done
  kill -9 "$pid"
  wait "$pid" 2>/dev/null || true
  run cs_journal_pending
  [ "${#lines[@]}" -eq 1 ]
  cs_journal_abandon "${lines[0]}"
  [ ! -e "$tmpf" ]
  [ -e "$keep" ]
  [ -z "$(cs_journal_pending)" ]
}
