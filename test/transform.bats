#!/usr/bin/env bats
# transform: canonicalize/localize (ticket #13, SPEC §7). Fixtures are written with printf so the bytes
# are explicit: in JSON a Windows path separator is the two bytes \\ .

load test_helper

setup() {
  cs_test_setup
  cs_load transform
  T=$BATS_TEST_TMPDIR
  # Machine A (Windows): project p1 at D:\Projects\TransFlow (real root differs to exercise {R:}),
  # memory dir under the Claude config, plans under {CFG}.
  WIN_ROWS=$(
    cs_transform_row P '{P:p1}' 'D:\Projects\TransFlow'
    cs_transform_row R '{R:p1}' 'E:\Real\TransFlow'
    cs_transform_row A '{MEM:p1}' 'C:\Users\frank\.claude\projects\D--Projects-TransFlow\memory'
    cs_transform_row A '{CFG}/plans' 'C:\Users\frank\.claude\plans'
  )
  # Machine B (Linux): same project under a different folder name.
  LIN_ROWS=$(
    cs_transform_row P '{P:p1}' '/home/u/projects/TransFlowX'
    cs_transform_row R '{R:p1}' '/data/TransFlowX'
    cs_transform_row A '{MEM:p1}' '/home/u/.claude/projects/-home-u-projects-TransFlowX/memory'
    cs_transform_row A '{CFG}/plans' '/home/u/.claude/plans'
  )
}

canon_win() { CS_SEP=w cs_transform canon "$WIN_ROWS"; }
local_lin() { CS_SEP=p cs_transform local "$LIN_ROWS"; }
canon_lin() { CS_SEP=p cs_transform canon "$LIN_ROWS"; }
local_win() { CS_SEP=w cs_transform local "$WIN_ROWS"; }

@test "row builder: style, case rule and JSON escaping follow the path form" {
  [ "$(cs_transform_row P t 'D:\Projects\X\')" = "$(printf 'P\tt\tD:\\\\Projects\\\\X\tw\t1')" ]
  [ "$(cs_transform_row P t 'd:/Projects/X')" = "$(printf 'P\tt\td:\\\\Projects\\\\X\tw\t1')" ]
  [ "$(cs_transform_row P t '/mnt/d/Projects/X/')" = "$(printf 'P\tt\t/mnt/d/Projects/X\tp\t1')" ]
  [ "$(cs_transform_row P t '/home/u/x')" = "$(printf 'P\tt\t/home/u/x\tp\t0')" ]
  [ "$(cs_transform_row R t '\\srv\share\x')" = "$(printf 'R\tt\t\\\\\\\\srv\\\\share\\\\x\tw\t1')" ]
}

@test "cwd: Windows root to token, either drive-letter case, rest uses /" {
  out=$(printf '%s\n' '{"cwd":"D:\\Projects\\TransFlow\\apps\\server","type":"user"}' '{"cwd":"d:\\projects\\transflow"}' | canon_win)
  [ "$out" = $'{"cwd":"{P:p1}/apps/server","type":"user"}\n{"cwd":"{P:p1}"}' ]
}

@test "path boundary: TransFlowOld is not under TransFlow" {
  out=$(printf '%s\n' '{"cwd":"D:\\Projects\\TransFlowOld\\x"}' | canon_win)
  [ "$out" = '{"cwd":"D:\\Projects\\TransFlowOld\\x"}' ]
}

@test "relocatedCwd, trackingPath (absolute and relative) and trackedFileBackups keys" {
  in='{"type":"relocated","relocatedCwd":"D:\\Projects\\TransFlow\\sub"}
{"trackingPath":"D:\\Projects\\TransFlow\\a.ts","x":{"trackingPath":"src\\b.ts"}}
{"trackedFileBackups":{"D:\\Projects\\TransFlow\\a.ts":{"backupFileName":"abc@v1"},"src\\c.ts":{"backupFileName":"def@v2"}}}'
  want='{"type":"relocated","relocatedCwd":"{P:p1}/sub"}
{"trackingPath":"{P:p1}/a.ts","x":{"trackingPath":"src/b.ts"}}
{"trackedFileBackups":{"{P:p1}/a.ts":{"backupFileName":"abc@v1"},"src/c.ts":{"backupFileName":"def@v2"}}}'
  [ "$(printf '%s\n' "$in" | canon_win)" = "$want" ]
}

