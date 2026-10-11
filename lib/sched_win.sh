# shellcheck shell=bash
# sched_win: the Windows half of lib/scheduler.sh (SPEC §17.2): one Task Scheduler task "claude-sync" that starts a
# hidden launcher.exe (launcher/launcher.cs), with run-hidden.vbs as the fallback when the launcher is blocked.
# Sourced by scheduler.sh. Requires core, platform, store, ui.

[[ -n ${CS_SCHED_WIN_LOADED:-} ]] && return 0
CS_SCHED_WIN_LOADED=1

cs_sched_win_launcher() { printf '%s\n' "$CS_HOME/bin/launcher.exe"; }

# cs_sched_win_native PATH: Windows spelling of a Git Bash path (CS_SCHED_NATIVE_PREFIX=1 keeps it as is: tests).
cs_sched_win_native() {
  if [[ -n ${CS_SCHED_NATIVE_PREFIX:-} ]]; then
    printf '%s\n' "$1"
  elif command -v cygpath >/dev/null 2>&1; then
    cygpath -w -- "$1"
  else
    printf '%s\n' "$1"
  fi
}

# cs_sched_win_git_bash: <Git>\bin\bash.exe, never a bare "bash" (that one may be WSL's).
cs_sched_win_git_bash() {
  local root
  if [[ -n ${CS_SCHED_GIT_BASH:-} ]]; then
    printf '%s\n' "$CS_SCHED_GIT_BASH"
    return
  fi
  root=$(cygpath -w / 2>/dev/null) || root='C:\Program Files\Git'
  root=${root%\\}
  printf '%s\\bin\\bash.exe\n' "$root"
}

cs_sched_win_app() { # native path of the app directory
  if [[ -x $CS_HOME/app/bin/claude-sync ]]; then cs_sched_win_native "$CS_HOME/app"; else cs_sched_win_native "$CS_APP_DIR"; fi
}

