#!/usr/bin/env bats
# Memory 3-way merge and plans (ticket #22). Machines B and C are POSIX-style (a real memory dir); C has a root of its own.

load test_helper
load sim_helper

SID=0b7a1c2e-1111-4222-8333-444455556666

setup() {
  cs_test_setup
  cs_load platform version
  sim_init
  BROOT="$SIM/B/work/X"
  CROOT="$SIM/C/work/X"
  sim_machine B p "$BROOT"
  sim_machine C p "$CROOT"
  BMEM="$SIM/B/claude/projects/$(cc_slug "$BROOT")/memory"
  CMEM="$SIM/C/claude/projects/$(cc_slug "$CROOT")/memory"
  mkdir -p "$BMEM" "$CMEM"
}

# sync_all: B, C, B, C (enough rounds to settle).
sync_all() { local m; for m in B C B C; do sim_run "$m" >/dev/null; done; }

@test "a new memory file travels and the index merges line by line (different lines: clean; same line: union)" {
  printf 'l1
l2
l3
l4
l5
' >"$BMEM/MEMORY.md"
  printf 'alpha
' >"$BMEM/a.md"
  sync_all
  [ "$(cat "$CMEM/a.md")" = alpha ]
  [ "$(cat "$CMEM/MEMORY.md")" = "$(cat "$BMEM/MEMORY.md")" ]
  # different lines
  sed -i 's/^l1$/l1-B/' "$BMEM/MEMORY.md"
  sed -i 's/^l5$/l5-C/' "$CMEM/MEMORY.md"
  sync_all
  [ "$(cat "$BMEM/MEMORY.md")" = "$(cat "$CMEM/MEMORY.md")" ]
  grep -q '^l1-B$' "$BMEM/MEMORY.md"
  grep -q '^l5-C$' "$BMEM/MEMORY.md"
  # the same line
  sed -i 's/^l3$/l3-from-B/' "$BMEM/MEMORY.md"
  sed -i 's/^l3$/l3-from-C/' "$CMEM/MEMORY.md"
  sync_all
  [ "$(cat "$BMEM/MEMORY.md")" = "$(cat "$CMEM/MEMORY.md")" ]
  grep -q 'l3-from-B' "$BMEM/MEMORY.md"
  grep -q 'l3-from-C' "$BMEM/MEMORY.md"
}

@test "M9: B deletes foo.md and its index line; C, unchanged, deletes both too, with a backup" {
  printf 'idx1
- foo
idx2
' >"$BMEM/MEMORY.md"
  printf 'foo body
' >"$BMEM/foo.md"
  sync_all
  [ -f "$CMEM/foo.md" ]
  rm "$BMEM/foo.md"
  printf 'idx1
idx2
' >"$BMEM/MEMORY.md"
  sync_all
  [ ! -e "$CMEM/foo.md" ]
  [ "$(cat "$CMEM/MEMORY.md")" = "$(printf 'idx1
idx2
')" ]
  [ -n "$(find "$SIM/C/home/.claude-sync/backups" -name foo.md)" ]
  for m in B C B C; do
    run sim_run "$m"
    [ "$status" -eq 0 ]
  done
  [ ! -e "$BMEM/foo.md" ]
}

@test "both sides changed a non-index file: local is kept, the other version goes to conflicts/ and is reported" {
  printf 'one
' >"$BMEM/note.md"
  sync_all
  printf 'from B
' >"$BMEM/note.md"
  printf 'from C
' >"$CMEM/note.md"
  sim_run B >/dev/null
  sim_run C >/dev/null
  [ "$(cat "$CMEM/note.md")" = 'from C' ]
  [ -n "$(find "$SIM/C/home/.claude-sync/conflicts" -type f)" ]
  grep -q 'note.md' "$SIM/C/home/.claude-sync/state/status.json"
  sync_all
  [ "$(cat "$BMEM/note.md")" = "$(cat "$CMEM/note.md")" ]
}

@test "without git on PATH both-changed files fall back to keep local + conflict copy" {
  printf 'a
b
c
' >"$BMEM/MEMORY.md"
  sync_all
  printf 'a-B
b
c
' >"$BMEM/MEMORY.md"
  printf 'a
b
c-C
' >"$CMEM/MEMORY.md"
  sim_run B >/dev/null
  sim_exec C 'cs_dsync_merge() { return 1; }; cs_run' >/dev/null
  [ "$(cat "$CMEM/MEMORY.md")" = "$(printf 'a
b
c-C
')" ]
  [ -n "$(find "$SIM/C/home/.claude-sync/conflicts" -type f)" ]
}

@test "names that are invalid on Windows are skipped, never an error" {
  run sim_exec B 'CS_SEP=w; cs_dsync_name_ok "a:b.md" mem; echo "$?"; cs_dsync_name_ok "ok.md" mem; echo "$?"; cs_dsync_name_ok "trail. .md" mem; echo "$?"; cs_dsync_name_ok "x.md." mem; echo "$?"; CS_SEP=p; cs_dsync_name_ok "a:b.md" mem; echo "$?"; cs_dsync_name_ok "team/x.md" mem; echo "$?"'
  [ "$output" = "$(printf '1
0
0
1
0
1')" ]
}

@test "plans: a plan referenced by a synced session travels; the newer one wins when both changed" {
  mkdir -p "$SIM/B/claude/plans" "$SIM/C/claude/plans"
  slug=calm-river-test
  sim_write B "$(cc_slug "$BROOT")" "$SID" "{\"type\":\"user\",\"cwd\":\"$BROOT\",\"slug\":\"$slug\"}"
  printf 'plan v1
' >"$SIM/B/claude/plans/$slug.md"
  printf 'other plan
' >"$SIM/B/claude/plans/unrelated.md"
  sync_all
  [ "$(cat "$SIM/C/claude/plans/$slug.md")" = 'plan v1' ]
  [ ! -e "$SIM/C/claude/plans/unrelated.md" ]
  printf 'plan B
' >"$SIM/B/claude/plans/$slug.md"
  printf 'plan C
' >"$SIM/C/claude/plans/$slug.md"
  touch -d '+1 hour' "$SIM/C/claude/plans/$slug.md"
  sync_all
  [ "$(cat "$SIM/B/claude/plans/$slug.md")" = 'plan C' ]
  [ -n "$(find "$SIM/C/home/.claude-sync/conflicts" -type f)" ]
}
