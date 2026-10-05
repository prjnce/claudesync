#!/usr/bin/env bats
# platform: nat, cc_slug, realpath, PID liveness, fd lock (ticket #06).

load test_helper

setup() {
  cs_test_setup
  cs_load platform
}

# --- cc_slug ---------------------------------------------------------------------------------

check_slug_vectors() {
  local expected input got n=0 bad=0
  while IFS=$'\t' read -r expected input; do
    n=$((n + 1))
    got=$(cc_slug "$input")
    if [[ $got != "$expected" ]]; then
      printf 'MISMATCH #%d input=[%s]\n  want=%s\n  got =%s\n' "$n" "$input" "$expected" "$got"
      bad=$((bad + 1))
    fi
  done <"$CS_ROOT/test/fixtures/slug_vectors.tsv"
  [ "$n" -eq 22 ]
  [ "$bad" -eq 0 ]
}

@test "cc_slug matches the Claude Code oracle on all 22 vectors (LC_ALL=C)" {
  check_slug_vectors
}

@test "cc_slug is locale independent (POSIX, C.UTF-8)" {
  LC_ALL=POSIX check_slug_vectors
  LC_ALL=C.UTF-8 check_slug_vectors
}

@test "cc_slug: Windows drive letter case gives different slugs (d: vs D:)" {
  [ "$(cc_slug 'd:\Projects\x')" = d--Projects-x ]
  [ "$(cc_slug 'D:\Projects\x')" = D--Projects-x ]
}

# --- nat ---------------------------------------------------------------------------------------

@test "nat refuses unconverted rooted POSIX paths" {
  run cs_nat_check_args /c/Users/x
  [ "$status" -eq 2 ]
  run cs_nat_check_args --file=/tmp/a/b
  [ "$status" -eq 2 ]
  run cs_nat_check_args /home/u/x
  [ "$status" -eq 2 ]
}

@test "nat accepts Windows paths, single-component switches and URLs" {
  cs_nat_check_args C:/Users/x 'C:\Users\x' /TN /Create /F '\claude-sync' https://www.googleapis.com/drive/v3/files -H 'a: b'
}

@test "nat passes switches to native exes without MSYS conversion" {
  cs_is_windows || skip "Windows only"
  run nat cmd.exe /d /c echo /TN
  [ "$(printf '%s' "$output" | tr -d '\r')" = /TN ]
}

@test "cs_to_win converts in one call and keeps order" {
  run cs_to_win "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b c"
  [ "${#lines[@]}" -eq 2 ]
  if cs_is_windows; then
    [[ ${lines[0]} == [A-Za-z]:/*/a ]]
    [[ ${lines[1]} == [A-Za-z]:/*/b\ c ]]
  else
    [ "${lines[0]}" = "$BATS_TEST_TMPDIR/a" ]
  fi
}

# --- realpath ----------------------------------------------------------------------------------

@test "realpath resolves symlinks (Linux) or true case (Windows) and flags missing paths" {
  mkdir -p "$BATS_TEST_TMPDIR/CaseDir/sub"
  if cs_is_windows; then
    run cs_realpath_disk "$BATS_TEST_TMPDIR/casedir/SUB" "$BATS_TEST_TMPDIR/missing"
    [ "$status" -eq 1 ]
    [ "${#lines[@]}" -eq 1 ] || [ "${#lines[@]}" -eq 2 ]
    [[ ${lines[0]} == [A-Za-z]:\\*\\CaseDir\\sub ]]
  else
    ln -s "$BATS_TEST_TMPDIR/CaseDir" "$BATS_TEST_TMPDIR/link"
    run cs_realpath_disk "$BATS_TEST_TMPDIR/link/sub" "$BATS_TEST_TMPDIR/missing"
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "$(cd "$BATS_TEST_TMPDIR/CaseDir/sub" && pwd -P)" ]
  fi
}

@test "realpath keeps one output line per input even when the last one is missing" {
  mkdir -p "$BATS_TEST_TMPDIR/x"
  out=$(cs_realpath_disk "$BATS_TEST_TMPDIR/missing1" "$BATS_TEST_TMPDIR/x" "$BATS_TEST_TMPDIR/missing2"; printf 'END')
  [ "$(printf '%s' "$out" | wc -l)" -eq 3 ]
}

