# shellcheck shell=bash
# core: bootstrap, logging, errors, config, atomic writes (SPEC §3.2, §5.2, §20, §21).
# Sourced by bin/claude-sync and by tests; never executed directly.

[[ -n ${CS_CORE_LOADED:-} ]] && return 0
CS_CORE_LOADED=1

CS_VERSION=0.1.0-rc1

# Exit codes (SPEC §20).
CS_EXIT_OK=0
CS_EXIT_ERROR=1
CS_EXIT_USAGE=2
CS_EXIT_LOGIN=3
CS_EXIT_OFFLINE=4
CS_EXIT_BUSY=5
CS_EXIT_REPAIR=6

CS_TRIGGER=${CS_TRIGGER:-manual}

# cs_die CODE MSG...: print to stderr, log, and exit with CODE.
cs_die() {
  local code=$1
  shift
  printf 'claude-sync: %s\n' "$*" >&2
  cs_log error "$*" 2>/dev/null || true
  exit "$code"
}

# cs_bash_version_ok MAJOR MINOR: rc 0 when MAJOR.MINOR >= 4.4.
cs_bash_version_ok() {
  (( $1 > 4 || ($1 == 4 && $2 >= 4) ))
}

# cs_win_to_posix 'C:\Users\x' -> /c/Users/x (no fork; MSYS mount layout).
cs_win_to_posix() {
  local p=$1 drive
  if [[ $p == [A-Za-z]:* ]]; then
    drive=${p:0:1}
    p="/${drive,,}${p:2}"
  fi
  printf '%s\n' "${p//\\//}"
}

# cs_set_home: CS_HOME = $CLAUDE_SYNC_HOME, else %USERPROFILE%\.claude-sync on Windows, else ~/.claude-sync.
cs_set_home() {
  if [[ -n ${CLAUDE_SYNC_HOME:-} ]]; then
    CS_HOME=$CLAUDE_SYNC_HOME
  elif [[ ${CS_OS:-} == windows && -n ${USERPROFILE:-} ]]; then
    CS_HOME="$(cs_win_to_posix "$USERPROFILE")/.claude-sync"
  else
    CS_HOME="$HOME/.claude-sync"
  fi
}

# cs_detect_os: sets CS_OS (windows|linux) and CS_WSL (0|1); repairs PATH on MSYS.
cs_detect_os() {
  CS_WSL=0
  case $OSTYPE in
    msys* | cygwin*)
      CS_OS=windows
      # Task Scheduler starts bash with the bare Windows PATH: find/sort/curl would resolve to System32.
      case ":$PATH:" in
        *:/usr/bin:*) ;;
        *) PATH=/mingw64/bin:/usr/bin:$PATH ;;
      esac
      ;;
    linux*)
      CS_OS=linux
      if [[ -e /proc/sys/fs/binfmt_misc/WSLInterop || -n ${WSL_DISTRO_NAME:-} ]]; then
        CS_WSL=1
      fi
      ;;
    *) cs_die "$CS_EXIT_ERROR" "unsupported OSTYPE=$OSTYPE" ;;
  esac
}

# cs_required_tools: one tool per line. CS_TEST_EXTRA_TOOLS lets tests inject a missing tool.
cs_required_tools() {
  local -a tools=(find sort sed stat date sha256sum md5sum gzip mktemp tail od truncate iconv openssl jq perl curl)
  [[ $CS_OS == windows ]] && tools+=(cygpath powershell.exe)
  if [[ -n ${CS_TEST_EXTRA_TOOLS:-} ]]; then
    local -a extra
    IFS=' ' read -r -a extra <<<"$CS_TEST_EXTRA_TOOLS"
    tools+=("${extra[@]}")
  fi
  printf '%s\n' "${tools[@]}"
}

# cs_install_hint TOOL...: one line telling the user how to install the missing tools.
cs_install_hint() {
  local t pkgs=" "
  if [[ $CS_OS == windows ]]; then
    cs_say boot.install_git
    return 0
  fi
  for t in "$@"; do
    case $t in
      find) t=findutils ;;
      sort | stat | date | sha256sum | md5sum | mktemp | tail | od | truncate) t=coreutils ;;
      iconv) t=libc-bin ;;
    esac
    [[ $pkgs == *" $t "* ]] || pkgs+="$t "
  done
  pkgs=${pkgs# }
  cs_say boot.install_apt "${pkgs% }"
}

