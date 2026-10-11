#!/usr/bin/env bats
# Linux scheduling (ticket #25): units, config interval, kick. systemctl and loginctl are stubs that log their calls.

load test_helper

setup() {
  cs_test_setup
  export CS_SCHED_KIND=linux
  STUBS="$BATS_TEST_TMPDIR/stubs"
  CALLS="$BATS_TEST_TMPDIR/calls.log"
  mkdir -p "$STUBS" "$HOME/.config"
  : >"$CALLS"
  cat >"$STUBS/systemctl" <<'EOS'
#!/usr/bin/env bash
echo "systemctl $*" >>"$CALLS"
[[ $1 == --user && $2 == show-environment ]] && exit "${STUB_SYSTEMD_RC:-0}"
if [[ $* == *"start "* && $* != *--no-block* ]]; then sleep 4; fi
exit 0
EOS
  cat >"$STUBS/loginctl" <<'EOS'
#!/usr/bin/env bash
echo "loginctl $*" >>"$CALLS"
exit "${STUB_LINGER_RC:-0}"
EOS
  cat >"$STUBS/sudo" <<'EOS'
#!/usr/bin/env bash
echo "sudo $*" >>"$CALLS"
exit 0
EOS
  chmod +x "$STUBS"/*
  export PATH="$STUBS:$PATH" CALLS
  export USER=tester
}

svc() { bash "$CS_ROOT/bin/claude-sync" service "$@"; }

@test "install writes the units of SPEC 17.1, the shim, and enables the timer and linger" {
  run svc install
  [ "$status" -eq 0 ]
  d="$HOME/.config/systemd/user"
  grep -qx 'ExecStart=%h/.local/bin/claude-sync run --trigger=timer' "$d/claude-sync.service"
  grep -qx 'Type=oneshot' "$d/claude-sync.service"
  grep -qx 'TimeoutStartSec=600' "$d/claude-sync.service"
  grep -qx 'Nice=10' "$d/claude-sync.service"
  grep -qx 'IOSchedulingClass=idle' "$d/claude-sync.service"
  grep -qx 'Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus' "$d/claude-sync.service"
  grep -qxF 'OnCalendar=*:0/5' "$d/claude-sync.timer"
  grep -qx 'Persistent=true' "$d/claude-sync.timer"
  grep -qx 'OnStartupSec=30' "$d/claude-sync.timer"
  grep -qx 'AccuracySec=30s' "$d/claude-sync.timer"
  grep -qx 'WantedBy=timers.target' "$d/claude-sync.timer"
  [ -x "$HOME/.local/bin/claude-sync" ]
  grep -q 'systemctl --user daemon-reload' "$CALLS"
  grep -q 'systemctl --user enable --now claude-sync.timer' "$CALLS"
  grep -q 'loginctl enable-linger tester' "$CALLS"
}

@test "config set interval 10 rewrites the OnCalendar line and reloads; bad values are refused" {
  svc install >/dev/null
  : >"$CALLS"
  run bash "$CS_ROOT/bin/claude-sync" config set interval 10
  [ "$status" -eq 0 ]
  grep -qxF 'OnCalendar=*:0/10' "$HOME/.config/systemd/user/claude-sync.timer"
  [ "$(grep -c 'OnCalendar' "$HOME/.config/systemd/user/claude-sync.timer")" -eq 1 ]
  grep -q 'daemon-reload' "$CALLS"
  grep -q 'restart claude-sync.timer' "$CALLS"
  run bash "$CS_ROOT/bin/claude-sync" config set interval 7
  [ "$status" -eq 2 ]
  run bash "$CS_ROOT/bin/claude-sync" config get interval
  [ "$output" = 10 ]
}

@test "kick returns at once, does not wait for a running service, and leaves the pending mark (F10)" {
  svc install >/dev/null
  start=$SECONDS
  run bash "$CS_ROOT/bin/claude-sync" kick
  [ "$status" -eq 0 ]
  ((SECONDS - start < 2))
  [ -e "$CLAUDE_SYNC_HOME/pending" ]
  grep -q 'start --no-block claude-sync.service' "$CALLS"
}

@test "uninstall removes the units and the shim" {
  svc install >/dev/null
  run svc uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.config/systemd/user/claude-sync.timer" ]
  [ ! -e "$HOME/.config/systemd/user/claude-sync.service" ]
  [ ! -e "$HOME/.local/bin/claude-sync" ]
  grep -q 'disable --now claude-sync.timer' "$CALLS"
}

@test "polkit refuses linger: the answer decides whether sudo is used" {
  STUB_LINGER_RC=1 run bash -c 'printf "n
" | bash "$CS_ROOT/bin/claude-sync" service install'
  [ "$status" -eq 0 ]
  ! grep -q '^sudo' "$CALLS"
  : >"$CALLS"
  STUB_LINGER_RC=1 run bash -c 'printf "y
" | bash "$CS_ROOT/bin/claude-sync" service install'
  grep -q 'sudo loginctl enable-linger tester' "$CALLS"
}

@test "without a systemd user instance nothing is installed (no cron) and the exit code says so" {
  STUB_SYSTEMD_RC=1 run svc install
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.config/systemd/user/claude-sync.timer" ]
  [ ! -e "$HOME/.config/cron" ]
  ! grep -q 'enable' "$CALLS"
}

@test "service status reports the interval and the timer state" {
  svc install >/dev/null
  run svc status
  [ "$status" -eq 0 ]
  [[ $output == *'every 5 min'* ]]
}

@test "a kick during a run makes the engine run one more cycle; without a kick it runs one" {
  run bash -c '
    source "$CS_ROOT/lib/core.sh"; cs_bootstrap
    for m in platform version manifest store claude transform projects drive root status engine; do source "$CS_ROOT/lib/$m.sh"; done
    mkdir -p "$CLAUDE_SYNC_HOME"
    n=0
    cs_run_cycle() { n=$((n + 1)); if [[ $n == 1 && ${KICK:-} == 1 ]]; then sleep 0.1; : >"$CS_HOME/pending"; fi; return 0; }
    cs_run
    echo "cycles=$n"'
  [[ $output == *cycles=1* ]]
  KICK=1 run bash -c '
    source "$CS_ROOT/lib/core.sh"; cs_bootstrap
    for m in platform version manifest store claude transform projects drive root status engine; do source "$CS_ROOT/lib/$m.sh"; done
    mkdir -p "$CLAUDE_SYNC_HOME"
    n=0
    cs_run_cycle() { n=$((n + 1)); if [[ $n == 1 && ${KICK:-} == 1 ]]; then sleep 0.1; : >"$CS_HOME/pending"; fi; return 0; }
    cs_run
    echo "cycles=$n"'
  [[ $output == *cycles=2* ]]
}