# --- PID liveness -------------------------------------------------------------------------------

native_pid() { # MSYS pid -> native pid on Windows
  if cs_is_windows; then cat "/proc/$1/winpid"; else printf '%s\n' "$1"; fi
}

@test "pid_alive: running process is alive, killed process and bogus pids are not" {
  sleep 30 3>&- &
  local spid=$! npid
  npid=$(native_pid "$spid")
  cs_pid_alive "$npid"
  cs_live_pids | grep -qx "$npid"
  kill "$spid"
  wait "$spid" 2>/dev/null || true
  ! cs_pid_alive "$npid"
  ! cs_pid_alive 4294967
  ! cs_pid_alive abc
}

@test "proc start id is stable for a live process and absent for a dead one" {
  sleep 30 3>&- &
  local spid=$! npid a b
  npid=$(native_pid "$spid")
  a=$(cs_proc_start_ids "$npid")
  b=$(cs_proc_start_ids "$npid")
  [[ $a == "$npid"$'\t'?* ]]
  [ "$a" = "$b" ]
  kill "$spid"
  wait "$spid" 2>/dev/null || true
  [ -z "$(cs_proc_start_ids "$npid")" ]
}

# --- fd lock -------------------------------------------------------------------------------------

@test "lock: 20 contenders x 5 increments = 100 (no lost update)" {
  local lockf="$BATS_TEST_TMPDIR/sync.lock" counter="$BATS_TEST_TMPDIR/counter" i pids=()
  printf 0 >"$counter"
  for i in $(seq 1 20); do
    (
      for _ in 1 2 3 4 5; do
        (
          cs_lock_acquire "$lockf" 60 || exit 9
          n=$(<"$counter")
          printf '%d' $((n + 1)) >"$counter"
        )
      done
    ) 3>&- &
    pids+=($!)
  done
  for i in "${pids[@]}"; do wait "$i"; done
  [ "$(<"$counter")" -eq 100 ]
}

@test "lock: second taker is refused without waiting, accepted after the holder exits" {
  local lockf="$BATS_TEST_TMPDIR/sync.lock"
  (
    cs_lock_acquire "$lockf"
    sleep 2
  ) 3>&- &
  local holder=$!
  sleep 0.7
  run bash -c 'source "$CS_ROOT/lib/core.sh"; source "$CS_ROOT/lib/platform.sh"; cs_lock_acquire "$1"' _ "$lockf"
  [ "$status" -eq 1 ]
  wait "$holder"
  run bash -c 'source "$CS_ROOT/lib/core.sh"; source "$CS_ROOT/lib/platform.sh"; cs_lock_acquire "$1"' _ "$lockf"
  [ "$status" -eq 0 ]
}

@test "lock: waiting taker gets the lock once the holder releases it" {
  local lockf="$BATS_TEST_TMPDIR/sync.lock"
  (
    cs_lock_acquire "$lockf"
    sleep 1
  ) 3>&- &
  sleep 0.5
  run bash -c 'source "$CS_ROOT/lib/core.sh"; source "$CS_ROOT/lib/platform.sh"; cs_lock_acquire "$1" 10' _ "$lockf"
  [ "$status" -eq 0 ]
}

@test "lock: kill -9 of the holder frees the lock (F3: no stale lock after sleep/crash)" {
  local lockf="$BATS_TEST_TMPDIR/sync.lock"
  (
    cs_lock_acquire "$lockf"
    sleep 30 9>&- # child does not inherit the lock
  ) >/dev/null 2>&1 3>&- &
  local holder=$!
  sleep 0.7
  kill -9 "$holder"
  wait "$holder" 2>/dev/null || true
  run bash -c 'source "$CS_ROOT/lib/core.sh"; source "$CS_ROOT/lib/platform.sh"; cs_lock_acquire "$1"' _ "$lockf"
  [ "$status" -eq 0 ]
}
