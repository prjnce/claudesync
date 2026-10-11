# shellcheck shell=bash
# hooks: Claude Code hooks (SPEC §18): `hooks install|uninstall` edit settings.json; `hook session-start` and
# `hook prompt-guard` are the handlers Claude runs. Handlers read only local state (status.json, pending_map.tsv):
# no network, so they stay under their 2 s timeout. Every command line we write ends with the marker #claude-sync,
# which is what uninstall (and a second install) looks for; entries of other tools are never touched.
# Requires core, platform, version, store, claude, projects, status, scheduler.

[[ -n ${CS_HOOKS_LOADED:-} ]] && return 0
CS_HOOKS_LOADED=1

CS_HOOK_MARK='#claude-sync'

# The three entries: "event<TAB>matcher<TAB>timeout<TAB>command".
cs_hooks_entries() {
  local guard='command -v claude-sync >/dev/null 2>&1 && claude-sync hook'
  printf 'SessionStart\tstartup|resume\t2\t%s session-start; exit 0 %s\n' "$guard" "$CS_HOOK_MARK"
  printf 'UserPromptSubmit\t-\t2\t%s prompt-guard; r=$?; [ "$r" = 2 ] && exit 2; exit 0 %s\n' "$guard" "$CS_HOOK_MARK"
  printf 'SessionEnd\t-\t5\tcommand -v claude-sync >/dev/null 2>&1 && { nohup claude-sync kick >/dev/null 2>&1 & }; exit 0 %s\n' "$CS_HOOK_MARK"
}

# cs_hooks_apply FILTER [JQ_ARGS...]: settings.json through a jq filter, after a backup; atomic, no CR.
cs_hooks_apply() {
  local f ts filter=$1
  shift
  f="$(cs_claude_dir)/settings.json"
  mkdir -p -- "${f%/*}" "$CS_HOME/backups"
  if [[ -f $f ]]; then
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 || cs_die_t "$CS_EXIT_ERROR" settings.not_object "$f"
    TZ=UTC printf -v ts '%(%Y%m%dT%H%M%SZ)T' -1
    cp -p -- "$f" "$CS_HOME/backups/settings.json.$ts.$$"
  else
    printf '{}\n' >"$f"
  fi
  cs_write_atomic "$f" cs_hooks_filter "$f" "$filter" "$@"
}

cs_hooks_filter() { # FILE FILTER [ARGS...]
  local f=$1 filter=$2
  shift 2
  jq "$@" "$filter" "$f" | tr -d '\r'
}

# jq: drop our entries (by marker) from every event, then prune what became empty.
CS_HOOKS_REMOVE='
  def ours: (.command // "") | contains($mark);
  if .hooks == null then .
  else .hooks |= (with_entries(
        .value |= (map(.hooks |= map(select(ours | not))) | map(select((.hooks | length) > 0))))
      | with_entries(select((.value | length) > 0)))
    | if (.hooks | length) == 0 then del(.hooks) else . end
  end'

cs_hooks_install() {
  local ev matcher timeout cmd entries='[]'
  while IFS=$'\t' read -r ev matcher timeout cmd; do
    [[ -n $ev ]] || continue
    [[ $matcher == - ]] && matcher=''
    entries=$(jq -c --arg ev "$ev" --arg m "$matcher" --argjson t "$timeout" --arg c "$cmd" \
      '. + [{event: $ev, entry: ({hooks: [{type: "command", command: $c, timeout: $t}]} + (if $m != "" then {matcher: $m} else {} end))}]' <<<"$entries" | tr -d '\r')
  done < <(cs_hooks_entries)
  cs_hooks_apply "$CS_HOOKS_REMOVE | .hooks = ((.hooks // {}) as \$h | reduce \$e[] as \$x (\$h; .[\$x.event] = ((.[\$x.event] // []) + [\$x.entry])))" \
    --arg mark "$CS_HOOK_MARK" --argjson e "$entries"
  cs_say hooks.installed
}

cs_hooks_uninstall() {
  [[ -f $(cs_claude_dir)/settings.json ]] || {
    cs_say hooks.removed
    return 0
  }
  cs_hooks_apply "$CS_HOOKS_REMOVE" --arg mark "$CS_HOOK_MARK"
  cs_say hooks.removed
}

cmd_hooks() {
  case ${1:-} in
    install) cs_hooks_install ;;
    uninstall) cs_hooks_uninstall ;;
    *) cs_die_t "$CS_EXIT_USAGE" hooks.usage ;;
  esac
}

# --- handlers --------------------------------------------------------------------------------------------------

# cs_hook_json: one JSON object from stdin, "{}" when there is none (a closed or terminal stdin).
cs_hook_input() {
  local j=''
  [[ -t 0 ]] || j=$(cat)
  [[ -n $j ]] && jq -e . >/dev/null 2>&1 <<<"$j" || j='{}'
  printf '%s\n' "$j"
}

