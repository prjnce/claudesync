# shellcheck shell=bash
# fork: deterministic resolution of a session that two machines continued separately (SPEC §12.5) and the
# `conflicts` command. Every machine computes the same winner from the two canonical contents; only the machine
# that owns the losing branch creates a separate session for it, so no machine acts on another's files.
#   fork point  the first canonical line that differs
#   chat line   type is user, assistant, attachment, system or unknown; the rest is metadata (CS_META_TYPES).
#               What Claude writes when it only reopens a session is not chat either: hook attachments (hook_*) and
#               the synthetic user line of a <task-notification>. A branch made of that alone is no work to keep.
#   winner      the branch whose first chat line after the fork point has the earlier timestamp; a tie goes to the
#               lower machine_id; a branch without chat lines after the fork point loses, with no separate session
#   fork_sid    a v4-shaped UUID from sha256(sid + uuid of the loser's first chat line after the fork point)
# forks.tsv: sid losing_version fork_sid created. Requires core ... engine, bundle, memory.

[[ -n ${CS_FORK_LOADED:-} ]] && return 0
CS_FORK_LOADED=1

CS_META_TYPES=${CS_META_TYPES:-"last-prompt custom-title ai-title agent-name tag permission-mode file-history-snapshot file-history-delta attribution-snapshot queue-operation summary relocated mode worktree-state pr-link bridge-session content-replacement cost-state atis-latch frame-link artifact-comment-monitor artifact-autoreact-ledger history-suppression"}

# cs_fork_sid SID UUID: UUID in v4 shape from sha256(SID + UUID).
cs_fork_sid() {
  local h
  h=$(printf '%s%s' "$1" "$2" | cs_sha256_hex -)
  printf '%s-%s-4%s-%x%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" $((0x${h:16:1} & 3 | 8)) "${h:17:3}" "${h:20:12}"
}

