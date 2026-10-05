# shellcheck shell=bash
# i18n: user-facing messages in English (default) or Vietnamese (SPEC §20.1).
# Catalogs: lib/i18n/<lang>.sh define CS_MSG_<lang>[key]=printf-format. Logs always use English.
# Sourced by lib/core.sh.

[[ -n ${CS_I18N_LOADED:-} ]] && return 0
CS_I18N_LOADED=1

cs_i18n_dir=${BASH_SOURCE[0]%/*}/i18n
# shellcheck source=lib/i18n/en.sh
source "$cs_i18n_dir/en.sh"
# shellcheck source=lib/i18n/vi.sh
source "$cs_i18n_dir/vi.sh"
unset cs_i18n_dir

CS_LANG=${CS_LANG:-en}

# cs_lang_init: CS_LANG = $CLAUDE_SYNC_LANG > config "lang" > en; anything else falls back to en.
cs_lang_init() {
  local l=${CLAUDE_SYNC_LANG:-}
  [[ -n $l ]] || l=$(cs_config_get lang en 2>/dev/null) || l=en
  case $l in
    en | vi) CS_LANG=$l ;;
    *) CS_LANG=en ;;
  esac
}

# cs_t_lang LANG KEY [ARGS...]: formatted message (no trailing newline). Missing in LANG -> English;
# unknown key -> the key itself (test/i18n.bats makes sure that never ships).
cs_t_lang() {
  local lang=$1 key=$2 fmt=
  shift 2
  [[ $lang == vi ]] && fmt=${CS_MSG_vi[$key]-}
  [[ -n $fmt ]] || fmt=${CS_MSG_en[$key]-}
  [[ -n $fmt ]] || fmt=$key
  # shellcheck disable=SC2059 # the catalog entry is the format
  printf -- "$fmt" "$@"
}

# cs_t KEY [ARGS...]: message in the current UI language.
cs_t() {
  cs_t_lang "$CS_LANG" "$@"
}

# cs_say KEY [ARGS...]: cs_t plus newline on stdout.
cs_say() {
  cs_t "$@"
  printf '\n'
}

# cs_die_t CODE KEY [ARGS...]: localized error on stderr, English line in the log, exit CODE.
cs_die_t() {
  local code=$1
  shift
  printf 'claude-sync: %s\n' "$(cs_t "$@")" >&2
  cs_log error "$(cs_t_lang en "$@")" 2>/dev/null || true
  exit "$code"
}

# cs_pad TEXT WIDTH: TEXT left-aligned to WIDTH characters (not bytes, so Vietnamese aligns too).
cs_pad() {
  local LC_ALL=C.UTF-8
  local s=$1 w=$2
  printf '%s%*s' "$s" $((w > ${#s} ? w - ${#s} : 0)) ''
}
