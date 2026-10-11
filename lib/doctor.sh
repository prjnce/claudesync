# shellcheck shell=bash
# doctor: `claude-sync doctor` (SPEC §20): what is wrong with this installation, one line per check
# (tag OK | INFO | WARN | FAIL). Exit 1 when anything is WARN or FAIL. The checks that need a finished setup
# (client, token, Drive root, service, hooks) only run once this machine has an identity.
# Requires core, platform, version, store, claude, drive, root, scheduler, hooks, ui (loaded by bin/claude-sync).

[[ -n ${CS_DOCTOR_LOADED:-} ]] && return 0
CS_DOCTOR_LOADED=1

# doctor_line TAG KEY [ARGS...]: "  TAG   message" (tags stay untranslated).
doctor_line() {
  local tag=$1
  shift
  printf '  %-5s %s\n' "$tag" "$(cs_t "$@")"
}

cs_doctor_service() {
  case ${CS_SCHED_KIND:-$CS_OS} in
    windows)
      if nat schtasks /Query /TN claude-sync >/dev/null 2>&1; then
        doctor_line OK doctor.service_task
      else
        doctor_line WARN doctor.service_missing
        return 1
      fi
      ;;
    *)
      if [[ ! -f $(cs_sched_unit_dir)/claude-sync.timer ]]; then
        doctor_line WARN doctor.service_missing
        return 1
      fi
      if cs_sched_systemd_ok; then
        if [[ $(systemctl --user is-active claude-sync.timer 2>/dev/null) == active ]]; then
          doctor_line OK doctor.service_timer
        else
          doctor_line WARN doctor.service_inactive
          return 1
        fi
      else
        doctor_line WARN doctor.no_systemd
        return 1
      fi
      ;;
  esac
  return 0
}

# cs_doctor_launcher: Windows only. Runs the launcher once against a child that exits with 7.
cs_doctor_launcher() {
  local l rc=0
  l=$(cs_sched_win_launcher)
  if [[ ! -f $l ]]; then
    if [[ -f $CS_HOME/bin/run-hidden.vbs ]]; then
      doctor_line INFO doctor.launcher_vbs
      return 0
    fi
    doctor_line WARN doctor.launcher_missing
    return 1
  fi
  MSYS2_ARG_CONV_EXCL='*' "$l" cmd.exe /c "exit 7" || rc=$?
  if ((rc == 7)); then
    doctor_line OK doctor.launcher_ok
  else
    doctor_line WARN doctor.launcher_bad "$rc"
    return 1
  fi
}

cs_doctor_hooks() {
  local f n
  f="$(cs_claude_dir)/settings.json"
  n=0
  [[ -f $f ]] && n=$(grep -c "$CS_HOOK_MARK" "$f" || true)
  if ((n >= 3)); then
    doctor_line OK doctor.hooks_ok
  else
    doctor_line WARN doctor.hooks_missing
    return 1
  fi
}

cs_doctor() {
  local problems=0 dir scan n dirs junk dups os=$CS_OS reason arg d days
  ((CS_WSL)) && os+=' (WSL)'
  cs_say doctor.title "$CS_VERSION"
  doctor_line OK doctor.env "$BASH_VERSION" "$CS_AWK" "$os"
  dir=$(cs_claude_dir)
  if [[ -d $dir ]]; then
    doctor_line OK doctor.claude_dir "$dir"
  else
    doctor_line FAIL doctor.claude_dir_missing "$dir"
    return 1
  fi
  scan=$(cs_claude_scan)
  n=$(printf '%s' "$scan" | grep -c . || true)
  dirs=$(printf '%s\n' "$scan" | "$CS_AWK" -F'\t' 'NF { d[$1] = 1 } END { print length(d) + 0 }')
  doctor_line OK doctor.sessions "$n" "$dirs"
  days=$(cs_claude_retention_days)
  doctor_line OK doctor.retention "$days"
  junk=$(cs_claude_junk_dirs)
  if [[ -n $junk ]]; then
    while IFS= read -r d; do doctor_line WARN doctor.junk_dir "$d"; done <<<"$junk"
    problems=1
  fi
  dups=$(printf '%s\n' "$scan" | cs_claude_dup_ids /dev/stdin)
  if [[ -n $dups ]]; then
    doctor_line WARN doctor.dup_ids "$(printf '%s\n' "$dups" | grep -c .)"
    problems=1
  fi
  if ! reason=$(cs_claude_layout_check); then
    IFS=$'\t' read -r reason arg <<<"$reason"
    doctor_line FAIL "$reason" "$arg"
    problems=1
  fi

  if [[ -z $(cs_config_get machine_id "") ]]; then
    doctor_line INFO doctor.not_set_up
  else
    doctor_line OK doctor.machine "$(cs_config_get machine_name "")"
    cs_owner_check || {
      doctor_line FAIL doctor.owner_conflict "$(cs_owner_file)"
      problems=1
    }
    if [[ -s $(cs_client_file) ]]; then doctor_line OK doctor.client; else
      doctor_line WARN doctor.no_client
      problems=1
    fi
    if cs_token_load >/dev/null 2>&1; then doctor_line OK doctor.token; else
      doctor_line WARN doctor.no_token
      problems=1
    fi
    if [[ -n $(cs_config_get root_id "") ]]; then
      if cs_root_check >/dev/null 2>&1; then doctor_line OK doctor.root; else
        doctor_line WARN doctor.root_bad
        problems=1
      fi
      n=$(cs_root_candidates 2>/dev/null | grep -c . || true)
      if ((n > 1)); then
        doctor_line WARN doctor.many_roots "$n"
        problems=1
      fi
    else
      doctor_line WARN doctor.no_root
      problems=1
    fi
    cs_doctor_service || problems=1
    if [[ ${CS_SCHED_KIND:-$CS_OS} == windows ]]; then cs_doctor_launcher || problems=1; fi
    cs_doctor_hooks || problems=1
    if [[ $days != 0 ]] && ((days < 3650)); then
      doctor_line WARN doctor.retention_low "$days"
      problems=1
    fi
  fi
  printf '\n'
  if ((problems)); then
    cs_say doctor.problems
    return 1
  fi
  cs_say doctor.ok
}
