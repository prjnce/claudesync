# shellcheck shell=bash
# scheduler: the service that runs `claude-sync run` by itself, and kick (SPEC §17).
#   Linux/WSL: systemd user units (this file). Windows: Task Scheduler + launcher.exe (ticket #26: cs_sched_win_*).
# kick = touch $CS_HOME/pending, then start the service without waiting; the engine runs one more cycle when
# `pending` is newer than the cycle it is in (cs_run).
# Requires core, platform, store (for CS_HOME).

[[ -n ${CS_SCHEDULER_LOADED:-} ]] && return 0
CS_SCHEDULER_LOADED=1

cs_sched_unit_dir() { printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"; }
cs_sched_shim_path() { printf '%s\n' "$HOME/.local/bin/claude-sync"; }

cs_sched_service_text() {
  cat <<'EOF'
[Unit]
Description=claude-sync one-shot run

[Service]
Type=oneshot
ExecStart=%h/.local/bin/claude-sync run --trigger=timer
TimeoutStartSec=600
Nice=10
IOSchedulingClass=idle
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus
EOF
}

# cs_sched_timer_text MINUTES (1..1440): a calendar line when MINUTES divides an hour evenly (so runs fall on the
# same minutes every hour and Persistent= catches up after power-off), else a fixed delay after the last run.
cs_sched_timer_text() {
  local n=$1 sched persistent=''
  if ((n <= 60 && 60 % n == 0)); then
    sched="OnCalendar=*:0/$n"
    persistent='Persistent=true'
  else
    sched="OnUnitActiveSec=${n}min"
  fi
  cat <<EOF
# claude-sync interval=$n
[Unit]
Description=claude-sync every $n min (catch-up after power-off/suspend)

[Timer]
$sched
${persistent:+$persistent
}OnStartupSec=30
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
}

# cs_interval_ok VALUE: rc 0 for a whole number of minutes from 1 to 1440.
cs_interval_ok() {
  [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 1440))
}

# cs_sched_systemd_ok: a systemd user instance is reachable (not in a container or a WSL without systemd).
cs_sched_systemd_ok() {
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

# cs_sched_shim_install: ~/.local/bin/claude-sync starts the installed app (or the app we run from).
cs_sched_shim_install() {
  local shim app
  shim=$(cs_sched_shim_path)
  app="$CS_HOME/app/bin/claude-sync"
  [[ -x $app ]] || app="$CS_APP_DIR/bin/claude-sync"
  mkdir -p -- "${shim%/*}"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# claude-sync shim (written by claude-sync service install)\n'
    printf 'if [[ -x "%s/app/bin/claude-sync" ]]; then exec "%s/app/bin/claude-sync" "$@"; fi\n' "$CS_HOME" "$CS_HOME"
    printf 'exec "%s" "$@"\n' "$app"
  } >"$shim"
  chmod +x "$shim"
}

cs_sched_linger() {
  command -v loginctl >/dev/null 2>&1 || return 0
  loginctl enable-linger "$USER" >/dev/null 2>&1 && return 0
  # polkit refused: ask before using sudo (SPEC §17.1)
  if cs_confirm service.ask_sudo n; then
    sudo loginctl enable-linger "$USER" || cs_say service.linger_failed >&2
  else
    cs_say service.linger_failed >&2
  fi
}

cs_sched_install() {
  local d interval
  case ${CS_SCHED_KIND:-$CS_OS} in
    windows)
      declare -F cs_sched_win_install >/dev/null || cs_die_t "$CS_EXIT_ERROR" cli.not_implemented "service install (Windows)"
      cs_sched_win_install
      return
      ;;
  esac
  cs_sched_systemd_ok || {
    cs_say service.no_systemd >&2
    return 1
  }
  d=$(cs_sched_unit_dir)
  interval=$(cs_config_get interval 5)
  mkdir -p -- "$d"
  cs_sched_service_text >"$d/claude-sync.service"
  cs_sched_timer_text "$interval" >"$d/claude-sync.timer"
  cs_sched_shim_install
  systemctl --user daemon-reload || return
  systemctl --user enable --now claude-sync.timer || return
  cs_sched_linger
  cs_say service.installed "$interval"
}

