# shellcheck shell=bash
# wrapper: `claude-sync claude [args...]` (SPEC §17.4): bring this folder's project up to date, then exec claude.
# Never keeps Claude from opening for more than CS_WRAPPER_BUDGET seconds (default 60): offline, login required,
# a busy lock that does not clear, or a slow Drive all end in one warning line and Claude opens anyway.
# Requires core, platform, version, store, claude, transform, projects, ui, cmd_projects, status, pending.

[[ -n ${CS_WRAPPER_LOADED:-} ]] && return 0
CS_WRAPPER_LOADED=1

CS_WRAPPER_BUDGET=${CS_WRAPPER_BUDGET:-60}

# cs_wrapper_tty: rc 0 when we may ask the user (CS_WRAPPER_ASSUME_TTY=1 is for tests).
cs_wrapper_tty() {
  [[ ${CS_WRAPPER_ASSUME_TTY:-} == 1 ]] || { [[ -t 0 && -t 2 ]]; }
}

# cs_wrapper_ask_map CWD: if CWD is a candidate of a project that waits for a folder here, ask whether it is that
# project. y maps it (same checks as `projects map`), skip remembers the answer, anything else asks again next time.
cs_wrapper_ask_map() {
  local cwd=$1 kind key alias machines cands dec c path ans
  local -a cl
  [[ -f $CS_HOME/state/pending_map.tsv ]] || return 1
  while IFS=$'\t' read -r -u 7 kind key alias machines _ _ _ _ _ cands dec; do
    [[ $kind == remote && $dec == pending && $cands != - ]] || continue
    IFS=';' read -r -a cl <<<"$cands"
    for c in "${cl[@]}"; do
      path=${c%%|*}
      if ! { cs_path_under "$cwd" "$path" && cs_path_under "$path" "$cwd"; }; then continue; fi
      ans=$(cs_ask wrapper.ask_map "n" "$alias" "$machines")
      case ${ans,,} in
        y | yes | c | có)
          cs_pend_precheck "$cwd" || return 1
          cs_pend_apply remote "$key" "$alias" "$cwd" >/dev/null
          return $?
          ;;
        s | skip)
          cs_pend_decide remote "$key" skipped
          return 1
          ;;
      esac
      return 1
    done
  done 7< <(cs_tsv_rows pending_map)
  return 1
}

# cs_wrapper_pull PROJECT_ID: run --pull-only for the project, waiting for a busy lock, within the budget.
cs_wrapper_pull() {
  local pid=$1 start=$SECONDS rc left
  while :; do
    left=$((CS_WRAPPER_BUDGET - (SECONDS - start)))
    ((left > 0)) || {
      cs_say wrapper.timeout >&2
      return 124
    }
    rc=0
    timeout "$left" "$CS_APP_DIR/bin/claude-sync" run --pull-only --project "$pid" --trigger=wrapper || rc=$?
    if ((rc == CS_EXIT_BUSY)); then
      sleep 1
      continue
    fi
    break
  done
  case $rc in
    0) ;;
    "$CS_EXIT_LOGIN") cs_say wrapper.login >&2 ;;
    "$CS_EXIT_OFFLINE") cs_say wrapper.offline >&2 ;;
    124) cs_say wrapper.timeout >&2 ;;
    *) cs_say wrapper.failed "$rc" >&2 ;;
  esac
  return "$rc"
}

# cs_claude_wrapper ARGS...: never returns (exec), except when claude cannot be found.
cs_claude_wrapper() {
  local cwd pid='' claude
  claude=${CS_CLAUDE_BIN:-$(command -v claude || true)}
  [[ -n $claude ]] || cs_die_t 127 wrapper.no_claude
  cwd=${CS_WRAPPER_CWD:-$(cs_native_path "$PWD")} # CS_WRAPPER_CWD: tests
  pid=$(cs_project_of_cwd "$cwd" 2>/dev/null) || pid=''
  if [[ -z $pid ]] && cs_wrapper_tty && cs_wrapper_ask_map "$cwd"; then
    pid=$(cs_project_of_cwd "$cwd" 2>/dev/null) || pid=''
  fi
  if [[ -n $pid ]]; then cs_wrapper_pull "$pid" || true; fi
  exec "$claude" "$@"
}
