# shellcheck shell=bash
# store: local DB as TSV tables with a header line, append-only known-version sets, and the journal of
# multi-step operations (SPEC §5.2, §11, §14.1). All writes are atomic (temp file + mv); callers that
# write concurrently must hold the sync lock. Requires lib/core.sh.

[[ -n ${CS_STORE_LOADED:-} ]] && return 0
CS_STORE_LOADED=1

# Table schemas: "keycols col1 col2 ..." (SPEC §11). keycols = number of leading columns forming the key.
declare -gA CS_TABLES=(
  [sessions]="1 sid project_id dir local_size local_mtime installed_len installed_sha base base_segs_ref status flags updated"
  [objects]="1 path_rel file_id sha size state resumable_uri created"
  [projects]="2 project_id cwd_root alias real_root mem_dir enabled remote_keys"
  [forks]="2 sid losing_version fork_sid created"
  [pending_map]="2 kind key alias machines remote_roots sessions bytes first_seen notified_sessions candidates decision"
)

# cs_store_init: create the ~/.claude-sync tree (SPEC §5.2). Idempotent; a missing state/ is rebuilt empty.
cs_store_init() {
  local d
  mkdir -p -- "$CS_HOME"
  [[ $CS_OS == linux ]] && chmod 700 -- "$CS_HOME"
  for d in state state/known state/remote state/base/mem journal cache/manifests staging backups conflicts logs; do
    mkdir -p -- "$CS_HOME/$d"
  done
}

# cs_store_same_volume DIR: rc 0 if staging/ is on the same volume as DIR (renames stay atomic).
cs_store_same_volume() {
  [[ $(stat -c %d -- "$CS_HOME/staging") == "$(stat -c %d -- "$1")" ]]
}

cs_tsv_file() {
  printf '%s\n' "$CS_HOME/state/$1.tsv"
}

# cs_tsv_schema TABLE -> sets CS_TSV_KEYS (int) and CS_TSV_COLS (array); dies on unknown table.
cs_tsv_schema() {
  local spec=${CS_TABLES[$1]:-}
  [[ -n $spec ]] || cs_die "$CS_EXIT_ERROR" "store: unknown table: $1"
  local IFS=' ' # independent of the caller's IFS
  read -r CS_TSV_KEYS spec <<<"$spec"
  read -r -a CS_TSV_COLS <<<"$spec"
}

cs_tsv_header() {
  cs_tsv_schema "$1"
  local IFS=$'\t'
  printf '#%s\n' "${CS_TSV_COLS[*]}"
}

# cs_tsv_check TABLE: dies if the file exists with a different header (schema changed underneath us).
cs_tsv_check() {
  local f header
  cs_tsv_schema "$1"
  f=$(cs_tsv_file "$1")
  [[ -f $f ]] || return 0
  IFS= read -r header <"$f" || header=
  [[ $header == "$(cs_tsv_header "$1")" ]] || cs_die "$CS_EXIT_ERROR" "store: $f has an unexpected header (schema mismatch)"
}

# cs_tsv_col TABLE NAME -> 1-based column index.
cs_tsv_col() {
  cs_tsv_schema "$1"
  local i
  for i in "${!CS_TSV_COLS[@]}"; do
    [[ ${CS_TSV_COLS[i]} == "$2" ]] && {
      printf '%d\n' $((i + 1))
      return 0
    }
  done
  cs_die "$CS_EXIT_ERROR" "store: table $1 has no column $2"
}

