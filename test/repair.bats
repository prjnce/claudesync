#!/usr/bin/env bats
# repair (ticket #15, SPEC §19). The fixture mirrors the real TransFlow damage: a legacy transcript that
# was re-serialized with spaces, CRLF and a WSL cwd, its compact original in a "<slug>.bak-*" junk dir
# inside projects/, a legacy transcript with lines the original lacks, a spaced subagent transcript with
# no original, and a native transcript that must not change by a single byte.

load test_helper

setup() {
  cs_test_setup
  cs_load platform version store claude transform projects ui repair
  T=$BATS_TEST_TMPDIR
  export CS_CLAUDE_DIR="$T/claude"
  mkdir -p "$T/work/X"
  cs_store_init
  ROOT=$(cs_native_path "$T/work/X")
  cs_project_map X "$T/work/X" >/dev/null 2>&1
  SLUG=$(cs_claude_slug "$ROOT")
  P="$CS_CLAUDE_DIR/projects"
  mkdir -p "$P/$SLUG/s1/subagents" "$P/$SLUG.bak-20260925-170208"
  if FOREIGN=$(cs_equiv_path "$ROOT"); then :; else FOREIGN=; fi
  [[ $CS_OS == linux ]] && FOREIGN= # a Linux temp dir has no Windows twin
  CWD=${FOREIGN:-$ROOT}
  E=$(cs_json_escape "$CWD")
  # Original (compact, LF) and its re-serialized legacy copy (spaces, CRLF).
  printf '%s\n' \
    "{\"type\":\"user\",\"cwd\":\"$E\",\"message\":{\"content\":\"xin chào \\\"q\\\" & é\"},\"n\":1}" \
    "{\"type\":\"assistant\",\"cwd\":\"$E/apps\",\"realParentDir\":\"$E\",\"n\":2}" >"$P/$SLUG.bak-20260925-170208/s1.jsonl"
  printf '%s\r\n' \
    "{\"type\": \"user\", \"cwd\": \"$E\", \"message\": {\"content\": \"xin chào \\\"q\\\" & é\"}, \"n\": 1}" \
    "{\"type\": \"assistant\", \"cwd\": \"$E/apps\", \"realParentDir\": \"$E\", \"n\": 2}" >"$P/$SLUG/s1.jsonl"
  # Legacy with an extra line the original does not have.
  cp "$P/$SLUG.bak-20260925-170208/s1.jsonl" "$P/$SLUG.bak-20260925-170208/s2.jsonl"
  { cat "$P/$SLUG/s1.jsonl"; printf '%s\r\n' "{\"type\": \"user\", \"cwd\": \"$E\", \"n\": 3, \"z\": [1, 2]}"; } >"$P/$SLUG/s2.jsonl"
  # Subagent transcript re-serialized, no original.
  printf '%s\n' "{\"type\": \"user\", \"cwd\": \"$E\", \"isSidechain\": true}" >"$P/$SLUG/s1/subagents/agent-a.jsonl"
  # Native transcript: never touched.
  printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$(cs_json_escape "$ROOT")\",\"n\":9}" >"$P/$SLUG/s3.jsonl"
  cp -p "$P/$SLUG/s3.jsonl" "$T/s3.orig"
  touch -d @1790000000 "$P/$SLUG/s1.jsonl"
}

@test "equivalent paths across the Windows/WSL boundary" {
  [ "$(cs_equiv_path /mnt/d/Projects/TransFlow)" = 'D:\Projects\TransFlow' ]
  [ "$(cs_equiv_path 'd:\Projects\TransFlow')" = /mnt/d/Projects/TransFlow ]
  run cs_equiv_path /home/u/x
  [ "$status" -eq 1 ]
}

@test "dry run reports and changes nothing" {
  before=$(find "$P" -type f -exec md5sum {} + | sort)
  run cs_repair --dry-run
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"$SLUG/s1.jsonl"* && $output == *"$SLUG/s2.jsonl"* && $output == *agent-a.jsonl* ]]
  [[ $output != *"$SLUG/s3.jsonl"* ]]
  [[ $output == *"$SLUG.bak-20260925-170208"* ]]
  [ "$(find "$P" -type f -exec md5sum {} + | sort)" = "$before" ]
  [ -z "$(ls "$CLAUDE_SYNC_HOME/staging")" ]
}

