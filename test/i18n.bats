#!/usr/bin/env bats
# i18n: catalogs, language selection, fallback, English logs (ticket #32, SPEC §20.1).

load test_helper

setup() {
  cs_test_setup
  unset CLAUDE_SYNC_LANG
  cs_load_core
}

# printf conversion specifiers of a format, in order (%% excluded).
specs() {
  printf '%s' "$1" | "$CS_AWK" '{ s = s $0 "\n" } END {
    gsub(/%%/, "", s)
    while (match(s, /%[-+ #0]*[0-9]*(\.[0-9]+)?[sdifxXc]/)) { o = o substr(s, RSTART + RLENGTH - 1, 1); s = substr(s, RSTART + RLENGTH) }
    print o }'
}

@test "en and vi catalogs have exactly the same keys" {
  local en vi
  en=$(printf '%s\n' "${!CS_MSG_en[@]}" | sort)
  vi=$(printf '%s\n' "${!CS_MSG_vi[@]}" | sort)
  diff <(printf '%s\n' "$en") <(printf '%s\n' "$vi")
}

@test "every key has the same printf specifiers in the same order in both catalogs" {
  local k bad=0
  for k in "${!CS_MSG_en[@]}"; do
    if [[ $(specs "${CS_MSG_en[$k]}") != "$(specs "${CS_MSG_vi[$k]}")" ]]; then
      printf 'specifier mismatch: %s (en=%s vi=%s)\n' "$k" "$(specs "${CS_MSG_en[$k]}")" "$(specs "${CS_MSG_vi[$k]}")"
      bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}

@test "catalog formats contain no backslashes" {
  local k
  for k in "${!CS_MSG_en[@]}"; do [[ ${CS_MSG_en[$k]} != *\\* ]] || { echo "en $k"; return 1; }; done
  for k in "${!CS_MSG_vi[@]}"; do [[ ${CS_MSG_vi[$k]} != *\\* ]] || { echo "vi $k"; return 1; }; done
}

@test "every cs_t/cs_say/cs_die_t/doctor_line key used in the code exists in the catalog" {
  local k missing=0
  while IFS= read -r k; do
    [[ -n ${CS_MSG_en[$k]+x} ]] || { echo "missing key: $k"; missing=1; }
  done < <(grep -rhoE '(cs_t|cs_say|cs_t_lang [a-z]+|doctor_line [A-Z]+) [a-z_]+\.[a-z_.]+|cs_die_t "\$CS_EXIT_[A-Z]+" [a-z_]+\.[a-z_.]+' \
    "$CS_ROOT/bin/claude-sync" "$CS_ROOT/lib" | awk '{ print $NF }' | sort -u)
  [ "$missing" -eq 0 ]
}

@test "language: default en, CLAUDE_SYNC_LANG, config lang, unknown value falls back to en" {
  cs_lang_init
  [ "$CS_LANG" = en ]
  CLAUDE_SYNC_LANG=vi cs_lang_init
  [ "$CS_LANG" = vi ]
  cs_config_set lang vi
  cs_lang_init
  [ "$CS_LANG" = vi ]
  CLAUDE_SYNC_LANG=en cs_lang_init
  [ "$CS_LANG" = en ]
  cs_config_set lang xx
  cs_lang_init
  [ "$CS_LANG" = en ]
}

@test "cs_t formats arguments; missing vi key falls back to en; unknown key prints the key" {
  CS_LANG=vi
  [ "$(cs_t doctor.sessions 3 2)" = "3 session trong 2 thư mục project" ]
  CS_MSG_en[test.only_en]='only %s'
  [ "$(cs_t test.only_en x)" = "only x" ]
  [ "$(cs_t no.such.key)" = no.such.key ]
}

@test "help follows the language; usage error too" {
  run cli help
  [[ ${lines[0]} == "usage: claude-sync"* ]]
  CLAUDE_SYNC_LANG=vi run cli help
  [[ ${lines[0]} == "cách dùng: claude-sync"* ]]
  CLAUDE_SYNC_LANG=vi run cli frob
  [ "$status" -eq 2 ]
  [[ $output == *"lệnh không tồn tại: frob"* ]]
}

@test "errors are localized on stderr but logged in English" {
  mkdir -p "$CLAUDE_SYNC_HOME/logs"
  CLAUDE_SYNC_LANG=vi run cli conflicts
  [ "$status" -eq 1 ]
  [[ $output == *'lệnh "conflicts" chưa được làm'* ]]
  grep -q 'level=error "conflicts" is not implemented yet' "$CLAUDE_SYNC_HOME/logs/claude-sync.log"
}

@test "cs_pad aligns by characters, not bytes" {
  [ "$(cs_pad 'DUNG LƯỢNG' 12)|" = 'DUNG LƯỢNG  |' ]
  [ "$(cs_pad abc 2)|" = 'abc|' ]
}
