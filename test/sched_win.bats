#!/usr/bin/env bats
# Windows scheduling (ticket #26): task XML, UTF-16LE BOM, install/uninstall/kick against a stub schtasks, and the
# real launcher.exe on Windows hosts.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  cs_test_setup
  export CS_SCHED_KIND=windows CS_SCHED_NATIVE_PREFIX=1 CS_SCHED_GIT_BASH='C:\Program Files\Git\bin\bash.exe'
  export USERDOMAIN=PC USERNAME=tester
  STUBS="$BATS_TEST_TMPDIR/stubs"
  CALLS="$BATS_TEST_TMPDIR/calls.log"
  mkdir -p "$STUBS" "$CLAUDE_SYNC_HOME/bin"
  : >"$CALLS"
  printf '#!/usr/bin/env bash\necho "schtasks $*" >>"$CALLS"\nexit "${STUB_SCHTASKS_RC:-0}"\n' >"$STUBS/schtasks"
  chmod +x "$STUBS/schtasks"
  export PATH="$STUBS:$PATH" CALLS
}

cs_native_for_python() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi; }

# xml MINUTES: the task XML as text, through the real functions.
xml() {
  bash -c 'source "$CS_ROOT/lib/core.sh"; cs_bootstrap; source "$CS_ROOT/lib/platform.sh"; source "$CS_ROOT/lib/store.sh"
    CS_APP_DIR=$CS_ROOT; source "$CS_ROOT/lib/ui.sh"; source "$CS_ROOT/lib/scheduler.sh"; cs_sched_win_task_xml "$1"' _ "$1"
}

@test "task XML: one task, user principal with InteractiveToken, the triggers and settings of SPEC 17.2" {
  : >"$CLAUDE_SYNC_HOME/bin/launcher.exe"
  run xml 5
  [ "$status" -eq 0 ]
  [[ $output == *'<LogonType>InteractiveToken</LogonType>'* ]]
  [[ $output == *'<RunLevel>LeastPrivilege</RunLevel>'* ]]
  [[ $output == *'<LogonTrigger>'* ]]
  [[ $output == *'<Interval>PT5M</Interval>'* ]]
  [[ $output == *'Microsoft-Windows-Power-Troubleshooter'* ]]
  [[ $output == *'<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>'* ]]
  [[ $output == *'<StartWhenAvailable>true</StartWhenAvailable>'* ]]
  [[ $output == *'<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'* ]]
  [[ $output == *'<ExecutionTimeLimit>PT10M</ExecutionTimeLimit>'* ]]
  [[ $output != *BootTrigger* ]]
  [[ $output == *'launcher.exe</Command>'* ]]
  [[ $output == *'&quot;C:\Program Files\Git\bin\bash.exe&quot; --noprofile --norc'* ]]
  [[ $output == *'run --trigger=task'* ]]
  run xml 10
  [[ $output == *'<Interval>PT10M</Interval>'* ]]
  run xml 7
  [[ $output == *'<Interval>PT7M</Interval>'* ]]
  [[ $output != *'PT5M</Interval>'* ]]
}

@test "the written file is UTF-16LE with a BOM and well-formed XML" {
  : >"$CLAUDE_SYNC_HOME/bin/launcher.exe"
  bash -c 'source "$CS_ROOT/lib/core.sh"; cs_bootstrap; source "$CS_ROOT/lib/platform.sh"; source "$CS_ROOT/lib/store.sh"
    CS_APP_DIR=$CS_ROOT; source "$CS_ROOT/lib/ui.sh"; source "$CS_ROOT/lib/scheduler.sh"; cs_sched_win_write_xml "$1" 10' _ "$BATS_TEST_TMPDIR/task.xml"
  [ "$(head -c 2 "$BATS_TEST_TMPDIR/task.xml" | od -An -tx1 | tr -d ' ')" = fffe ]
  iconv -f UTF-16 -t UTF-8 "$BATS_TEST_TMPDIR/task.xml" | grep -q 'PT10M'
  if command -v python3 >/dev/null 2>&1; then
    # parse the UTF-16 file itself, as schtasks will read it
    python3 -c 'import sys, xml.dom.minidom as m; m.parse(sys.argv[1])' "$(cs_native_for_python "$BATS_TEST_TMPDIR/task.xml")"
  fi
}

@test "without a launcher the action is wscript + run-hidden.vbs, which waits for the child" {
  run xml 5
  [[ $output == *'<Command>wscript.exe</Command>'* ]]
  [[ $output == *'run-hidden.vbs'* ]]
  run bash -c 'source "$CS_ROOT/lib/core.sh"; cs_bootstrap; source "$CS_ROOT/lib/platform.sh"; source "$CS_ROOT/lib/store.sh"
    CS_APP_DIR=$CS_ROOT; source "$CS_ROOT/lib/ui.sh"; source "$CS_ROOT/lib/scheduler.sh"; cs_sched_win_vbs'
  [[ $output == *'sh.Run('* && $output == *', 0, True)'* && $output == *'WScript.Quit rc'* ]]
}

@test "a configured WSL distro adds a second action" {
  : >"$CLAUDE_SYNC_HOME/bin/launcher.exe"
  bash "$CS_ROOT/bin/claude-sync" config set wsl_distro Ubuntu2404 >/dev/null
  bash "$CS_ROOT/bin/claude-sync" config set wsl_user frank >/dev/null
  run xml 5
  [ "$(grep -c '<Exec>' <<<"$output")" -eq 2 ]
  [[ $output == *'wsl.exe -d Ubuntu2404 --exec /home/frank/.local/bin/claude-sync run --trigger=task'* ]]
}