@test "repair: original bytes reused, extra lines compacted, CRLF gone, cwd translated, mtime kept" {
  run cs_repair --yes
  echo "$output"
  [ "$status" -eq 0 ]
  for f in s1 s2; do [ "$(tr -cd '\r' <"$P/$SLUG/$f.jsonl" | wc -c)" -eq 0 ]; done
  ! grep -q -F '": "' "$P/$SLUG/s1.jsonl"
  ! grep -q -F '": "' "$P/$SLUG/s2.jsonl"
  ! grep -q -F '": "' "$P/$SLUG/s1/subagents/agent-a.jsonl"
  grep -q -F "\"cwd\":\"$(cs_json_escape "$ROOT")\"" "$P/$SLUG/s1.jsonl"
  grep -q -F "\"cwd\":\"$(cs_json_escape "$ROOT")$(cs_is_windows && echo '\\' || echo /)apps\"" "$P/$SLUG/s1.jsonl"
  [ "$(sed -n 3p "$P/$SLUG/s2.jsonl")" = "{\"type\":\"user\",\"cwd\":\"$(cs_json_escape "$ROOT")\",\"n\":3,\"z\":[1,2]}" ]
  grep -q -F 'xin chào \"q\" & é' "$P/$SLUG/s1.jsonl"
  [ "$(stat -c %Y "$P/$SLUG/s1.jsonl")" = 1790000000 ]
  cmp "$P/$SLUG/s3.jsonl" "$T/s3.orig"
  [ "$(stat -c %Y "$P/$SLUG/s3.jsonl")" = "$(stat -c %Y "$T/s3.orig")" ]
}

@test "repair: the original line bytes are reused verbatim, not re-serialized" {
  # A key order and spacing that a re-serializer would never produce from the spaced copy.
  printf '%s\n' '{"n":1,"type":"user","a":1.50}' >"$P/$SLUG.bak-20260925-170208/s9.jsonl"
  printf '%s\r\n' '{"n": 1, "type": "user", "a": 1.5}' >"$P/$SLUG/s9.jsonl"
  cs_repair --yes >/dev/null
  [ "$(cat "$P/$SLUG/s9.jsonl")" = '{"n":1,"type":"user","a":1.50}' ]
}

@test "repair: junk dir moves to backups, originals of rewritten files are backed up" {
  cs_repair --yes >/dev/null
  [ ! -e "$P/$SLUG.bak-20260925-170208" ]
  b=$(ls -d "$CLAUDE_SYNC_HOME"/backups/repair-*)
  [ -d "$b/junk/$SLUG.bak-20260925-170208" ]
  [ "$(tr -cd '\r' <"$b/projects/$SLUG/s1.jsonl" | wc -c)" -gt 0 ] # the backup is the damaged original
  [ -f "$b/projects/$SLUG/s1/subagents/agent-a.jsonl" ]
  [ ! -e "$b/projects/$SLUG/s3.jsonl" ]
  [ -z "$(cs_claude_junk_dirs)" ]
  [ -z "$(cs_claude_dup_ids)" ]
}

@test "repair is idempotent: a second run finds nothing to do" {
  cs_repair --yes >/dev/null
  run cs_repair --yes
  [ "$status" -eq 0 ]
  [[ $output == *'Nothing to repair'* ]]
}

@test "a native transcript with a nested Git Bash cwd is not touched (false-positive guard)" {
  printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$(cs_json_escape "$ROOT")\",\"wireIngestContext\":{\"x\":{\"cwd\":\"/d/Projects/X\"}}}" >"$P/$SLUG/s4.jsonl"
  cp -p "$P/$SLUG/s4.jsonl" "$T/s4.orig"
  run cs_repair --dry-run
  [[ $output != *"$SLUG/s4.jsonl"* ]]
  cs_repair --yes >/dev/null
  cmp "$P/$SLUG/s4.jsonl" "$T/s4.orig"
}

@test "long lines with multi-byte characters still match their original (jq 1.6 raw-mode bug)" {
  # A >200 KB line of box-drawing and Vietnamese characters: jq -R would corrupt characters that straddle
  # its read buffer, the line would no longer match its original and get re-serialized instead.
  big=$(for i in $(seq 1 9000); do printf '│ ằ─'; done)
  printf '%s\n' "{\"type\":\"user\",\"n\":7,\"t\":\"$big\"}" >"$P/$SLUG.bak-20260925-170208/s7.jsonl"
  printf '%s\r\n' "{\"type\": \"user\", \"n\": 7, \"t\": \"$big\"}" >"$P/$SLUG/s7.jsonl"
  run cs_repair --yes
  [[ $output == *"$SLUG/s7.jsonl"* ]]
  [[ $output == *'1 lines: 1 from the original, 0 re-serialized'* ]]
  cmp "$P/$SLUG/s7.jsonl" "$CLAUDE_SYNC_HOME"/backups/repair-*/junk/"$SLUG".bak-20260925-170208/s7.jsonl
}