cs_sched_uninstall() {
  local d shim
  case ${CS_SCHED_KIND:-$CS_OS} in
    windows)
      declare -F cs_sched_win_uninstall >/dev/null || cs_die_t "$CS_EXIT_ERROR" cli.not_implemented "service uninstall (Windows)"
      cs_sched_win_uninstall
      return
      ;;
  esac
  d=$(cs_sched_unit_dir)
  if cs_sched_systemd_ok; then
    systemctl --user disable --now claude-sync.timer >/dev/null 2>&1 || true
  fi
  rm -f -- "$d/claude-sync.service" "$d/claude-sync.timer"
  cs_sched_systemd_ok && systemctl --user daemon-reload >/dev/null 2>&1
  shim=$(cs_sched_shim_path)
  if [[ -f $shim ]] && grep -q 'claude-sync shim' "$shim"; then rm -f -- "$shim"; fi
  cs_say service.removed
  return 0
}

cs_sched_status() {
  local d
  case ${CS_SCHED_KIND:-$CS_OS} in
    windows)
      declare -F cs_sched_win_status >/dev/null || cs_die_t "$CS_EXIT_ERROR" cli.not_implemented "service status (Windows)"
      cs_sched_win_status
      return
      ;;
  esac
  d=$(cs_sched_unit_dir)
  if [[ ! -f $d/claude-sync.timer ]]; then
    cs_say service.not_installed
    return 1
  fi
  if ! cs_sched_systemd_ok; then
    cs_say service.no_systemd >&2
    return 1
  fi
  cs_say service.interval "$(sed -n 's/^# claude-sync interval=//p' "$d/claude-sync.timer")"
  cs_say service.timer_state "$(systemctl --user is-active claude-sync.timer 2>/dev/null || echo inactive)" \
    "$(systemctl --user is-enabled claude-sync.timer 2>/dev/null || echo disabled)"
  systemctl --user list-timers claude-sync.timer --no-pager 2>/dev/null | sed -n '1,2p'
  return 0
}

# cs_sched_set_interval MINUTES: rewrite the timer and reload (no-op when the service is not installed).
cs_sched_set_interval() {
  local d
  d=$(cs_sched_unit_dir)
  case ${CS_SCHED_KIND:-$CS_OS} in
    windows)
      declare -F cs_sched_win_set_interval >/dev/null && cs_sched_win_set_interval "$1"
      return 0
      ;;
  esac
  [[ -f $d/claude-sync.timer ]] || return 0
  cs_sched_timer_text "$1" >"$d/claude-sync.timer"
  if cs_sched_systemd_ok; then
    systemctl --user daemon-reload || return
    systemctl --user restart claude-sync.timer || return
  fi
  return 0
}

# cs_kick: wake the service without waiting for it (F10).
cs_kick() {
  mkdir -p -- "$CS_HOME"
  : >"$CS_HOME/pending"
  case ${CS_SCHED_KIND:-$CS_OS} in
    windows)
      if declare -F cs_sched_win_kick >/dev/null; then
        cs_sched_win_kick
      else
        nohup "$CS_APP_DIR/bin/claude-sync" run --trigger=kick >/dev/null 2>&1 &
      fi
      ;;
    *)
      if cs_sched_systemd_ok && [[ -f $(cs_sched_unit_dir)/claude-sync.service ]]; then
        systemctl --user start --no-block claude-sync.service >/dev/null 2>&1 || true
      else
        # No service (container, WSL without systemd): run once in the background; the lock keeps it single.
        nohup "$CS_APP_DIR/bin/claude-sync" run --trigger=kick >/dev/null 2>&1 &
      fi
      ;;
  esac
  return 0
}

# cs_service CMD: the `service` command.
cs_service() {
  local sub=${1:-status}
  case $sub in
    install) cs_sched_install ;;
    uninstall) cs_sched_uninstall ;;
    status) cs_sched_status ;;
    kick) cs_kick ;;
    *) cs_die_t "$CS_EXIT_USAGE" service.usage ;;
  esac
}

# shellcheck source=lib/sched_win.sh
source "${BASH_SOURCE[0]%/*}/sched_win.sh"