# cs_check_tools: dies listing every missing tool plus an install hint.
cs_check_tools() {
  local t
  local -a missing=()
  while IFS= read -r t; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done < <(cs_required_tools)
  if ((${#missing[@]})); then
    cs_die_t "$CS_EXIT_ERROR" boot.missing_tools "${missing[*]}" "$(cs_install_hint "${missing[@]}")"
  fi
  # shellcheck disable=SC2185 # --version takes no path
  find --version 2>/dev/null | grep -q 'GNU findutils' || cs_die_t "$CS_EXIT_ERROR" boot.gnu_tool find "$(command -v find)"
  sort --version 2>/dev/null | grep -q 'GNU coreutils' || cs_die_t "$CS_EXIT_ERROR" boot.gnu_tool sort "$(command -v sort)"
}

# cs_pick_awk: CS_AWK = override (name or path) or gawk || mawk || awk, as an absolute path.
cs_pick_awk() {
  local a
  if [[ -n ${CS_AWK:-} ]]; then
    a=$(command -v "$CS_AWK") || cs_die "$CS_EXIT_ERROR" "CS_AWK=$CS_AWK not found"
  else
    a=$(command -v gawk || command -v mawk || command -v awk) || cs_die "$CS_EXIT_ERROR" "no awk found"
  fi
  CS_AWK=$a
}

# cs_bootstrap_ui: the minimum needed to talk to the user (help, usage errors): OS, locale, home, language.
cs_bootstrap_ui() {
  cs_detect_os
  export LC_ALL=C
  cs_set_home
  cs_lang_init
}

# cs_bootstrap: everything an entrypoint needs before doing real work (SPEC §3.2).
cs_bootstrap() {
  cs_bootstrap_ui
  cs_check_tools
  cs_pick_awk
  local proxy
  proxy=$(cs_config_get proxy "")
  if [[ -n $proxy && -z ${HTTPS_PROXY:-} ]]; then
    export HTTPS_PROXY=$proxy
  fi
}

# cs_log LEVEL MSG...: append "ISO-local-time-with-offset trigger level msg" to the log (only if logs/ exists);
# warn/error also go to stderr, info/debug only with CS_VERBOSE=1. Never pass secrets here.
cs_log() {
  local level=$1 ts line
  shift
  printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
  line="$ts trigger=$CS_TRIGGER level=$level $*"
  if [[ -n ${CS_HOME:-} && -d $CS_HOME/logs ]]; then
    printf '%s\n' "$line" >>"$CS_HOME/logs/claude-sync.log"
  fi
  case $level in
    warn | error) printf 'claude-sync: %s: %s\n' "$level" "$*" >&2 ;;
    *) [[ ${CS_VERBOSE:-0} == 1 ]] && printf 'claude-sync: %s\n' "$*" >&2 ;;
  esac
  return 0
}

# cs_write_atomic TARGET CMD [ARGS...]: run CMD with stdout into a temp file next to TARGET and
# rename it over TARGET only if CMD succeeds. TARGET is untouched on failure or kill.
cs_write_atomic() {
  local target=$1 tmp
  shift
  tmp="$target.csync-tmp.$$"
  if "$@" >"$tmp"; then
    mv -f -- "$tmp" "$target"
  else
    local rc=$?
    rm -f -- "$tmp"
    return "$rc"
  fi
}

# cs_config_file: path of the key=value config.
cs_config_file() {
  printf '%s\n' "$CS_HOME/config"
}

# cs_config_get KEY [DEFAULT]: print the value, or DEFAULT (rc 1 if absent and no default given).
cs_config_get() {
  local key=$1 file val
  file=$(cs_config_file)
  if [[ -f $file ]]; then
    val=$(K=$key "${CS_AWK:-awk}" 'index($0, ENVIRON["K"] "=") == 1 { v = substr($0, length(ENVIRON["K"]) + 2); f = 1 } END { if (f) print v; exit !f }' "$file") && {
      printf '%s\n' "$val"
      return 0
    }
  fi
  if (($# >= 2)); then
    printf '%s\n' "$2"
    return 0
  fi
  return 1
}

# cs_config_set KEY VALUE: insert or replace one line, atomically. Keys are [a-z_][a-z0-9_]*.
cs_config_set() {
  local key=$1 val=$2 file
  [[ $key =~ ^[a-z_][a-z0-9_]*$ ]] || cs_die_t "$CS_EXIT_USAGE" config.bad_key "$key"
  [[ $val != *$'\n'* && $val != *$'\r'* ]] || cs_die_t "$CS_EXIT_USAGE" config.multiline
  file=$(cs_config_file)
  mkdir -p -- "${file%/*}"
  [[ -f $file ]] || : >"$file"
  cs_write_atomic "$file" env K="$key" V="$val" "${CS_AWK:-awk}" '
    index($0, ENVIRON["K"] "=") == 1 { if (!done) print ENVIRON["K"] "=" ENVIRON["V"]; done = 1; next }
    { print }
    END { if (!done) print ENVIRON["K"] "=" ENVIRON["V"] }' "$file"
}

# shellcheck source=lib/i18n.sh
source "${BASH_SOURCE[0]%/*}/i18n.sh"
