# shellcheck shell=bash
# setup: the re-runnable wizard (SPEC §16): lang deps client proxy login root machine (#12), repair projects
#   retention finish (#29).
# Each step can run alone: claude-sync setup --step <name>. Requires core, platform, version, store,
# claude, drive (with auth), root, ui.

[[ -n ${CS_SETUP_LOADED:-} ]] && return 0
CS_SETUP_LOADED=1

CS_SETUP_STEPS=(lang deps client proxy login root machine repair projects retention finish)
# CS_SETUP_ONLY_STEPS="lang deps ..." restricts the full run to those steps (tests, partial re-runs).

cs_setup_step_lang() {
  cs_heading setup.h_lang
  local cur=${CS_LANG:-en} ans
  ans=$(cs_ask setup.ask_lang "$([[ $cur == vi ]] && echo 2 || echo 1)")
  case $ans in
    2 | vi) cs_config_set lang vi ;;
    *) cs_config_set lang en ;;
  esac
  cs_lang_init
}

cs_setup_step_deps() {
  cs_heading setup.h_deps
  cs_say setup.deps_ok "$BASH_VERSION" "$CS_AWK"
  if [[ $CS_OS == linux ]] && ! command -v python3 >/dev/null 2>&1; then
    cs_say setup.no_python
  fi
  command -v git >/dev/null 2>&1 || cs_say setup.no_git
}

cs_setup_step_client() {
  cs_heading setup.h_client
  local f path tries=0
  f=$(cs_client_file)
  if [[ -f $f ]]; then
    cs_client_load
    cs_say setup.client_have "${CS_CLIENT_ID:0:12}…"
    cs_confirm setup.ask_client_replace n || return 0
  else
    cs_say google.guide
  fi
  while ((tries < 3)); do
    tries=$((tries + 1))
    path=$(cs_ask setup.ask_client_path "")
    if [[ -z $path ]]; then
      # no file: type the Client ID and the secret instead
      if (cs_client_ask_ids); then
        cs_say auth.client_installed "$f"
        return 0
      fi
      continue
    fi
    [[ $CS_OS == windows && $path == [A-Za-z]:* ]] && path=$(cs_win_to_posix "$path")
    if [[ -f $path ]] && jq -e '(.installed // .web) | .client_id and .client_secret' "$path" >/dev/null 2>&1; then
      cs_client_install "$path"
      cs_say auth.client_installed "$f"
      return 0
    fi
    cs_say auth.bad_client "$path"
  done
  return 1
}