# cs_hook_notify_due KEY: rc 0 when KEY has not been shown in the last 24 h (and records it now).
cs_hook_notify_due() {
  local f="$CS_HOME/state/hook-notified" now last
  now=$(date +%s)
  last=$(K=$1 "$CS_AWK" -F'\t' '$1 == ENVIRON["K"] { v = $2 } END { print v }' "$f" 2>/dev/null)
  [[ $last =~ ^[0-9]+$ ]] && ((now - last < 86400)) && return 1
  mkdir -p -- "${f%/*}"
  {
    [[ -f $f ]] && K=$1 "$CS_AWK" -F'\t' '$1 != ENVIRON["K"]' "$f"
    printf '%s\t%s\n' "$1" "$now"
  } >"$f.tmp.$$"
  mv -f -- "$f.tmp.$$" "$f"
}

cs_hook_epoch() { # ISO UTC -> epoch seconds ("" if unparsable)
  [[ -n $1 ]] || return 0
  date -u -d "$1" +%s 2>/dev/null || true
}

# cs_hook_messages SID CWD: the notices for this session start, one per line.
cs_hook_messages() {
  local sid=$1 cwd=$2 st state lastpull boot iv pull boote since machine lines
  st="$CS_HOME/state/status.json"
  [[ -f $st ]] || return 0
  IFS=$'\t' read -r state lastpull boot machine since lines < <(cs_jq -r --arg s "$sid" \
    '[.state, (.last_ok_pull // "-"), (.boot_time // "-"), (.behind[$s].machine // "-"), (.behind[$s].since // "-"), ((.behind[$s].lines // 0) | tostring)] | @tsv' "$st")
  iv=$(cs_config_get interval 5)
  case $state in
    LOGIN_REQUIRED | OFFLINE | ROOT_MISSING | NEEDS_REPAIR) cs_say "hook.state_$state" ;;
  esac
  pull=$(cs_hook_epoch "${lastpull/#-/}")
  boote=$(cs_hook_epoch "${boot/#-/}")
  if [[ -z $pull ]]; then
    [[ $state == OK ]] && cs_say hook.never_pulled
  elif ((($(date +%s) - pull) > 2 * iv * 60)) || { [[ -n $boote ]] && ((pull < boote)); }; then
    cs_say hook.stale "${lastpull}"
  fi
  [[ $machine != - ]] && cs_say hook.behind "$machine" "$lines"
  local other
  other=$(cs_jq -r --arg s "$sid" '.live_elsewhere[$s].machine // empty' "$st")
  [[ -n $other ]] && cs_say hook.live_elsewhere "$other"
  cs_hook_waiting_map "$cwd"
  return 0
}

# cs_hook_waiting_map CWD: projects that wait to be mapped, each at most once a day; a folder that is a
# candidate gets the exact command.
cs_hook_waiting_map() {
  local cwd=$1 kind key alias cands dec c path any=0
  local -a cl
  [[ -f $CS_HOME/state/pending_map.tsv ]] || return 0
  while IFS=$'	' read -r kind key alias _ _ _ _ _ _ cands dec; do
    [[ $dec == pending ]] || continue
    if [[ $kind == remote && -n $cwd && $cands != - ]]; then
      IFS=';' read -r -a cl <<<"$cands"
      for c in "${cl[@]}"; do
        path=${c%%|*}
        if cs_path_under "$cwd" "$path" && cs_path_under "$path" "$cwd"; then
          if cs_hook_notify_due "map-$key"; then cs_say hook.map_here "$alias" "$alias" "$cwd"; fi
          continue 2
        fi
      done
    fi
    any=1
  done < <(cs_tsv_rows pending_map)
  if ((any)) && cs_hook_notify_due map-generic; then cs_say hook.map_waiting; fi
}

cs_hook_session_start() {
  local in sid cwd msgs
  in=$(cs_hook_input)
  sid=$(cs_jq -r '.session_id // empty' <<<"$in")
  cwd=$(cs_jq -r '.cwd // empty' <<<"$in")
  msgs=$(cs_hook_messages "$sid" "$cwd")
  if [[ -n $msgs ]]; then
    cs_jq -nc --arg m "$msgs" '{systemMessage: $m}'
  fi
  cs_kick >/dev/null 2>&1 || true
  return 0
}

cs_hook_prompt_guard() {
  local in sid st machine since mode msg
  in=$(cs_hook_input)
  sid=$(cs_jq -r '.session_id // empty' <<<"$in")
  st="$CS_HOME/state/status.json"
  mode=$(cs_config_get guard block)
  [[ -n $sid && -f $st && $mode != off ]] || return 0
  IFS=$'\t' read -r machine since < <(cs_jq -r --arg s "$sid" '[(.behind[$s].machine // "-"), (.behind[$s].since // "-")] | @tsv' "$st")
  [[ $machine != - ]] || return 0
  msg=$(cs_say hook.guard "$machine" "$since")
  cs_kick >/dev/null 2>&1 || true
  if [[ $mode == block ]]; then
    printf '%s\n' "$msg" >&2
    return 2
  fi
  cs_jq -nc --arg m "$msg" '{systemMessage: $m}'
  return 0
}

# cs_hook CMD: the `hook` command (internal; Claude Code runs it).
cs_hook() {
  case ${1:-} in
    session-start) cs_hook_session_start ;;
    prompt-guard) cs_hook_prompt_guard ;;
    *) return 0 ;;
  esac
}