@test "a compact line without an original is kept byte for byte (not re-serialized)" {
  printf '%s\r\n' '{"type": "user", "n": 1}' '{"type":"assistant","x":"a \": b","n":2.50}' >"$P/$SLUG/s8.jsonl"
  cs_repair --yes >/dev/null
  [ "$(sed -n 2p "$P/$SLUG/s8.jsonl")" = '{"type":"assistant","x":"a \": b","n":2.50}' ]
  [ "$(sed -n 1p "$P/$SLUG/s8.jsonl")" = '{"type":"user","n":1}' ]
}

@test "DEL bytes and lone surrogates survive byte for byte" {
  printf '%s\n' "{\"type\":\"user\",\"t\":\"a$(printf '\x7f')b \\ud800 c\"}" >"$P/$SLUG.bak-20260925-170208/s6.jsonl"
  printf '%s\r\n' "{\"type\": \"user\", \"t\": \"a$(printf '\x7f')b \\ud800 c\"}" >"$P/$SLUG/s6.jsonl"
  printf '%s\r\n' "{\"type\": \"user\", \"t\": \"x$(printf '\x7f')y \\udfff z\"}" >"$P/$SLUG/s5.jsonl"
  cs_repair --yes >/dev/null
  cmp "$P/$SLUG/s6.jsonl" "$CLAUDE_SYNC_HOME"/backups/repair-*/junk/"$SLUG".bak-20260925-170208/s6.jsonl
  [ "$(cat "$P/$SLUG/s5.jsonl")" = "{\"type\":\"user\",\"t\":\"x$(printf '\x7f')y \\udfff z\"}" ]
}

@test "a run killed half way leaves the originals intact; the next run cleans up and completes" {
  # Simulate the kill: the journal entry and temp file exist, the target was never replaced.
  j=$(cs_journal_begin repair "{\"file\":\"$P/$SLUG/s1.jsonl\",\"tmp\":[\"$P/$SLUG/s1.jsonl.csync-tmp\"]}")
  printf 'partial' >"$P/$SLUG/s1.jsonl.csync-tmp"
  cp -p "$P/$SLUG/s1.jsonl" "$T/s1.before"
  cmp "$P/$SLUG/s1.jsonl" "$T/s1.before"
  cs_repair --yes >/dev/null
  [ ! -e "$P/$SLUG/s1.jsonl.csync-tmp" ]
  [ ! -e "$j" ]
  [ "$(tr -cd '\r' <"$P/$SLUG/s1.jsonl" | wc -c)" -eq 0 ]
  [ -z "$(cs_journal_pending)" ]
}

@test "live sessions are skipped" {
  sleep 60 3>&- &
  spid=$!
  npid=$(if cs_is_windows; then cat "/proc/$spid/winpid"; else echo "$spid"; fi)
  mkdir -p "$CS_CLAUDE_DIR/sessions"
  printf '{"pid":%s,"sessionId":"s1","procStart":"%s","pidDomain":"%s"}' "$npid" "$(cs_proc_start_ids "$npid" | cut -f2)" "$(cs_claude_pid_domain)" >"$CS_CLAUDE_DIR/sessions/$npid.json"
  run cs_repair --yes
  kill "$spid"
  [[ $output == *"$SLUG/s1.jsonl"*'open in Claude'* ]]
  [ "$(tr -cd '\r' <"$P/$SLUG/s1.jsonl" | wc -c)" -gt 0 ]
  [ "$(tr -cd '\r' <"$P/$SLUG/s2.jsonl" | wc -c)" -eq 0 ]
}

@test "without node and python, unmatched lines are kept and reported" {
  cs_repair_compactor_kind() { printf 'none\n'; }
  run cs_repair --yes
  [ "$status" -eq 0 ]
  grep -q -F '": "' "$P/$SLUG/s1/subagents/agent-a.jsonl" # kept, not mangled
  ! grep -q -F '": "' "$P/$SLUG/s1.jsonl"                   # came from the original
}

@test "CLI: repair --dry-run exits 0 and leaves files alone; unknown flag is a usage error" {
  run cli repair --dry-run
  [ "$status" -eq 0 ]
  [ "$(tr -cd '\r' <"$P/$SLUG/s1.jsonl" | wc -c)" -gt 0 ]
  run cli repair --frob
  [ "$status" -eq 2 ]
}