# cs_fork_first_chat FILE FROM_LINE: the line number (within FILE, from FROM_LINE on) of the first chat line; 0 if none.
# t is the first "type" of the line: for an attachment that is the attachment's own type (hook_success, ...), written
# before the line's "type":"attachment".
cs_fork_first_chat() {
  tail -n +"$2" -- "$1" | LC_ALL=C "$CS_AWK" -v meta="$CS_META_TYPES" -v from="$2" '
    BEGIN { n = split(meta, a, " "); for (i = 1; i <= n; i++) m[a[i]] = 1 }
    { t = ""; if (match($0, /"type":"[^"]*"/)) t = substr($0, RSTART + 8, RLENGTH - 9)
      if (t in m || t ~ /^hook_/) next
      if (t == "user" && $0 ~ /"content":"<task-notification>/) next
      if (!found) { first = NR + from - 1; found = 1 } }
    END { print (found ? first : 0) }'
}

# cs_fork_line_info FILE LINE: "uuid<TAB>timestamp" of one line (JSON mode, never -R).
cs_fork_line_info() {
  sed -n "${2}p" -- "$1" | cs_jq -r '[(.uuid // ""), (.timestamp // "")] | @tsv'
}

# cs_fork_compare LOCAL REMOTE LOCAL_MID REMOTE_MID: sets CS_FORK_* describing the divergence:
#   CS_FORK_REL   same | local_prefix | remote_prefix | diverged
#   CS_FORK_WIN   local | remote            (diverged only)
#   CS_FORK_LOSER_UUID  uuid of the loser's first chat line ("" if the loser has none: it loses without a fork)
cs_fork_compare() {
  local l=$1 r=$2 lm=$3 rm=$4 ls rs k cl cr il ir tl tr ul ur
  CS_FORK_REL=diverged CS_FORK_WIN='' CS_FORK_LOSER_UUID=''
  ls=$(stat -c %s -- "$l") rs=$(stat -c %s -- "$r")
  if cmp -s -- "$l" "$r"; then
    CS_FORK_REL=same
    return 0
  fi
  if ((ls < rs)) && head -c "$rs" -- "$r" | head -c "$ls" | cmp -s - "$l"; then
    CS_FORK_REL=local_prefix
    return 0
  fi
  if ((rs < ls)) && head -c "$ls" -- "$l" | head -c "$rs" | cmp -s - "$r"; then
    CS_FORK_REL=remote_prefix
    return 0
  fi
  k=$(cmp -- "$l" "$r" 2>/dev/null | sed -n 's/.*line \([0-9]*\).*/\1/p') || true
  [[ $k =~ ^[0-9]+$ ]] || k=1
  cl=$(cs_fork_first_chat "$l" "$k") || cl=0
  cr=$(cs_fork_first_chat "$r" "$k") || cr=0
  if ((cl == 0 && cr == 0)); then
    [[ $lm < $rm ]] && CS_FORK_WIN=local || CS_FORK_WIN=remote
  elif ((cl == 0)); then
    CS_FORK_WIN=remote
  elif ((cr == 0)); then
    CS_FORK_WIN=local
  else
    IFS=$'\t' read -r ul tl < <(cs_fork_line_info "$l" "$cl")
    IFS=$'\t' read -r ur tr < <(cs_fork_line_info "$r" "$cr")
    if [[ $tl < $tr ]]; then
      CS_FORK_WIN=local
    elif [[ $tl > $tr ]]; then
      CS_FORK_WIN=remote
    elif [[ $lm < $rm ]]; then
      CS_FORK_WIN=local
    else
      CS_FORK_WIN=remote
    fi
    il=$ul ir=$ur
    if [[ $CS_FORK_WIN == local ]]; then CS_FORK_LOSER_UUID=$ir; else CS_FORK_LOSER_UUID=$il; fi
    [[ -n $CS_FORK_LOSER_UUID ]] || CS_FORK_LOSER_UUID="line-$k"
  fi
  return 0
}

# cs_fork_resolve SID FILE PID DIR CMID CHANGED: decide between our file and machine CMID's version.
# CS_FORK_RESULT: local_wins (ignore the candidate, carry on), remote_extends (install it as usual),
# handled (we lost and have already installed the winner), deferred (try again later).
cs_fork_resolve() {
  local sid=$1 f=$2 pid=$3 dir=$4 cmid=$5 e lc rc L lv fork lt ts ct ep
  CS_FORK_RESULT=deferred
  e=$(cs_eng_remote_entry "$cmid" "$sid") || return 0
  lc="$CS_HOME/staging/fork.$sid.local"
  rc="$CS_HOME/staging/fork.$sid.remote"
  L=$(cs_complete_len "$f")
  head -c "$L" -- "$f" | cs_transform canon "$CS_ROWS" >"$lc"
  local n i
  local -a gzs=()
  n=$(cs_jq '.segs | length' <<<"$e")
  for ((i = 0; i < n; i++)); do
    gzs+=("$(cs_eng_seg_fetch "$(cs_jq -c ".segs[$i]" <<<"$e")")") || {
      rm -f -- "$lc"
      return 0
    }
  done
  if ((n)); then gzip -dc -- "${gzs[@]}" >"$rc"; else : >"$rc"; fi
  cs_fork_compare "$lc" "$rc" "$CS_ME" "$cmid"
  case $CS_FORK_REL in
    same | local_prefix | remote_prefix)
      # Not a divergence after all: a prefix is a plain fast-forward either way.
      if [[ $CS_FORK_REL == remote_prefix ]]; then CS_FORK_RESULT=local_wins; else CS_FORK_RESULT=remote_extends; fi
      [[ $CS_FORK_REL == same ]] && CS_FORK_RESULT=remote_extends
      rm -f -- "$lc" "$rc"
      return 0
      ;;
  esac
  if [[ $CS_FORK_WIN == local ]]; then
    CS_FORK_RESULT=local_wins
    cs_log info "run: $sid diverged from $cmid; this machine's branch wins, nothing to do until the other machine forks"
    rm -f -- "$lc" "$rc"
    return 0
  fi
  if cs_claude_live_sessions | cut -f1 | grep -qx "$sid"; then
    cs_log info "run: $sid is open and lost to $cmid; resolved when it is closed"
    rm -f -- "$lc" "$rc"
    return 0
  fi
  # We lost. The version others saw of our branch (or the one we would have published).
  lv=$(cs_jq -r --arg s "$sid" '.sessions[$s].head // empty' <<<"$(cs_eng_my_manifest)")
  [[ ${6:-0} == 1 || -z $lv ]] && lv=$(cs_cum_next "$(cs_cum0 "$sid")" "$(cs_sha256_hex "$lc")")
  if [[ -n $CS_FORK_LOSER_UUID ]]; then
    fork=$(cs_fork_sid "$sid" "$CS_FORK_LOSER_UUID")
    cs_fork_materialize "$sid" "$fork" "$f" "$dir" "$pid" "$e" || {
      rm -f -- "$lc" "$rc"
      return 0
    }
  else
    mkdir -p -- "$CS_HOME/backups"
    cp -- "$f" "$CS_HOME/backups/fork-$sid-$(date +%Y%m%dT%H%M%S).jsonl"
    fork=''
    cs_log info "run: $sid: our branch only differs in metadata; saved a backup and took the other version"
  fi
  rm -f -- "$lc" "$rc"
  CS_INSTALL_FORCE=1 cs_eng_install "$sid" "$e" "$dir" 0 '' || return 0
  CS_FORK_RESULT=handled
  if [[ -n $fork ]]; then
    cs_fork_man_forked "$sid" "$lv" "$fork"
    printf '%s\t%s\t%s\t%s\n' "$sid" "$lv" "$fork" "$(date +%s)" | cs_tsv_upsert_many forks
    cs_log warn "run: $sid forked: our branch is now session $fork"
  fi
  return 0
}

# cs_fork_known_from_manifests: versions that other machines forked away (forked{} in their manifests) are never
# candidates here again.
cs_fork_known_from_manifests() {
  local f sid v
  for f in "$CS_HOME"/state/remote/*.json; do
    [[ -f $f ]] || continue
    while IFS=$'\t' read -r sid v; do
      [[ -n $sid && -n $v ]] && cs_known_add "$sid" "$v"
    done < <(cs_jq -r '.sessions | to_entries[] | .key as $s | (.value.forked // {} | keys[]) | [$s, .] | @tsv' "$f")
  done
  return 0
}

cs_fork_man_forked() { # SID LOSING_VERSION FORK_SID
  cs_eng_my_manifest_save "$(cs_jq -c --arg s "$1" --arg v "$2" --arg f "$3" '.sessions[$s].forked[$v] = $f' <<<"$(cs_eng_my_manifest)")"
}

# cs_fork_title FILE: the title the session shows, as the text of a JSON string (escapes kept): the last customTitle
# (a /rename), else the last aiTitle (Claude's own), else "(untitled)". A customTitle hides the aiTitle, so the
# conflict title must carry the real one.
cs_fork_title() {
  local k t=''
  for k in customTitle aiTitle; do
    t=$(grep -a -o -E "\"$k\":\"([^\"\\\\]|\\\\.)*\"" -- "$1" | tail -n 1 | sed "s/^\"$k\":\"//;s/\"\$//") || t=''
    [[ -n $t ]] && break
  done
  printf '%s\n' "${t:-(untitled)}"
}

# cs_fork_materialize SID FORK FILE DIR PID WINNER_ENTRY: the losing branch as a session of its own.
cs_fork_materialize() {
  local sid=$1 fork=$2 f=$3 dir=$4 pid=$5 pd cc title slug nslug mt wmt tmp d x
  pd="$CS_PDIR/$dir"
  cc=$(cs_claude_dir)
  for x in "$CS_PDIR"/*/"$fork.jsonl"; do
    [[ -f $x ]] && return 0 # already there: running again creates nothing
  done
  title=$(cs_fork_title "$f")
  slug=$(grep -a -o -m1 '"slug":"[A-Za-z0-9._-]*"' -- "$f" | head -n 1 | sed 's/^"slug":"//;s/"$//') || slug=''
  nslug=''
  [[ -n $slug ]] && nslug="$slug-c${fork:0:4}"
  # bundle first, transcript last
  if [[ -d $pd/$sid ]]; then
    cp -a -- "$pd/$sid" "$pd/$fork"
    for x in "$pd/$fork"/subagents/agent-*.jsonl; do
      [[ -f $x ]] || continue
      LC_ALL=C "$CS_AWK" -v BINMODE=3 -v s="$sid" -v n="$fork" '{ gsub("\"sessionId\":\"" s "\"", "\"sessionId\":\"" n "\""); print }' "$x" >"$x.csync-tmp" && mv -f -- "$x.csync-tmp" "$x"
    done
    printf '{"customTitle":"[conflict %s] %s"}\n' "$(cs_config_get machine_name "")" "$title" >"$pd/$fork/custom-title.json"
  fi
  for d in cast desktop-released.json; do
    [[ -f $pd/$sid.$d ]] && cp -- "$pd/$sid.$d" "$pd/$fork.$d"
  done
  [[ -d $cc/file-history/$sid ]] && cp -a -- "$cc/file-history/$sid" "$cc/file-history/$fork"
  if [[ -n $slug ]]; then
    for x in "$cc/plans/$slug"*.md; do
      [[ -f $x ]] && cp -- "$x" "$cc/plans/$nslug${x##*/"$slug"}"
    done
  fi
  tmp="$pd/$fork.jsonl.csync-tmp"
  {
    LC_ALL=C "$CS_AWK" -v BINMODE=3 -v s="$sid" -v n="$fork" -v sl="$slug" -v nsl="$nslug" '
      { gsub("\"sessionId\":\"" s "\"", "\"sessionId\":\"" n "\"")
        if (sl != "") gsub("\"slug\":\"" sl "\"", "\"slug\":\"" nsl "\"")
        print }' "$f"
    printf '{"type":"custom-title","customTitle":"[conflict %s] %s","sessionId":"%s"}\n' "$(cs_config_get machine_name "")" "$title" "$fork"
  } >"$tmp"
  mt=$(stat -c %Y -- "$f")
  wmt=$(cs_jq -r '.mtime // empty' <<<"$6")
  [[ $wmt =~ ^[0-9]+$ ]] && ((wmt - 1 < mt)) && mt=$((wmt - 1))
  touch -d "@$mt" -- "$tmp"
  mv -f -- "$tmp" "$pd/$fork.jsonl"
}

# --- conflicts command -----------------------------------------------------------------------------------------------

cs_conflicts() {
  local sub=${1:-list} sid fork lv ts when
  shift || true
  case $sub in
    list)
      local any=0
      while IFS=$'\t' read -r sid lv fork ts; do
        [[ -n $sid ]] || continue
        any=1
        when=$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$ts")
        cs_say conflicts.row "$sid" "$fork" "$when"
      done < <(cs_tsv_rows forks)
      [[ -f $CS_HOME/state/status.json ]] && while IFS= read -r x; do
        [[ -n $x ]] || continue
        any=1
        cs_say conflicts.memory "$x"
      done < <(cs_jq -r '.memory_conflicts[]?' "$CS_HOME/state/status.json")
      ((any)) || cs_say conflicts.none
      ;;
    show)
      sid=${1:-}
      [[ -n $sid ]] || cs_die_t "$CS_EXIT_USAGE" conflicts.usage
      local found=0
      while IFS=$'\t' read -r s lv fork ts; do
        [[ $s == "$sid" || $fork == "$sid" ]] || continue
        found=1
        cs_say conflicts.show "$s" "$fork" "$lv" "$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$ts")"
      done < <(cs_tsv_rows forks)
      ((found)) || cs_die_t "$CS_EXIT_ERROR" conflicts.unknown "$sid"
      ;;
    *) cs_die_t "$CS_EXIT_USAGE" conflicts.usage ;;
  esac
}