@test "service install registers the task with schtasks /XML; interval change re-registers; uninstall removes the task and keeps the data" {
  unset CS_SCHED_NATIVE_PREFIX
  mkdir -p "$CLAUDE_SYNC_HOME/state"
  : >"$CLAUDE_SYNC_HOME/state/keep.me"
  run bash "$CS_ROOT/bin/claude-sync" service install
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q 'schtasks /Create /TN claude-sync /XML .*task.xml /F' "$CALLS"
  [ -f "$CLAUDE_SYNC_HOME/bin/task.xml" ]
  [ "$(head -c 2 "$CLAUDE_SYNC_HOME/bin/task.xml" | od -An -tx1 | tr -d ' ')" = fffe ]
  [ -x "$HOME/bin/claude-sync" ]
  : >"$CALLS"
  bash "$CS_ROOT/bin/claude-sync" config set interval 10 >/dev/null
  grep -q 'schtasks /Create' "$CALLS"
  iconv -f UTF-16 -t UTF-8 "$CLAUDE_SYNC_HOME/bin/task.xml" | grep -q 'PT10M'
  : >"$CALLS"
  run bash "$CS_ROOT/bin/claude-sync" service uninstall
  [ "$status" -eq 0 ]
  grep -q 'schtasks /Delete /TN claude-sync /F' "$CALLS"
  [ ! -e "$CLAUDE_SYNC_HOME/bin/task.xml" ]
  [ -e "$CLAUDE_SYNC_HOME/state/keep.me" ]
}

@test "kick touches pending and runs the task, returning at once" {
  start=$SECONDS
  run bash "$CS_ROOT/bin/claude-sync" kick
  [ "$status" -eq 0 ]
  ((SECONDS - start < 3))
  [ -e "$CLAUDE_SYNC_HOME/pending" ]
  grep -q 'schtasks /Run /TN claude-sync' "$CALLS"
}

@test "entrypoint started by a Windows path with backslashes finds its app dir from any cwd" {
  cs_is_windows || skip "Windows only"
  cd "$BATS_TEST_TMPDIR"
  run bash "$(cygpath -w "$CS_ROOT/bin/claude-sync")" --version
  [ "$status" -eq 0 ]
  [[ $output != *"No such file"* ]]
}

@test "md5sum of a file works under launcher.exe once cs_fix_stdin has run" {
  cs_is_windows || skip "Windows only"
  CS_APP_DIR=$CS_ROOT
  run bash -c 'source "$CS_ROOT/lib/core.sh"; cs_bootstrap; source "$CS_ROOT/lib/platform.sh"; source "$CS_ROOT/lib/store.sh"
    CS_APP_DIR=$CS_ROOT; source "$CS_ROOT/lib/ui.sh"; source "$CS_ROOT/lib/scheduler.sh"; unset CS_SCHED_NATIVE_PREFIX; cs_sched_win_build_launcher'
  [ "$status" -eq 0 ]
  L="$CLAUDE_SYNC_HOME/bin/launcher.exe"
  export MSYS2_ARG_CONV_EXCL='*'
  printf 'hello\n' >"$BATS_TEST_TMPDIR/data"
  # the launcher passes its command line through raw (no single-quote handling): use a script file
  cat >"$BATS_TEST_TMPDIR/probe.sh" <<'EOF'
source "$1/lib/core.sh"
cs_fix_stdin
md5sum -- "$2" >"$3" 2>&1
EOF
  run "$L" "$(cygpath -w "$(command -v bash)")" --noprofile --norc "$BATS_TEST_TMPDIR/probe.sh" "$CS_ROOT" "$BATS_TEST_TMPDIR/data" "$BATS_TEST_TMPDIR/after"
  grep -q 'b1946ac92492d2347c6235b4d2611184' "$BATS_TEST_TMPDIR/after"
}

@test "launcher.exe: runs hidden, waits, returns the child's exit code, prints real paths" {
  cs_is_windows || skip "Windows only"
  CS_APP_DIR=$CS_ROOT
  run bash -c 'source "$CS_ROOT/lib/core.sh"; cs_bootstrap; source "$CS_ROOT/lib/platform.sh"; source "$CS_ROOT/lib/store.sh"
    CS_APP_DIR=$CS_ROOT; source "$CS_ROOT/lib/ui.sh"; source "$CS_ROOT/lib/scheduler.sh"; unset CS_SCHED_NATIVE_PREFIX; cs_sched_win_build_launcher'
  [ "$status" -eq 0 ]
  L="$CLAUDE_SYNC_HOME/bin/launcher.exe"
  export MSYS2_ARG_CONV_EXCL='*'
  run "$L" cmd.exe /c "exit 7"
  [ "$status" -eq 7 ]
  start=$SECONDS
  run "$L" cmd.exe /c "ping -n 3 127.0.0.1 >nul"
  [ "$status" -eq 0 ]
  ((SECONDS - start >= 1))
  run "$L" realpath 'C:\Windows'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | tr -d '\r')" = 'C:\Windows' ]
  run -127 "$L" nosuchprogram.exe
}