cs_xml_escape() {
  local s=$1
  # a "&" in the replacement text means the matched text in newer bash: escape it
  s=${s//&/\&amp;}
  s=${s//</\&lt;}
  s=${s//>/\&gt;}
  s=${s//\"/\&quot;}
  printf '%s\n' "$s"
}

# cs_sched_win_command: "<launcher or wscript><TAB><arguments>" of the main action.
cs_sched_win_command() {
  local bash app
  bash=$(cs_sched_win_git_bash)
  app=$(cs_sched_win_app)
  if [[ -f $(cs_sched_win_launcher) ]]; then
    printf '%s\t"%s" --noprofile --norc "%s\\bin\\claude-sync" run --trigger=task\n' "$(cs_sched_win_native "$(cs_sched_win_launcher)")" "$bash" "$app"
  else
    printf 'wscript.exe\t"%s"\n' "$(cs_sched_win_native "$CS_HOME/bin/run-hidden.vbs")"
  fi
}

# cs_sched_win_vbs: run-hidden.vbs. It WAITS for the child (F4): Run(cmd, 0 = hidden, True = wait).
cs_sched_win_vbs() {
  local bash app
  bash=$(cs_sched_win_git_bash)
  app=$(cs_sched_win_app)
  printf 'Set sh = CreateObject("WScript.Shell")\r\n'
  printf 'rc = sh.Run("""%s"" --noprofile --norc ""%s\\bin\\claude-sync"" run --trigger=task", 0, True)\r\n' "$bash" "$app"
  printf 'WScript.Quit rc\r\n'
}

# cs_sched_win_task_xml MINUTES [USER]: the task definition as UTF-8 text (cs_sched_win_write_xml encodes it).
cs_sched_win_task_xml() {
  local iv=$1 user=${2:-} cmd args distro wuser
  [[ -n $user ]] || user="${USERDOMAIN:-$(hostname)}\\${USERNAME:-user}"
  IFS=$'\t' read -r cmd args <<<"$(cs_sched_win_command)"
  user=$(cs_xml_escape "$user")
  cat <<EOF
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>claude-sync periodic sync and catch-up</Description><URI>\\claude-sync</URI></RegistrationInfo>
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled><UserId>$user</UserId></LogonTrigger>
    <TimeTrigger>
      <Enabled>true</Enabled>
      <StartBoundary>2020-01-01T00:00:00</StartBoundary>
      <Repetition><Interval>PT${iv}M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
    </TimeTrigger>
    <EventTrigger><Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and (EventID=1)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
    <EventTrigger><Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[Provider[@Name='Microsoft-Windows-NetworkProfile'] and (EventID=10000)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$user</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Priority>7</Priority>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(cs_xml_escape "$cmd")</Command>
      <Arguments>$(cs_xml_escape "$args")</Arguments>
    </Exec>
EOF
  distro=$(cs_config_get wsl_distro "")
  if [[ -n $distro && -f $(cs_sched_win_launcher) ]]; then
    wuser=$(cs_config_get wsl_user "${USERNAME:-user}")
    cat <<EOF
    <Exec>
      <Command>$(cs_xml_escape "$(cs_sched_win_native "$(cs_sched_win_launcher)")")</Command>
      <Arguments>$(cs_xml_escape "wsl.exe -d $distro --exec /home/$wuser/.local/bin/claude-sync run --trigger=task")</Arguments>
    </Exec>
EOF
  fi
  cat <<'EOF'
  </Actions>
</Task>
EOF
}

# cs_sched_win_write_xml FILE MINUTES: UTF-16LE with a byte order mark (schtasks refuses anything else).
cs_sched_win_write_xml() {
  { printf '\xff\xfe'; cs_sched_win_task_xml "$2" | sed 's/$/\r/' | iconv -f UTF-8 -t UTF-16LE; } >"$1"
}

# cs_sched_win_build_launcher: compile launcher.exe with the .NET Framework's csc.exe; rc 1 if that is not possible.
cs_sched_win_build_launcher() {
  local csc src out
  csc="${WINDIR:-/c/Windows}/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
  [[ -x $csc ]] || csc=/c/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe
  src="$CS_APP_DIR/launcher/launcher.cs"
  out=$(cs_sched_win_launcher)
  [[ -x $csc && -f $src ]] || return 1
  mkdir -p -- "${out%/*}"
  # dash options: a "/target" argument would be taken for a POSIX path and converted
  MSYS2_ARG_CONV_EXCL='*' "$csc" -nologo -target:winexe -out:"$(cs_sched_win_native "$out")" "$(cs_sched_win_native "$src")" >/dev/null 2>&1 && [[ -f $out ]]
}

cs_sched_win_shim() {
  local shim="$HOME/bin/claude-sync" app
  app="$CS_HOME/app/bin/claude-sync"
  [[ -x $app ]] || app="$CS_APP_DIR/bin/claude-sync"
  mkdir -p -- "${shim%/*}"
  {
    printf '#!/usr/bin/env bash\n# claude-sync shim (written by claude-sync service install)\n'
    printf 'if [[ -x "%s/app/bin/claude-sync" ]]; then exec "%s/app/bin/claude-sync" "$@"; fi\n' "$CS_HOME" "$CS_HOME"
    printf 'exec "%s" "$@"\n' "$app"
  } >"$shim"
  chmod +x "$shim"
}

cs_sched_win_register() { # MINUTES
  local xml="$CS_HOME/bin/task.xml"
  mkdir -p -- "$CS_HOME/bin"
  cs_sched_win_write_xml "$xml" "$1"
  nat schtasks /Create /TN claude-sync /XML "$(cs_sched_win_native "$xml")" /F >/dev/null
}

cs_sched_win_install() {
  local interval
  interval=$(cs_config_get interval 5)
  mkdir -p -- "$CS_HOME/bin"
  if ! cs_sched_win_build_launcher; then
    cs_say service.launcher_fallback >&2
    cs_sched_win_vbs >"$CS_HOME/bin/run-hidden.vbs"
  fi
  cs_sched_win_shim
  cs_sched_win_register "$interval" || {
    cs_say service.register_failed >&2
    return 1
  }
  cs_say service.installed "$interval"
}

cs_sched_win_uninstall() {
  nat schtasks /Delete /TN claude-sync /F >/dev/null 2>&1 || true
  rm -f -- "$CS_HOME/bin/task.xml" "$CS_HOME/bin/run-hidden.vbs"
  if [[ -f $HOME/bin/claude-sync ]] && grep -q 'claude-sync shim' "$HOME/bin/claude-sync"; then rm -f -- "$HOME/bin/claude-sync"; fi
  cs_say service.removed
}

cs_sched_win_status() {
  nat schtasks /Query /TN claude-sync /FO LIST /V 2>/dev/null | tr -d '\r' | grep -E '^(Status|Next Run Time|Last Run Time|Last Result|Run As User):' || {
    cs_say service.not_installed
    return 1
  }
}

cs_sched_win_set_interval() {
  [[ -f $CS_HOME/bin/task.xml ]] || return 0
  cs_sched_win_register "$1"
}

cs_sched_win_kick() {
  if ! nat schtasks /Run /TN claude-sync >/dev/null 2>&1; then
    nohup "$CS_APP_DIR/bin/claude-sync" run --trigger=kick >/dev/null 2>&1 &
  fi
  return 0
}