@test "realParentDir uses the real root {R:}; cwd never does (P3)" {
  out=$(printf '%s\n' '{"realParentDir":"E:\\Real\\TransFlow\\src","cwd":"E:\\Real\\TransFlow"}' | canon_win)
  [ "$out" = '{"realParentDir":"{R:p1}/src","cwd":"E:\\Real\\TransFlow"}' ]
}

@test "memory and plans paths map to {MEM:} and {CFG}; the longest root wins (P4)" {
  out=$(printf '%s\n' '{"trackingPath":"C:\\Users\\frank\\.claude\\projects\\D--Projects-TransFlow\\memory\\MEMORY.md","realParentDir":"C:\\Users\\frank\\.claude\\plans"}' | canon_win)
  [ "$out" = '{"trackingPath":"{MEM:p1}/MEMORY.md","realParentDir":"{CFG}/plans"}' ]
}

@test "nested roots differing between machines: the longest match wins (P5)" {
  rows=$(cs_transform_row P '{P:a}' '/home/u/work'; cs_transform_row P '{P:b}' '/home/u/work/TransFlow')
  out=$(printf '%s\n' '{"cwd":"/home/u/work/TransFlow/x"}' '{"cwd":"/home/u/work/other"}' | CS_SEP=p cs_transform canon "$rows")
  [ "$out" = $'{"cwd":"{P:b}/x"}\n{"cwd":"{P:a}/other"}' ]
}

@test "/mnt/<x> roots match case-insensitively; plain Linux roots do not" {
  rows=$(cs_transform_row P '{P:w}' '/mnt/d/Projects/X'; cs_transform_row P '{P:l}' '/home/u/X')
  out=$(printf '%s\n' '{"cwd":"/mnt/D/projects/x/y"}' '{"cwd":"/home/u/x"}' | CS_SEP=p cs_transform canon "$rows")
  [ "$out" = $'{"cwd":"{P:w}/y"}\n{"cwd":"/home/u/x"}' ]
}

@test "values outside key context are untouched: message text, nested Git Bash cwd, other keys" {
  in='{"message":{"content":"cd D:\\Projects\\TransFlow && ls"},"wireIngestContext":{"x":{"cwd":"/d/Projects/TransFlow"}},"path":"D:\\Projects\\TransFlow"}'
  [ "$(printf '%s\n' "$in" | canon_win)" = "$in" ]
}

@test "bytes are preserved: escapes, Vietnamese, &, CRLF, lines without paths" {
  in=$'{"cwd":"D:\\\\Projects\\\\TransFlow\\\\D\xe1\xbb\xb1 \xc3\xa1n","t":"a \\"q\\" & \\\\ \\u00e9 \\n"}\r\n{"type":"summary"}\n'
  want=$'{"cwd":"{P:p1}/D\xe1\xbb\xb1 \xc3\xa1n","t":"a \\"q\\" & \\\\ \\u00e9 \\n"}\r\n{"type":"summary"}\n'
  printf '%s' "$in" >"$T/in.jsonl"
  cs_transform_file canon "$WIN_ROWS" "$T/in.jsonl" "$T/out.jsonl"
  printf '%s' "$want" >"$T/want.jsonl"
  cmp "$T/out.jsonl" "$T/want.jsonl"
}

