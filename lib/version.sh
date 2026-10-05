# shellcheck shell=bash
# version: transcript versions as segment chains (SPEC §10). Pure functions, no Drive access.
#   cum_0 = sha256("claude-sync:" + sid)
#   cum_k = sha256(hex(cum_{k-1}) + hex(sha256(seg_k)))      (hex strings concatenated as ASCII)
#   version_id = cum of the last segment.
# A manifest session entry (SPEC §9.2) holds head, len, lines, segs[{m,id,len,sha,cum}] and from[].
# from[] accumulates every version id a rewrite or compaction replaced, so ancestry is plain membership:
#   ancestor(a, v) <=> a == v.head or a is a cum of v.segs or a is in v.from.
# Requires lib/core.sh. JSON is handled with jq (manifests are ours, never transcripts); CR is stripped.

[[ -n ${CS_VERSION_LOADED:-} ]] && return 0
CS_VERSION_LOADED=1

CS_CHAIN_MAX_SEGS=50  # compact a chain that grows beyond this many segments
CS_FROM_MAX=500       # cap on from[] (oldest dropped); rewrites are rare

# cs_sha256_hex [FILE]: sha256 of FILE or stdin, hex only (MSYS prints "hash *name").
cs_sha256_hex() {
  local h
  h=$(sha256sum -- "${1:--}") || return
  printf '%s\n' "${h%% *}"
}

# cs_sha256_range FILE OFFSET LENGTH: sha256 hex of LENGTH bytes starting at byte OFFSET.
cs_sha256_range() {
  tail -c +$(($2 + 1)) -- "$1" | head -c "$3" | cs_sha256_hex -
}

cs_cum0() {
  printf 'claude-sync:%s' "$1" | cs_sha256_hex -
}

# cs_cum_next PREV_CUM SEG_SHA -> next cum.
cs_cum_next() {
  printf '%s%s' "$1" "$2" | cs_sha256_hex -
}

# cs_chain_cums SID SEG_SHA...: one cum per segment, in order.
cs_chain_cums() {
  local c
  c=$(cs_cum0 "$1")
  shift
  local s
  for s in "$@"; do
    c=$(cs_cum_next "$c" "$s")
    printf '%s\n' "$c"
  done
}

# cs_jq ARGS...: jq with CR stripped (native jq on Windows writes CRLF). Returns jq's own exit status,
# with or without pipefail, so `cs_jq -e` keeps working in conditions.
cs_jq() {
  jq "$@" | tr -d '\r'
  return "${PIPESTATUS[0]}"
}

# cs_entry_new SID: an empty session entry (no segments yet; head = cum_0).
cs_entry_new() {
  cs_jq -nc --arg h "$(cs_cum0 "$1")" '{head: $h, len: 0, lines: 0, segs: [], from: []}'
}

# cs_entry_append SID ENTRY MACHINE FILE_ID LEN LINES SHA: entry with one more segment (append case).
# LEN/LINES are the segment's own bytes/lines; head, len and lines are updated.
cs_entry_append() {
  local sid=$1 entry=$2 m=$3 id=$4 len=$5 lines=$6 sha=$7 prev cum
  prev=$(cs_jq -r '.head' <<<"$entry")
  [[ $prev =~ ^[0-9a-f]{64}$ ]] || cs_die "$CS_EXIT_ERROR" "version: bad head in entry for $sid"
  cum=$(cs_cum_next "$prev" "$sha")
  cs_jq -c --arg m "$m" --arg id "$id" --argjson len "$len" --argjson lines "$lines" --arg sha "$sha" --arg cum "$cum" \
    '.segs += [{m: $m, id: $id, len: $len, sha: $sha, cum: $cum}] | .head = $cum | .len += $len | .lines += $lines' <<<"$entry"
}

# cs_entry_restart SID ENTRY MACHINE FILE_ID LEN LINES SHA: a new chain whose segment 0 is the whole
# content (rewrite or compaction); every version id of the old chain moves into from[].
cs_entry_restart() {
  local sid=$1 entry=$2 m=$3 id=$4 len=$5 lines=$6 sha=$7 cum
  cum=$(cs_cum_next "$(cs_cum0 "$sid")" "$sha")
  cs_jq -c --arg m "$m" --arg id "$id" --argjson len "$len" --argjson lines "$lines" --arg sha "$sha" --arg cum "$cum" \
    --argjson max "$CS_FROM_MAX" '
    ((.from // []) + [.segs[].cum] + [.head]) as $old
    | {head: $cum, len: $len, lines: $lines,
       segs: [{m: $m, id: $id, len: $len, sha: $sha, cum: $cum}],
       from: ($old | map(select(. != $cum)) | reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end) | .[-$max:])}
    + (if .forked then {forked} else {} end)' <<<"$entry"
}

# cs_entry_needs_compaction ENTRY: rc 0 when the chain is longer than CS_CHAIN_MAX_SEGS.
cs_entry_needs_compaction() {
  [[ $(cs_jq '.segs | length' <<<"$1") -gt $CS_CHAIN_MAX_SEGS ]]
}

# cs_entry_is_ancestor ENTRY VERSION: rc 0 if VERSION is the entry's head, one of its segment cums or in from[].
cs_entry_is_ancestor() {
  cs_jq -e --arg a "$2" '([.head] + [.segs[].cum] + (.from // [])) | any(. == $a)' <<<"$1" >/dev/null
}

# cs_entry_verify SID ENTRY: rc 0 if the cums of segs[] recompute from their shas and head is the last cum.
cs_entry_verify() {
  local sid=$1 entry=$2 shas cums want
  mapfile -t shas < <(cs_jq -r '.segs[].sha' <<<"$entry")
  mapfile -t want < <(cs_jq -r '.segs[].cum' <<<"$entry")
  ((${#shas[@]})) || {
    [[ $(cs_jq -r .head <<<"$entry") == "$(cs_cum0 "$sid")" ]]
    return
  }
  mapfile -t cums < <(cs_chain_cums "$sid" "${shas[@]}")
  [[ "${cums[*]}" == "${want[*]}" && $(cs_jq -r .head <<<"$entry") == "${cums[-1]}" ]]
}