# cs_detect_proxy: a proxy from the environment, or (Windows) from the WinINET user settings.
cs_detect_proxy() {
  local p=${HTTPS_PROXY:-${https_proxy:-}}
  if [[ -z $p && $CS_OS == windows ]]; then
    local key='HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings' en srv
    en=$(nat reg.exe query "$key" /v ProxyEnable 2>/dev/null | tr -d '\r' | "$CS_AWK" '/ProxyEnable/ { print $NF }')
    if [[ $en == 0x1 ]]; then
      srv=$(nat reg.exe query "$key" /v ProxyServer 2>/dev/null | tr -d '\r' | "$CS_AWK" '/ProxyServer/ { print $NF }')
      # "host:port" or "http=h:p;https=h:p"
      if [[ $srv == *https=* ]]; then srv=${srv#*https=}; srv=${srv%%;*}; fi
      [[ -n $srv ]] && p="http://${srv#http://}"
    fi
  fi
  printf '%s\n' "$p"
}

cs_setup_step_proxy() {
  cs_heading setup.h_proxy
  local cur ans
  cur=$(cs_config_get proxy "")
  [[ -n $cur ]] || cur=$(cs_detect_proxy)
  ans=$(cs_ask setup.ask_proxy "${cur:--}")
  [[ $ans == - ]] && ans=
  cs_config_set proxy "$ans"
  if [[ -n $ans ]]; then export HTTPS_PROXY=$ans; else unset HTTPS_PROXY; fi
}

cs_setup_step_login() {
  cs_heading setup.h_login
  local who
  if cs_access_token_ensure 2>/dev/null && who=$(drv_about_user 2>/dev/null) && [[ -n $who ]]; then
    cs_say auth.signed_in_as "$who"
    cs_confirm setup.ask_relogin n || return 0
  fi
  cs_auth_login || return
  who=$(drv_about_user 2>/dev/null) || who=
  if [[ -n $who ]]; then cs_say auth.signed_in_as "$who"; else cs_say auth.signed_in; fi
}

cs_setup_step_root() {
  cs_heading setup.h_root
  local cands n rid mid name
  cands=$(cs_root_candidates) || return
  n=$(grep -c . <<<"$cands" || true)
  if ((n == 0)); then
    name=$(cs_ask setup.ask_root_name "Claude Sync")
    IFS=$'\t' read -r rid mid < <(cs_root_create "$name") || return 1
    [[ -n $rid && -n $mid ]] || return 1
    cs_say setup.root_created "$name"
  else
    IFS=$'\t' read -r rid mid _ name <<<"${cands%%$'\n'*}"
    if ((n > 1)); then
      cs_say setup.root_many "$n" "$name"
      while IFS=$'\t' read -r r _ ct nm; do printf '  - %s  %s  %s\n' "$nm" "$ct" "$(cs_root_link "$r")"; done <<<"$cands"
    else
      cs_say setup.root_found "$name"
    fi
  fi
  cs_root_use "$rid" "$mid"
  cs_say setup.root_summary "$(drv_about_user 2>/dev/null || echo '?')" "$name" "$(cs_root_link "$rid")"
  local machines
  machines=$(cs_machines_list "$rid" 2>/dev/null) || machines=
  if [[ -n $machines ]]; then
    while IFS=$'\t' read -r m nm os; do printf '    %s (%s) %s\n' "$nm" "$os" "$m"; done <<<"$machines"
  else
    cs_say setup.no_machines
  fi
}

cs_setup_step_machine() {
  cs_heading setup.h_machine
  local name id rid
  name=$(cs_ask setup.ask_machine_name "$(cs_config_get machine_name "$(cs_default_machine_name)")")
  if [[ -z $(cs_config_get machine_id "") && -s $(cs_owner_file) ]]; then
    # ~/.claude-sync was removed (uninstall --purge) but this Claude config still says who manages it:
    # take that identity back, and with it the old area on Drive.
    cs_config_set machine_id "$(tr -d '\r\n' <"$(cs_owner_file)")"
    cs_say setup.machine_reused
  fi
  id=$(cs_machine_init "$name")
  if ! cs_owner_claim "$id"; then
    cs_die_t "$CS_EXIT_ERROR" setup.owner_conflict "$(cs_owner_file)" "$(tr -d '\r\n' <"$(cs_owner_file)")"
  fi
  rid=$(cs_config_get root_id "")
  if [[ -n $rid ]]; then
    cs_machine_area_ensure "$rid" >/dev/null || return
  fi
  cs_say setup.machine_done "$name" "$id"
}

# Step 7: transcripts that Claude cannot load as written (SPEC §19). Declined repairs block those sessions.
cs_setup_step_repair() {
  cs_heading setup.h_repair
  local needing n rel sid
  needing=$(cs_repair_needing)
  n=$(printf '%s' "$needing" | grep -c . || true)
  if ((n == 0)); then
    cs_say setup.repair_none
    return 0
  fi
  cs_say setup.repair_found "$n"
  if cs_confirm setup.ask_repair y; then
    cs_repair --yes
  else
    while IFS= read -r rel; do
      [[ -n $rel ]] || continue
      sid=$(cs_repair_sid_of "$rel")
      cs_tsv_upsert sessions "$sid" - "${rel%%/*}" 0 0 0 - - - needs_repair - "$(date +%s)"
    done <<<"$needing"
    cs_say setup.repair_blocked "$n"
  fi
}

# Step 8: which folders are synced, and the projects other machines already sync (SPEC §6.1).
# cs_setup_project_items: "kind<TAB>key<TAB>alias<TAB>root<TAB>id<TAB>sessions<TAB>bytes" for every project that uses Claude on
# this machine: the mapped ones first (kind m, key = project_id), then the folders not mapped yet (kind u, key = root).
cs_setup_project_items() {
  local counts id root alias en n b last='' seen=' '
  counts=$(cs_project_session_counts)
  while IFS=$'\t' read -r id root alias _ _ en _; do
    [[ -n $id && $id != "$last" ]] || continue
    last=$id
    IFS=$'\t' read -r _ n b < <(printf '%s\n' "$counts" | I=$id "$CS_AWK" -F'\t' '$1 == ENVIRON["I"]' | grep . || printf 'x\t0\t0\n')
    printf 'm\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$alias" "$root" "$id" "$n" "$b"
  done < <(cs_tsv_rows projects | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -s)
  while IFS=$'\t' read -r root n b; do
    [[ -n $root ]] || continue
    printf 'u\t%s\t%s\t%s\t-\t%s\t%s\n' "$root" "${root##*[\\/]}" "$root" "$n" "$b"
  done < <(cs_unmapped_roots)
}

# Step 8: one numbered list of everything that uses Claude here; the user picks what is synced (Enter = all).
cs_setup_choose_projects() {
  local items i=0 kind key alias root id n b ans tries=0 line none=0
  local -a kinds=() keys=() aliases=() roots=() sel=()
  items=$(cs_setup_project_items)
  if [[ -z $items ]]; then
    cs_say setup.projects_none
    return 0
  fi
  cs_say setup.projects_header
  while IFS=$'\t' read -r kind key alias root id n b; do
    i=$((i + 1))
    kinds+=("$kind") keys+=("$key") aliases+=("$alias") roots+=("$root")
    printf '  %s. %s %s %s %s %s\n' "$i" "$(cs_pad "$alias:" 18)" "$(cs_pad "$root" 28)" "$(cs_pad "$id" 9)" "$(cs_pad "$n" 5)" "$(cs_human_bytes "$b")"
  done <<<"$items"
  while ((tries < 3)); do
    tries=$((tries + 1))
    ans=$(cs_ask setup.projects_choose "")
    sel=()
    if [[ -z $ans || ${ans,,} == all || ${ans,,} == a ]]; then
      for ((n = 1; n <= i; n++)); do sel[n]=1; done
      break
    fi
    if [[ $ans == 0 || ${ans,,} == none || ${ans,,} == n ]]; then
      none=1 # sync nothing from this machine (for now)
      break
    fi
    local bad=0 tok
    local IFS=', '
    for tok in $ans; do
      if [[ $tok =~ ^[0-9]+$ ]] && ((tok >= 1 && tok <= i)); then sel[tok]=1; else bad=1; fi
    done
    unset IFS
    ((bad)) || break
    sel=()
    cs_say setup.bad_choice >&2
  done
  ((${#sel[@]} || none)) || return 0
  local chosen=0
  for ((n = 1; n <= i; n++)); do
    [[ -n ${sel[n]:-} ]] && chosen=$((chosen + 1))
    if [[ ${kinds[n - 1]} == m ]]; then
      cs_project_set_enabled "${keys[n - 1]}" "$([[ -n ${sel[n]:-} ]] && echo 1 || echo 0)"
    elif [[ -n ${sel[n]:-} ]]; then
      alias=${aliases[n - 1]}
      if cs_project_find "$alias" >/dev/null 2>&1; then alias="$alias-$n"; fi
      IFS=$'\t' read -r id _ _ < <(cs_project_map "$alias" "${roots[n - 1]}")
      cs_say projects.mapped "$alias" "$id" "${roots[n - 1]}"
    fi
  done
  if ((none)); then
    cs_config_set mode selected
    cs_say setup.projects_mode_none
  elif ((chosen == i)); then
    cs_config_set mode all
    cs_say setup.projects_mode_all
  else
    cs_config_set mode selected
    cs_say setup.projects_mode_selected
  fi
}

cs_setup_step_projects() {
  cs_heading setup.h_projects
  cs_setup_choose_projects
  if declare -F cs_eng_fetch_remotes >/dev/null && cs_eng_load 2>/dev/null; then
    cs_eng_fetch_remotes
    CS_RUN_REMOTE_FAIL=0 cs_pend_detect || true
    cs_pend_review
  fi
}

# Step 9: Claude deletes transcripts older than cleanupPeriodDays; ask before raising it.
cs_setup_step_retention() {
  cs_heading setup.h_retention
  local days
  days=$(cs_claude_retention_days)
  if [[ $days == 0 ]] || ((days >= 3650)); then
    cs_say setup.retention_ok "$days"
    cs_confirm setup.retention_keep y "$days" && return 0
    days=$(cs_ask setup.retention_ask_days 3650)
    if [[ $days =~ ^[0-9]+$ ]]; then
      cs_claude_settings_set cleanupPeriodDays "$((10#$days))"
      cs_say setup.retention_value "$((10#$days))"
    else
      cs_say setup.bad_choice >&2
    fi
    return 0
  fi
  if cs_confirm setup.ask_retention y "$days"; then
    cs_claude_settings_set cleanupPeriodDays 3650
    cs_say setup.retention_set
  else
    cs_say setup.retention_kept "$days"
  fi
}

# Step 10: interval, service, hooks, doctor, and the first sync right here with progress (F11).
cs_setup_step_finish() {
  cs_heading setup.h_finish
  local iv
  iv=$(cs_ask setup.ask_interval "$(cs_config_get interval 5)")
  if cs_interval_ok "$iv"; then iv=$((10#$iv)); else
    cs_say setup.bad_interval "$iv" >&2
    iv=5
  fi
  cs_config_set interval "$iv"
  cs_sched_install || cs_say setup.service_failed >&2
  cs_hooks_install
  cs_doctor || true
  cs_say setup.first_sync
  # a person is watching: do not wait half an hour for the network, say so after a short while
  CS_PROGRESS=1 CS_SOFT_DEADLINE=86400 CS_OFFLINE_BUDGET=${CS_OFFLINE_BUDGET:-30} cs_run || cs_say setup.first_sync_failed >&2
  cs_say setup.alias_hint
}

# cs_setup [--step NAME]: run every step (or one).
cs_setup() {
  local only='' s
  while (($#)); do
    case $1 in
      --step)
        only=${2:-}
        shift 2 || true
        ;;
      *) cs_die_t "$CS_EXIT_USAGE" cli.unknown_command "setup $1" ;;
    esac
  done
  cs_store_init
  if [[ -n $only ]]; then
    [[ " ${CS_SETUP_STEPS[*]} " == *" $only "* ]] || cs_die_t "$CS_EXIT_USAGE" setup.bad_step "$only" "${CS_SETUP_STEPS[*]}"
    "cs_setup_step_$only"
    return
  fi
  local -a steps=("${CS_SETUP_STEPS[@]}")
  [[ -z ${CS_SETUP_ONLY_STEPS:-} ]] || read -r -a steps <<<"$CS_SETUP_ONLY_STEPS"
  cs_say setup.secrets_warning
  for s in "${steps[@]}"; do
    "cs_setup_step_$s" || cs_die_t "$CS_EXIT_ERROR" setup.step_failed "$s"
  done
  printf '\n'
  cs_say setup.done_so_far
}
