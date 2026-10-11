#!/usr/bin/env bats
# The wrapper `claude-sync claude` (ticket #28) on simulated machines.

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
  # the "claude" that the wrapper starts: records its arguments and the state of B's transcript at that moment
  CLAUDE_STUB="$BATS_TEST_TMPDIR/claude-stub"
  OUT="$BATS_TEST_TMPDIR/claude-out"
  cat >"$CLAUDE_STUB" <<'EOS'
#!/usr/bin/env bash
{
  for a in "$@"; do printf 'arg:%s\n' "$a"; done
  f=$(ls "$SIM_B_PROJECTS"/*/"$SID".jsonl 2>/dev/null | head -n 1)
  if [[ -n $f ]]; then echo "lines:$(wc -l <"$f")"; else echo "lines:none"; fi
} >"$OUT"
EOS
  chmod +x "$CLAUDE_STUB"
}

uline() { printf '{"type":"user","uuid":"u-%s","cwd":"D:\\\\Projects\\\\X"}' "$1"; }

# wrap ARGS...: the wrapper as machine B, started in B's project folder.
wrap() {
  local -a e
  mapfile -t e < <(sim_env B)
  (cd "$BROOT" && env "${e[@]}" CS_CLAUDE_BIN="$CLAUDE_STUB" CS_WRAPPER_CWD="${WRAP_CWD:-$BROOT}" OUT="$OUT" SID="$SID" \
    SIM_B_PROJECTS="$SIM/B/claude/projects" bash "$CS_ROOT/bin/claude-sync" claude "$@")
}

@test "A writes more, B starts the wrapper: when claude starts the file already has the new lines; arguments survive" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  sim_write A "$ASLUG" "$SID" "$(uline 2)" "$(uline 3)"
  sim_run A >/dev/null
  run wrap --resume "$SID" "an argument with spaces"
  [ "$status" -eq 0 ]
  grep -qx 'lines:3' "$OUT"
  grep -qx 'arg:--resume' "$OUT"
  grep -qx "arg:$SID" "$OUT"
  grep -qx 'arg:an argument with spaces' "$OUT"
}

@test "the wrapper installs only; it publishes nothing" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  printf '{"type":"user","uuid":"u-b","cwd":"%s"}\n' "$BROOT" >>"$(sim_find B "$SID")"
  n=$(find "$SIM/drive" -type f | wc -l)
  run wrap
  [ "$status" -eq 0 ]
  [ "$(find "$SIM/drive" -type f | wc -l)" -eq "$n" ]
}

@test "a lock that never clears does not keep claude from opening beyond the budget" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  sim_run A >/dev/null
  mapfile -t e < <(sim_env B)
  mkdir -p "$SIM/B/home/.claude-sync"
  (env "${e[@]}" bash -c 'exec 9>>"$CLAUDE_SYNC_HOME/sync.lock"; source "$CS_ROOT/lib/core.sh"; cs_bootstrap; cs_lock_fd 9 0 && sleep 12' 3>&- &) 
  sleep 2
  start=$SECONDS
  CS_WRAPPER_BUDGET=3 run wrap
  [ "$status" -eq 0 ]
  ((SECONDS - start < 10))
  grep -q 'lines:' "$OUT"
}

@test "offline: one warning line and claude opens anyway" {
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  sim_exec B 'cs_lfs_inject server_time 6 1'
  run wrap
  [ "$status" -eq 0 ]
  [[ $output == *'offline'* ]]
  [ -f "$OUT" ]
}

@test "a folder that is a candidate of a waiting project: asked on a terminal (y maps and pulls before claude opens), never asked without one" {
  # B has no project here: forget the one sim_machine mapped, and fake a waiting project that A syncs
  sim_exec B 'cs_tsv_delete projects p1 "$1"' "$BROOT"
  sim_write A "$ASLUG" "$SID" "$(uline 1)"
  sim_run A >/dev/null
  sim_exec B 'cs_config_set scan_dirs "$1"' "$SIM/B/work"
  sim_run B >/dev/null
  [ -n "$(sim_exec B 'cat "$CS_HOME/state/pending_map.tsv"' | grep '^remote')" ]
  # no terminal: no question, nothing mapped, claude still opens
  if command -v cygpath >/dev/null 2>&1; then WRAP_CWD=$(cygpath -w "$BROOT"); else WRAP_CWD=$BROOT; fi
  export WRAP_CWD
  run wrap
  [ "$status" -eq 0 ]
  [ -z "$(sim_exec B 'cs_tsv_rows projects')" ]
  [ -f "$OUT" ]
  rm -f "$OUT"
  # with a terminal and the answer y: mapped and pulled before claude starts
  if command -v cygpath >/dev/null 2>&1; then WRAP_CWD=$(cygpath -w "$BROOT"); else WRAP_CWD=$BROOT; fi
  export WRAP_CWD
  CS_WRAPPER_ASSUME_TTY=1 run wrap <<<y
  [ "$status" -eq 0 ]
  [ "$(sim_exec B 'cs_tsv_rows projects | cut -f1' | tr -d '\r')" = p1 ]
  grep -qx 'lines:1' "$OUT"
}