@test "a missing final newline is preserved; an unterminated last line is left as is" {
  printf '%s\n%s' '{"cwd":"D:\\Projects\\TransFlow"}' '{"cwd":"D:\\Projects\\TransFl' >"$T/in.jsonl"
  CS_SEP=w cs_transform_file canon "$WIN_ROWS" "$T/in.jsonl" "$T/out.jsonl"
  [ "$(cat "$T/out.jsonl"; printf END)" = "$(printf '%s\n%s' '{"cwd":"{P:p1}"}' '{"cwd":"D:\\Projects\\TransFl')END" ]
}

@test "round trip Windows -> canonical -> Linux -> canonical is stable, and back to Windows" {
  in='{"cwd":"D:\\Projects\\TransFlow\\apps","x":{"trackingPath":"src\\b.ts"}}
{"realParentDir":"E:\\Real\\TransFlow\\lib","trackedFileBackups":{"D:\\Projects\\TransFlow\\a.ts":{"backupFileName":"h@v1"}}}
{"trackingPath":"C:\\Users\\frank\\.claude\\plans\\p.md"}'
  c1=$(printf '%s\n' "$in" | canon_win)
  lin=$(printf '%s\n' "$c1" | local_lin)
  [ "$lin" = '{"cwd":"/home/u/projects/TransFlowX/apps","x":{"trackingPath":"src/b.ts"}}
{"realParentDir":"/data/TransFlowX/lib","trackedFileBackups":{"/home/u/projects/TransFlowX/a.ts":{"backupFileName":"h@v1"}}}
{"trackingPath":"/home/u/.claude/plans/p.md"}' ]
  c2=$(printf '%s\n' "$lin" | canon_lin)
  [ "$c1" = "$c2" ]
  [ "$(printf '%s\n' "$c2" | local_win)" = "$in" ]
}

@test "canonicalize is idempotent" {
  c1=$(printf '%s\n' '{"cwd":"D:\\Projects\\TransFlow\\a","trackingPath":"x\\y"}' | canon_win)
  [ "$(printf '%s\n' "$c1" | canon_win)" = "$c1" ]
}

@test "prefix property: transform(first k lines) == first k lines of transform(all)" {
  for i in $(seq 1 30); do printf '{"cwd":"D:\\\\Projects\\\\TransFlow\\\\d%d","n":%d}\n' "$i" "$i"; done >"$T/in.jsonl"
  cs_transform_file canon "$WIN_ROWS" "$T/in.jsonl" "$T/all.jsonl"
  head -n 12 "$T/in.jsonl" >"$T/head.jsonl"
  cs_transform_file canon "$WIN_ROWS" "$T/head.jsonl" "$T/headout.jsonl"
  cmp "$T/headout.jsonl" <(head -n 12 "$T/all.jsonl")
}

@test "tail-only transform from an offset equals the tail of a full transform" {
  for i in $(seq 1 20); do printf '{"cwd":"D:\\\\Projects\\\\TransFlow","i":%d}\n' "$i"; done >"$T/in.jsonl"
  off=$(head -n 7 "$T/in.jsonl" | wc -c)
  cs_transform_file canon "$WIN_ROWS" "$T/in.jsonl" "$T/all.jsonl"
  cs_transform_file canon "$WIN_ROWS" "$T/in.jsonl" "$T/tail.jsonl" "$off"
  cmp "$T/tail.jsonl" <(tail -n 13 "$T/all.jsonl")
}

@test "gawk and mawk produce identical bytes (P10)" {
  command -v mawk >/dev/null && command -v gawk >/dev/null || skip "needs both mawk and gawk"
  in='{"cwd":"D:\\Projects\\TransFlow\\x","t":"& \\ \\u00e9"}
{"trackedFileBackups":{"src\\a":{"backupFileName":"b"}}}'
  a=$(printf '%s\n' "$in" | CS_AWK=gawk canon_win | CS_AWK=gawk local_lin)
  b=$(printf '%s\n' "$in" | CS_AWK=mawk canon_win | CS_AWK=mawk local_lin)
  [ "$a" = "$b" ]
}

@test "complete length stops at the last newline, including long lines" {
  printf 'a\nbb\nccc' >"$T/f"
  [ "$(cs_complete_len "$T/f")" = 5 ]
  printf 'a\nbb\n' >"$T/f"
  [ "$(cs_complete_len "$T/f")" = 5 ]
  printf 'no newline' >"$T/f"
  [ "$(cs_complete_len "$T/f")" = 0 ]
  : >"$T/f"
  [ "$(cs_complete_len "$T/f")" = 0 ]
  { printf 'x\n'; head -c 300000 /dev/zero | tr '\0' 'y'; } >"$T/f"
  [ "$(cs_complete_len "$T/f")" = 2 ]
}

@test "transform verify compares line, CR and unparsable counts" {
  printf '%s\n' '{"a":1}' '{"cut' '{"b":2}' >"$T/in"
  printf '%s\n' '{"a":1}' '{"cut' '{"b":2}' >"$T/same"
  printf '%s\n' '{"a":1}' '{"cut' '{"b":2' >"$T/broken"
  printf '%s\n' '{"a":1}' '{"b":2}' >"$T/short"
  cs_transform_verify "$T/in" "$T/same"
  ! cs_transform_verify "$T/in" "$T/broken"
  ! cs_transform_verify "$T/in" "$T/short"
  [ "$(cs_transcript_stats "$T/in")" = "3 0 1" ]
}
