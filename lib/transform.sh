# shellcheck shell=bash
# transform: canonicalize/localize paths in Claude Code JSONL, complete-line cuts, transcript checks
# (SPEC §7). The byte work is done by lib/transform.awk. Requires lib/core.sh.

[[ -n ${CS_TRANSFORM_LOADED:-} ]] && return 0
CS_TRANSFORM_LOADED=1

CS_TRANSFORM_AWK=${BASH_SOURCE[0]%/*}/transform.awk

# cs_json_escape STRING: STRING as it appears inside a JSON string literal (paths have no control chars).
cs_json_escape() {
  local s=${1//\\/\\\\}
  printf '%s\n' "${s//\"/\\\"}"
}

# cs_transform_row SCOPE TOKEN ROOT: one CS_ROOTS row for a native ROOT path (D:\x, /mnt/d/x, \\srv\x,
# /home/u/x). Style and case-sensitivity follow from the path form; a trailing separator is dropped.
cs_transform_row() {
  local scope=$1 token=$2 root=$3 style=p ci=0
  [[ $scope == [PRA] ]] || cs_die "$CS_EXIT_ERROR" "transform: bad scope $scope"
  if [[ $root =~ ^[A-Za-z]:([\\/]|$) || $root == \\\\* ]]; then
    style=w
    ci=1
    root=${root//\//\\}
  elif [[ $root =~ ^/mnt/[A-Za-z](/|$) ]]; then
    ci=1
  fi
  while [[ ${#root} -gt 3 && ( $root == */ || $root == *\\ ) ]]; do root=${root%?}; done
  printf '%s\t%s\t%s\t%s\t%s\n' "$scope" "$token" "$(cs_json_escape "$root")" "$style" "$ci"
}

# cs_sep_style: separator style of this machine (w on Windows, p elsewhere).
cs_sep_style() {
  if [[ $CS_OS == windows ]]; then printf 'w\n'; else printf 'p\n'; fi
}

# cs_transform MODE ROWS: stdin -> stdout (always newline-terminated output; see cs_transform_file).
cs_transform() {
  CS_MODE=$1 CS_ROOTS=$2 CS_SEP=${CS_SEP:-$(cs_sep_style)} LC_ALL=C "$CS_AWK" -v BINMODE=3 -f "$CS_TRANSFORM_AWK"
}

# cs_transform_file MODE ROWS IN OUT [OFFSET]: transform IN (from byte OFFSET, default 0) into OUT.
# A missing final newline in IN is preserved (awk would add one).
cs_transform_file() {
  local mode=$1 rows=$2 in=$3 out=$4 off=${5:-0}
  if ((off > 0)); then
    tail -c +$((off + 1)) -- "$in" | cs_transform "$mode" "$rows" >"$out" || return
  else
    cs_transform "$mode" "$rows" <"$in" >"$out" || return
  fi
  local size
  size=$(stat -c %s -- "$in")
  if ((size > off)) && [[ -n $(tail -c 1 -- "$in") ]]; then
    truncate -s -1 -- "$out"
  fi
}

# cs_complete_len FILE: byte length up to and including the last newline (0 if none). Writers append
# whole lines, so anything after the last newline is a line still being written.
cs_complete_len() {
  local f=$1 size win=65536 nr last
  size=$(stat -c %s -- "$f")
  if ((size == 0)) || [[ -z $(tail -c 1 -- "$f") ]]; then
    printf '%d\n' "$size" # empty, or ends with a newline
    return 0
  fi
  while :; do
    ((win > size)) && win=$size
    # Records in the window: the last one is the unterminated tail; its byte length is what to drop.
    read -r nr last < <(tail -c "$win" -- "$f" | LC_ALL=C "$CS_AWK" -v BINMODE=3 '{ l = length($0) } END { print NR, l }')
    if ((nr >= 2)); then
      printf '%d\n' $((size - last))
      return 0
    fi
    if ((win >= size)); then
      printf '0\n' # no newline at all
      return 0
    fi
    win=$((win * 4))
  done
}

# cs_transcript_stats FILE: "lines crs unparsable" — line count, CR bytes, lines that are not valid JSON.
# Read-only (jq never writes transcripts). Claude itself can leave a cut line mid-file, so callers
# compare stats before/after instead of demanding zero unparsable lines.
cs_transcript_stats() {
  local f=$1 lines crs bad
  lines=$(wc -l <"$f")
  crs=$(tr -cd '\r' <"$f" | wc -c)
  bad=$(jq -R -r 'try (fromjson | empty) catch "BAD"' "$f" 2>/dev/null | tr -d '\r' | grep -c BAD || true)
  printf '%d %d %d\n' "$lines" "$crs" "$bad"
}

# cs_transform_verify IN OUT: rc 0 if OUT has the same line count, CR count and unparsable-line count as
# IN (SPEC §7.2 check before any rename).
cs_transform_verify() {
  local a b
  a=$(cs_transcript_stats "$1")
  b=$(cs_transcript_stats "$2")
  [[ $a == "$b" ]] && return 0
  cs_log warn "transform verify failed: $1 [$a] -> $2 [$b]"
  return 1
}
