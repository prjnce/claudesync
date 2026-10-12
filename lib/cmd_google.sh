# shellcheck shell=bash
# cmd_google: `claude-sync google [guide|client <file>|status]` — the Google side of the setup, usable at any time
# (the wizard uses the same guide). Every user creates an OAuth client of their own; the same JSON goes to every
# machine of that user. Requires core, platform, version, store, drive (auth), ui.

[[ -n ${CS_CMD_GOOGLE_LOADED:-} ]] && return 0
CS_CMD_GOOGLE_LOADED=1

cmd_google() {
  local sub=${1:-status} f
  shift || true
  case $sub in
    guide) cs_say google.guide ;;
    client)
      [[ -n ${1:-} ]] || cs_die_t "$CS_EXIT_USAGE" google.usage
      f=$1
      [[ $CS_OS == windows && $f == [A-Za-z]:* ]] && f=$(cs_win_to_posix "$f")
      [[ -f $f ]] || cs_die_t "$CS_EXIT_ERROR" auth.bad_client "$f"
      cs_client_install "$f"
      rm -f -- "$CS_HOME/state/oauth_mode" # the new client has not been used to sign in yet
      cs_say google.client_installed "$(cs_client_file)"
      cs_say google.next_login
      ;;
    status) cs_google_status ;;
    *) cs_die_t "$CS_EXIT_USAGE" google.usage ;;
  esac
}

cs_google_status() {
  local f cid project mode
  f=$(cs_client_file)
  if [[ ! -f $f ]]; then
    cs_say google.no_client
    cs_say google.next_guide
    return 1
  fi
  cid=$(jq -r '(.installed // .web).client_id // empty' "$f" | tr -d '\r')
  project=$(jq -r '(.installed // .web).project_id // "?"' "$f" | tr -d '\r')
  cs_say google.client "${cid:0:14}..." "$project"
  if [[ -s $(cs_token_file) ]]; then cs_say google.token_yes; else cs_say google.token_no; fi
  mode=$(cat -- "$CS_HOME/state/oauth_mode" 2>/dev/null || true)
  case $mode in
    production) cs_say google.mode_production ;;
    testing) cs_say google.mode_testing ;;
    *) cs_say google.mode_unknown ;;
  esac
}
