# shellcheck shell=bash
# setup: the re-runnable wizard (SPEC §16). Steps 0-6 here (ticket #12); 7-10 come with #29.
#   lang deps client proxy login root machine
# Each step can run alone: claude-sync setup --step <name>. Requires core, platform, version, store,
# claude, drive (with auth), root, ui.

[[ -n ${CS_SETUP_LOADED:-} ]] && return 0
CS_SETUP_LOADED=1

CS_SETUP_STEPS=(lang deps client proxy login root machine)

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
    cs_say setup.client_guide
  fi
  while ((tries < 3)); do
    tries=$((tries + 1))
    path=$(cs_ask setup.ask_client_path "")
    [[ -n $path ]] || continue
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
  for s in "${CS_SETUP_STEPS[@]}"; do
    "cs_setup_step_$s" || cs_die_t "$CS_EXIT_ERROR" setup.step_failed "$s"
  done
  printf '\n'
  cs_say setup.done_so_far
}
