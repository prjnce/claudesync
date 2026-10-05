# shellcheck shell=bash
# ui: prompts for the wizard. Questions go to stderr, answers come from stdin, so the wizard can be
# driven by piped answers in tests. At EOF every question takes its default. Requires lib/core.sh.

[[ -n ${CS_UI_LOADED:-} ]] && return 0
CS_UI_LOADED=1

# cs_ask KEY DEFAULT [ARGS...]: print the localized question KEY (with DEFAULT shown) and read one line;
# prints the answer, or DEFAULT when the answer is empty or stdin is closed.
cs_ask() {
  local key=$1 def=$2 ans
  shift 2
  if [[ -n $def ]]; then
    printf '%s [%s]: ' "$(cs_t "$key" "$@")" "$def" >&2
  else
    printf '%s: ' "$(cs_t "$key" "$@")" >&2
  fi
  IFS= read -r ans || ans=
  ans=${ans%$'\r'}
  [[ -t 0 ]] || printf '%s\n' "$ans" >&2 # echo piped answers so logs of a scripted setup read well
  printf '%s\n' "${ans:-$def}"
}

# cs_confirm KEY DEFAULT(y|n) [ARGS...]: yes/no question; rc 0 = yes. Accepts y/yes/c/có and n/no/k/không.
cs_confirm() {
  local key=$1 def=$2 ans
  shift 2
  ans=$(cs_ask "$key" "$def" "$@")
  case ${ans,,} in
    y | yes | c | co | có) return 0 ;;
    n | no | k | khong | không) return 1 ;;
    *) [[ $def == y ]] ;;
  esac
}

# cs_heading KEY [ARGS...]: a step title.
cs_heading() {
  printf '\n== %s ==\n' "$(cs_t "$@")"
}