# cs_tsv_validate TABLE FIELD...: dies unless the row has exactly the table's column count and no
# field contains a tab, CR or newline.
cs_tsv_validate() {
  local t=$1 f
  shift
  cs_tsv_schema "$t"
  (($# == ${#CS_TSV_COLS[@]})) || cs_die "$CS_EXIT_ERROR" "store: $t row needs ${#CS_TSV_COLS[@]} fields, got $#"
  for f in "$@"; do
    [[ $f != *[$'\t\r\n']* ]] || cs_die "$CS_EXIT_ERROR" "store: $t field contains a tab or newline"
  done
}

# cs_tsv_split LINE ARRAYNAME: split a TSV line into an array, keeping empty fields.
cs_tsv_split() {
  local -n _cs_out=$2
  readarray -d $'\t' -t _cs_out < <(printf '%s' "$1")
  # A trailing empty field produces no element: pad with an empty string.
  [[ $1 == *$'\t' ]] && _cs_out+=("")
  return 0
}

# cs_tsv_rows TABLE: every data row (no header).
cs_tsv_rows() {
  local f
  cs_tsv_check "$1"
  f=$(cs_tsv_file "$1")
  [[ -f $f ]] || return 0
  "$CS_AWK" 'FNR > 1' "$f"
}

# cs_tsv_get TABLE KEY...: print the row whose key columns equal KEY...; rc 1 if absent.
cs_tsv_get() {
  local t=$1 f
  shift
  cs_tsv_check "$t"
  cs_tsv_schema "$t"
  (($# == CS_TSV_KEYS)) || cs_die "$CS_EXIT_ERROR" "store: $t key needs $CS_TSV_KEYS fields"
  f=$(cs_tsv_file "$t")
  [[ -f $f ]] || return 1
  local IFS=$'\t'
  K="$*" "$CS_AWK" -F'\t' -v n="$CS_TSV_KEYS" '
    FNR == 1 { next }
    { k = $1; for (i = 2; i <= n; i++) k = k "\t" $i }
    k == ENVIRON["K"] { print; found = 1; exit }
    END { exit !found }' "$f"
}

# cs_tsv_field TABLE COLUMN KEY...: print one field of the keyed row; rc 1 if the row is absent.
cs_tsv_field() {
  local t=$1 col=$2 row idx
  shift 2
  row=$(cs_tsv_get "$t" "$@") || return 1
  idx=$(cs_tsv_col "$t" "$col")
  local -a f
  cs_tsv_split "$row" f
  printf '%s\n' "${f[idx - 1]}"
}

# cs_tsv_upsert TABLE FIELD...: insert or replace one row by key.
cs_tsv_upsert() {
  local t=$1
  shift
  cs_tsv_validate "$t" "$@"
  local IFS=$'\t'
  printf '%s\n' "$*" | cs_tsv_upsert_many "$t"
}

# cs_tsv_upsert_many TABLE < ROWS: insert or replace many tab-separated rows in one pass (last wins).
# Existing rows keep their position; new rows are appended in input order.
cs_tsv_upsert_many() {
  local t=$1 f new row
  cs_tsv_check "$t"
  cs_tsv_schema "$t"
  f=$(cs_tsv_file "$t")
  new="$f.new.$$"
  : >"$new"
  while IFS= read -r row || [[ -n $row ]]; do
    local -a fields
    cs_tsv_split "$row" fields
    cs_tsv_validate "$t" "${fields[@]}"
    printf '%s\n' "$row" >>"$new"
  done
  [[ -f $f ]] || cs_tsv_header "$t" >"$f"
  cs_write_atomic "$f" "$CS_AWK" -F'\t' -v n="$CS_TSV_KEYS" '
    function key(   i, s) { s = $1; for (i = 2; i <= n; i++) s = s "\t" $i; return s }
    pass == 1 { k = key(); if (!(k in row)) order[++cnt] = k; row[k] = $0; next }
    FNR == 1 { print; next }
    { k = key(); if (k in row) { if (!(k in done)) print row[k]; done[k] = 1 } else print }
    END { for (i = 1; i <= cnt; i++) if (!(order[i] in done)) print row[order[i]] }' pass=1 "$new" pass=2 "$f"
  local rc=$?
  rm -f -- "$new"
  return "$rc"
}

# cs_tsv_delete TABLE KEY...: remove the keyed row (no error if absent).
cs_tsv_delete() {
  local t=$1 f
  shift
  cs_tsv_check "$t"
  cs_tsv_schema "$t"
  (($# == CS_TSV_KEYS)) || cs_die "$CS_EXIT_ERROR" "store: $t key needs $CS_TSV_KEYS fields"
  f=$(cs_tsv_file "$t")
  [[ -f $f ]] || return 0
  local IFS=$'\t'
  cs_write_atomic "$f" env K="$*" "$CS_AWK" -F'\t' -v n="$CS_TSV_KEYS" '
    FNR == 1 { print; next }
    { k = $1; for (i = 2; i <= n; i++) k = k "\t" $i }
    k != ENVIRON["K"]' "$f"
}

# --- known/<sid>: every version_id ever seen, installed or published (append-only, SPEC §11) ------------

cs_known_has() {
  local f="$CS_HOME/state/known/$1"
  [[ -f $f ]] && grep -qxF -- "$2" "$f"
}

cs_known_add() {
  [[ $1 =~ ^[A-Za-z0-9-]+$ && $2 =~ ^[A-Za-z0-9]+$ ]] || cs_die "$CS_EXIT_ERROR" "store: bad known entry: $1 $2"
  cs_known_has "$1" "$2" && return 0
  printf '%s\n' "$2" >>"$CS_HOME/state/known/$1"
}

# --- journal (SPEC §14.1) ---------------------------------------------------------------------------------

CS_JOURNAL_SEQ=0

# cs_journal_begin OP JSON: record the intent of a multi-step operation before doing it; prints the path.
# JSON is an object; an optional "tmp" array lists temp files to remove if the operation is abandoned.
cs_journal_begin() {
  local op=$1 json=$2 ts path
  [[ $op =~ ^[a-z-]+$ ]] || cs_die "$CS_EXIT_ERROR" "journal: bad op: $op"
  printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1 || cs_die "$CS_EXIT_ERROR" "journal: $op payload is not a JSON object"
  TZ=UTC printf -v ts '%(%Y%m%dT%H%M%SZ)T' -1
  CS_JOURNAL_SEQ=$((CS_JOURNAL_SEQ + 1))
  path="$CS_HOME/journal/$ts-$$-$(printf '%04d' "$CS_JOURNAL_SEQ")-$op.json"
  cs_write_atomic "$path" printf '%s\n' "$json"
  printf '%s\n' "$path"
}

# cs_journal_end PATH: the operation completed.
cs_journal_end() {
  rm -f -- "$1"
}

# cs_journal_pending: unfinished entries, oldest first.
cs_journal_pending() {
  local f
  for f in "$CS_HOME"/journal/*.json; do
    [[ -e $f ]] && printf '%s\n' "$f"
  done
  return 0
}

# cs_journal_op PATH -> the op name encoded in the file name.
cs_journal_op() {
  local b=${1##*/}
  b=${b%.json}
  printf '%s\n' "${b#*-*-*-}"
}

# cs_journal_abandon PATH: remove the entry's temp files ("tmp" array, only *.csync-tmp*) and the entry.
cs_journal_abandon() {
  local t
  while IFS= read -r t; do
    [[ -n $t && $t == *.csync-tmp* ]] && rm -f -- "$t"
  done < <(jq -r '.tmp // [] | .[]' "$1" | tr -d '\r')
  rm -f -- "$1"
}
