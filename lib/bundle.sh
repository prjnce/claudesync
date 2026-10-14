# shellcheck shell=bash
# bundle: the data that travels with a session besides its main transcript (SPEC §4.3, §9.1, §13):
#   * bundle files: projects/<dir>/<sid>/** (not the subagent transcripts), <sid>.cast, <sid>.desktop-released.json,
#     tasks/<sid>/**, uploads/<sid>/**, file-history/<sid>/**. Immutable by name: a changed file is uploaded as a
#     new object and the manifest points at it (files[rel] = {m, id, sha, mode}); installs only add or replace.
#   * subagent transcripts projects/<dir>/<sid>/subagents/agent-*.jsonl: one segment chain per agent
#     (manifest subagents[agent] = an entry as for the main transcript), paths translated like the main one.
# Relative names ("rel") are relative to the Claude config dir with "projects/<dir>/" written as "_p/", so they
# are the same on every machine. Local record state/bundle/<sid>.tsv (rel, sha, size, mtime) says what was last
# synced: a file whose recorded sha equals the remote one is never downloaded again, even if Claude deleted it
# (M7). Per-agent base entries live in state/agents/<sid>/<agent>.json, with state/agents/<sid>/<agent>.rec.
# Object names are flat in the machine area: f-<sid8>-<sha8>-<encoded file name> (only for people reading Drive), t-<sid>-a-<agent>-<seq>-<sha16>.jsonl.gz.
# Requires core, platform, version, manifest, store, claude, transform, projects, drive, root, status, engine.

[[ -n ${CS_BUNDLE_LOADED:-} ]] && return 0
CS_BUNDLE_LOADED=1

# cs_bundle_enc REL: percent-encode everything but [A-Za-z0-9._-] (safe as a Drive object name).
cs_bundle_enc() {
  local s=$1 out='' c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [A-Za-z0-9._-]) out+=$c ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s\n' "$out"
}

# cs_bundle_abs DIR REL: absolute path of REL on this machine; rc 1 for names that must never be written
# (outside the config dir, never-sync list, or invalid on Windows: `:?*"<>|`, a trailing dot or space).
cs_bundle_abs() {
  local dir=$1 rel=$2 cc p part
  cc=$(cs_claude_dir)
  [[ $rel != *..* && $rel != /* && $rel != *$'\n'* ]] || return 1
  case $rel in
    _p/*) p="projects/$dir/${rel#_p/}" ;;
    tasks/* | uploads/* | file-history/*) p=$rel ;;
    *) return 1 ;;
  esac
  cs_claude_never_sync "$p" && return 1
  local -a parts
  IFS=/ read -r -a parts <<<"$rel"
  for part in "${parts[@]}"; do
    # shellcheck disable=SC1003 # a literal backslash
    [[ $part != *[':?*"<>|']* && $part != *'\'* && $part != *. && $part != *' ' ]] || return 1
  done
  printf '%s\n' "$cc/$p"
}

# cs_bundle_list SID DIR: "rel<TAB>size<TAB>mtime<TAB>mode" of every bundle file present here.
cs_bundle_find() { # PREFIX DIR: every file below DIR as "PREFIX<relative path><TAB>size<TAB>mtime<TAB>mode"
  find "$2" -type f -printf '%P\t%s\t%Ts\t%m\n' | PRE=$1 "$CS_AWK" -F'\t' -v OFS='\t' '{ $1 = ENVIRON["PRE"] $1; print }'
}

cs_bundle_list() {
  local sid=$1 dir=$2 pd cc ext top f
  pd="$CS_PDIR/$dir"
  cc=$(cs_claude_dir)
  {
    [[ -d $pd/$sid ]] && cs_bundle_find "_p/$sid/" "$pd/$sid"
    for ext in cast desktop-released.json; do
      f="$pd/$sid.$ext"
      [[ -f $f ]] && stat --printf "_p/$sid.$ext\t%s\t%Y\t%a\n" -- "$f"
    done
    for top in tasks uploads file-history; do
      [[ -d $cc/$top/$sid ]] && cs_bundle_find "$top/$sid/" "$cc/$top/$sid"
    done
    true
  } | "$CS_AWK" -F'\t' -v sid="$sid" '
    index($1, "_p/" sid "/subagents/agent-") == 1 && $1 ~ /\.jsonl$/ { next }
    $1 ~ /\.(ccr-tip|precompact)\.json$/ || $1 ~ /\.compact\.tmp\./ || $1 ~ /\.superseded-/ || $1 ~ /\.orphaned-/ || $1 ~ /\.csync-tmp/ { next }
    { print }'
}

cs_bundle_man_set() { # SID KIND KEY JSON: our manifest entry of SID gets KIND[KEY] = JSON (the session must be in it)
  local m
  m=$(cs_eng_my_manifest)
  cs_manifest_session "$m" "$1" >/dev/null || return 0
  cs_eng_my_manifest_save "$({ printf '%s\n' "$m"; printf '%s\n' "$4"; } | cs_jq -cs --arg s "$1" --arg kind "$2" --arg k "$3" \
    '.[0] as $m | .[1] as $v | $m | .sessions[$s][$kind][$k] = $v')"
}

# --- bundle files ------------------------------------------------------------------------------------------

CS_PACK_FILE_MAX=${CS_PACK_FILE_MAX:-262144} # a file up to this size travels inside a pack
CS_PACK_MAX=${CS_PACK_MAX:-4194304}          # a pack holds up to this many bytes of files ...
CS_PACK_MAX_FILES=${CS_PACK_MAX_FILES:-2000} # ... and this many files

# cs_bundle_ccrel DIR REL: REL as a path below the Claude config dir.
cs_bundle_ccrel() {
  case $2 in
    _p/*) printf 'projects/%s/%s\n' "$1" "${2#_p/}" ;;
    *) printf '%s\n' "$2" ;;
  esac
}

# cs_sha256_batch FILE...: the sha256 of each file, one per line in the same order (many files per process).
# A file that cannot be read gives an empty line.
cs_sha256_batch() {
  local out line h i
  local -a res
  while (($#)); do
    local -a chunk=("${@:1:200}")
    shift "${#chunk[@]}"
    res=()
    out=$(sha256sum -- "${chunk[@]}" 2>/dev/null || true)
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      [[ $line == "\\"* ]] && line=${line:1} # sha256sum marks names that need escaping with a leading backslash
      h=${line:0:64}
      if [[ $h =~ ^[0-9a-f]{64}$ ]]; then res+=("$h"); else res+=(""); fi
    done <<<"$out"
    if ((${#res[@]} != ${#chunk[@]})); then
      # something was unreadable: ask one by one so that the order stays right
      res=()
      for i in "${!chunk[@]}"; do res+=("$(cs_sha256_hex "${chunk[i]}" 2>/dev/null || true)"); done
    fi
    printf '%s\n' "${res[@]}"
  done
}

# cs_bundle_entry_json REL SHA MODE ID PACK: one files[] entry as JSON text (written by hand: jq -R is not safe for
# UTF-8 names on jq 1.6).
cs_bundle_entry_json() { # REL SHA MODE ID PACK
  printf '"%s":{"m":"%s","id":"%s","sha":"%s","mode":"%s"%s}' "$(cs_json_escape "$1")" "$CS_ME" "$4" "$2" "$3" "$([[ $5 == 1 ]] && printf ',"pack":1')"
}

# cs_bundle_man_merge SID JSON_OBJECT: our manifest's files[] of SID gets those entries (one jq call for all).
cs_bundle_man_merge() {
  local m
  m=$(cs_eng_my_manifest)
  cs_manifest_session "$m" "$1" >/dev/null || return 0
  cs_eng_my_manifest_save "$({ printf '%s\n' "$m"; printf '%s\n' "$2"; } | cs_jq -cs --arg s "$1" \
    '.[0] as $m | .[1] as $o | $m | .sessions[$s].files = ((.sessions[$s].files // {}) + $o)')"
}

# cs_bundle_upload_pack SID DIR IDX REL... : one pack object holding those files. Prints the entries JSON on success.
cs_bundle_upload_pack() {
  local sid=$1 dir=$2 idx=$3 cc list pk sha id rel entries='' sep=''
  shift 3
  cc=$(cs_claude_dir)
  list="$CS_HOME/staging/pack.$$.list"
  pk="$CS_HOME/staging/pack.$$.tgz"
  for rel in "$@"; do cs_bundle_ccrel "$dir" "$rel"; done >"$list"
  tar -czf "$pk" -C "$cc" --transform "s,^projects/$dir/,_p/," -T "$list" 2>/dev/null || {
    rm -f -- "$list" "$pk"
    return 1
  }
  sha=$(cs_sha256_hex "$pk")
  id=$(drv_generate_ids 1) || return
  drv_upload "$CS_MY_AREA" "f-${sid:0:8}-pack$idx-${sha:0:8}.tgz" "$pk" "{\"csKind\":\"pack\",\"csSha\":\"$sha\",\"csSid\":\"$sid\"}" "$id" >/dev/null || {
    local rc=$?
    rm -f -- "$list" "$pk"
    return "$rc"
  }
  rm -f -- "$list" "$pk"
  printf '%s\n' "$id"
}

# cs_bundle_sync SID DIR: upload new or changed bundle files (small ones together in packs: one upload for many files),
# then install what other machines have and we do not (cs_bundle_remote_install).
cs_bundle_sync() {
  local sid=$1 dir=$2 recf="$CS_HOME/state/bundle/$1.tsv" rel size mt mode sha abs i rc id
  mkdir -p -- "$CS_HOME/state/bundle"
  local -A rsha=() rsize=() rmt=()
  while IFS=$'\t' read -r rel sha size mt; do
    [[ -n $rel ]] || continue
    rsha[$rel]=$sha rsize[$rel]=$size rmt[$rel]=$mt
  done 2>/dev/null <"$recf" || true
  local inman=0
  cs_manifest_session "$(cs_eng_my_manifest)" "$sid" >/dev/null && inman=1
  # 1. files whose size or mtime differ from the record
  local -a c_rel=() c_abs=() c_size=() c_mt=() c_mode=()
  while IFS=$'\t' read -r rel size mt mode; do
    [[ -n $rel ]] || continue
    [[ ${rsize[$rel]:-} == "$size" && ${rmt[$rel]:-} == "$mt" ]] && continue
    abs=$(cs_bundle_abs "$dir" "$rel") || continue
    c_rel+=("$rel") c_abs+=("$abs") c_size+=("$size") c_mt+=("$mt") c_mode+=("$mode")
  done < <(cs_bundle_list "$sid" "$dir")
  local entries='' sep='' uploaded=0
  if ((${#c_rel[@]})); then
    # 2. their hashes, many files per process
    local -a hashes=()
    mapfile -t hashes < <(cs_sha256_batch "${c_abs[@]}")
    # 3. unchanged content (only the mtime moved) is just recorded; the rest must go up
    local -a u_idx=()
    for i in "${!c_rel[@]}"; do
      sha=${hashes[i]:-}
      [[ -n $sha ]] || continue
      if [[ ${rsha[${c_rel[i]}]:-} == "$sha" ]]; then
        rsize[${c_rel[i]}]=${c_size[i]} rmt[${c_rel[i]}]=${c_mt[i]}
      elif ((inman)); then
        u_idx+=("$i")
      fi
    done
    # 4. small files in packs, larger ones on their own
    local -a pk_idx=() big_idx=()
    for i in "${u_idx[@]}"; do
      if ((c_size[i] <= CS_PACK_FILE_MAX)) && command -v tar >/dev/null 2>&1; then pk_idx+=("$i"); else big_idx+=("$i"); fi
    done
    local -a group=() gl=()
    local gbytes=0 gn=0 pkid g
    cs_bundle_flush_group() {
      ((${#group[@]})) || return 0
      if ((${#group[@]} == 1)); then
        big_idx+=("${group[0]}")
      else
        local -a rels=()
        for g in "${group[@]}"; do rels+=("${c_rel[g]}"); done
        if pkid=$(cs_bundle_upload_pack "$sid" "$dir" "$gn" "${rels[@]}"); then
          gn=$((gn + 1))
          for g in "${group[@]}"; do
            entries+="$sep$(cs_bundle_entry_json "${c_rel[g]}" "${hashes[g]}" "${c_mode[g]}" "$pkid" 1)"
            sep=','
            rsha[${c_rel[g]}]=${hashes[g]} rsize[${c_rel[g]}]=${c_size[g]} rmt[${c_rel[g]}]=${c_mt[g]}
            uploaded=$((uploaded + 1))
          done
        else
          rc=$?
          cs_eng_note_drv "$rc"
        fi
      fi
      group=()
      gbytes=0
    }
    for i in "${pk_idx[@]}"; do
      if ((gbytes + c_size[i] > CS_PACK_MAX || ${#group[@]} >= CS_PACK_MAX_FILES)); then cs_bundle_flush_group; fi
      group+=("$i")
      gbytes=$((gbytes + c_size[i]))
    done
    cs_bundle_flush_group
    # larger files: one object each (their ids are requested together)
    if ((${#big_idx[@]})); then
      local -a ids=()
      mapfile -t ids < <(drv_generate_ids "${#big_idx[@]}") || return
      local n=0
      for i in "${big_idx[@]}"; do
        id=${ids[n]:-}
        n=$((n + 1))
        [[ -n $id ]] || continue
        if drv_upload "$CS_MY_AREA" "f-${sid:0:8}-${hashes[i]:0:8}-$(cs_bundle_enc "${c_rel[i]##*/}")" "${c_abs[i]}" \
          "{\"csKind\":\"file\",\"csSha\":\"${hashes[i]}\",\"csSid\":\"$sid\"}" "$id" >/dev/null; then
          entries+="$sep$(cs_bundle_entry_json "${c_rel[i]}" "${hashes[i]}" "${c_mode[i]}" "$id" 0)"
          sep=','
          rsha[${c_rel[i]}]=${hashes[i]} rsize[${c_rel[i]}]=${c_size[i]} rmt[${c_rel[i]}]=${c_mt[i]}
          uploaded=$((uploaded + 1))
        else
          rc=$?
          cs_eng_note_drv "$rc"
        fi
      done
    fi
  fi
  # 5. one manifest update for everything that went up
  if [[ -n $entries ]]; then
    cs_bundle_man_merge "$sid" "{$entries}"
    cs_log info "run: $uploaded bundle file(s) uploaded for $sid"
    CS_BUNDLE_UPLOADED=$((${CS_BUNDLE_UPLOADED:-0} + uploaded))
  fi
  cs_bundle_record_save "$recf" rsha rsize rmt
  cs_bundle_remote_install "$sid" "$dir"
}

cs_bundle_record_save() { # FILE ASSOC_SHA ASSOC_SIZE ASSOC_MT (names of associative arrays)
  local -n _sha=$2 _size=$3 _mt=$4
  local k
  {
    for k in "${!_sha[@]}"; do printf '%s\t%s\t%s\t%s\n' "$k" "${_sha[$k]}" "${_size[$k]:-0}" "${_mt[$k]:-0}"; done
  } | LC_ALL=C sort >"$1.tmp.$$"
  mv -f -- "$1.tmp.$$" "$1"
}

# cs_bundle_place TMPFILE ABS MODE: put an installed file in place (mode first, then rename).
cs_bundle_place() {
  mkdir -p -- "$(dirname -- "$2")"
  chmod "$3" "$1" 2>/dev/null || true
  mv -f -- "$1" "$2.csync-tmp" && mv -f -- "$2.csync-tmp" "$2"
}

# cs_bundle_remote_install SID DIR: install bundle files that another machine has and whose sha is not the one
# recorded here. Where two machines advertise different content for a name, the highest machine id wins, so every
# machine picks the same one. Files changed here in this cycle are left alone. Files that sit in a pack are fetched
# with one download per pack.
cs_bundle_remote_install() {
  local sid=$1 dir=$2 recf="$CS_HOME/state/bundle/$1.tsv" f mid rel sha id mode pack abs tmp got size mt lsha
  local -A rsha=() rsize=() rmt=() pk_list=() pk_sha=() pk_mode=() pk_abs=()
  mkdir -p -- "$CS_HOME/state/bundle"
  while IFS=$'\t' read -r rel sha size mt; do
    [[ -n $rel ]] || continue
    rsha[$rel]=$sha rsize[$rel]=$size rmt[$rel]=$mt
  done 2>/dev/null <"$recf" || true
  local cur="" any=0
  for f in "$CS_HOME"/state/remote/*.json; do
    [[ -f $f ]] || continue
    mid=$(basename -- "$f" .json)
    cur+=$(cs_jq -r --arg s "$sid" --arg m "$mid" '.sessions[$s].files // {} | to_entries[] | [.key, .value.sha, .value.id, (.value.mode // "644"), $m, ((.value.pack // 0) | tostring)] | @tsv' "$f")$'\n'
  done
  [[ -n ${cur//$'\n'/} ]] || return 0
  while IFS=$'\t' read -r rel sha id mode mid pack; do
    [[ -n $rel ]] || continue
    [[ ${rsha[$rel]:-} == "$sha" ]] && continue
    abs=$(cs_bundle_abs "$dir" "$rel") || {
      cs_log warn "run: bundle file of $sid skipped (name not allowed here): $rel"
      continue
    }
    if [[ -e $abs ]]; then
      lsha=$(cs_sha256_hex "$abs")
      if [[ $lsha == "$sha" ]]; then
        read -r size mt < <(stat -c '%s %Y' -- "$abs")
        rsha[$rel]=$sha rsize[$rel]=$size rmt[$rel]=$mt
        continue
      fi
      if [[ ${rsha[$rel]:-} != "$lsha" ]]; then
        cs_log info "run: bundle file of $sid changed on both sides; the local one is kept"
        continue
      fi
    fi
    if [[ $pack == 1 ]]; then
      pk_list[$id]+="$rel"$'\n'
      pk_sha[$rel]=$sha pk_mode[$rel]=$mode pk_abs[$rel]=$abs
      continue
    fi
    tmp="$CS_HOME/staging/bundle.$$"
    drv_download "$id" "$tmp" || {
      cs_eng_note_drv $?
      continue
    }
    got=$(cs_sha256_hex "$tmp")
    if [[ $got != "$sha" ]]; then
      cs_log warn "run: bundle file of $sid has the wrong content; skipped"
      rm -f -- "$tmp"
      continue
    fi
    cs_bundle_place "$tmp" "$abs" "$mode" || continue
    read -r size mt < <(stat -c '%s %Y' -- "$abs")
    rsha[$rel]=$sha rsize[$rel]=$size rmt[$rel]=$mt
    any=1
  done < <(printf '%s' "$cur" | "$CS_AWK" -F'\t' -v OFS='\t' '$1 != "" { if (!($1 in best) || $5 > mid[$1]) { best[$1] = $0; mid[$1] = $5 } } END { for (k in best) print best[k] }' | LC_ALL=C sort)
  # packs: one download and one extraction per pack
  local pid pk xd lst
  for pid in "${!pk_list[@]}"; do
    pk="$CS_HOME/staging/pack.$$.dl.tgz"
    xd="$CS_HOME/staging/pack.$$.x"
    lst="$CS_HOME/staging/pack.$$.need"
    drv_download "$pid" "$pk" || {
      cs_eng_note_drv $?
      continue
    }
    rm -rf -- "$xd"
    mkdir -p -- "$xd"
    printf '%s' "${pk_list[$pid]}" >"$lst"
    tar -xzf "$pk" -C "$xd" -T "$lst" 2>/dev/null || cs_log warn "run: a pack of $sid could not be unpacked completely"
    while IFS= read -r rel; do
      [[ -n $rel ]] || continue
      tmp="$xd/$rel"
      [[ -f $tmp && $(cs_sha256_hex "$tmp") == "${pk_sha[$rel]}" ]] || {
        cs_log warn "run: a file in a pack of $sid has the wrong content; skipped"
        continue
      }
      abs=${pk_abs[$rel]}
      cs_bundle_place "$tmp" "$abs" "${pk_mode[$rel]}" || continue
      read -r size mt < <(stat -c '%s %Y' -- "$abs")
      rsha[$rel]=${pk_sha[$rel]} rsize[$rel]=$size rmt[$rel]=$mt
      any=1
    done <<<"${pk_list[$pid]}"
    rm -rf -- "$xd"
    rm -f -- "$pk" "$lst"
  done
  cs_bundle_record_save "$recf" rsha rsize rmt
  ((any)) && cs_log info "run: bundle files installed for $sid"
  return 0
}

# --- subagent transcripts ----------------------------------------------------------------------------------

cs_agent_dir() { printf '%s\n' "$CS_HOME/state/agents/$1"; }

# cs_agent_init SID AGENT FILE: SPEC §12.2 for a subagent transcript that exists here and on other machines but
# has no base yet. Compares the canonical bytes of the file with the full content of each remote version (most
# segments first) and sets CS_AGENT_INIT:
#   equal    same content: the remote entry becomes our base, nothing to do
#   publish  the remote version is a prefix of the file: base adopted, the tail is a local change
#   install  the file is a prefix of (or an older version of) the remote one: install it over the file
#   conflict no relation: left as it is (forks: #20)
#   retry    a segment could not be fetched: try again next cycle
# CS_AGENT_INIT_ENTRY is the remote entry that matched, CS_AGENT_INIT_ILEN / _ISHA the part of the file it covers.
cs_agent_init() {
  local sid=$1 a=$2 f=$3 st L canon cf csz xsz rf e n i lines v1 sha size mt
  local -a gzs=()
  st=$(cs_agent_dir "$sid")
  L=$(cs_complete_len "$f")
  canon="$CS_HOME/staging/ainit.$sid.$a.canon"
  cf="$CS_HOME/staging/ainit.$sid.$a.cand"
  head -c "$L" -- "$f" | cs_transform canon "$CS_ROWS" >"$canon"
  csz=$(stat -c %s -- "$canon")
  sha=$(cs_sha256_hex "$canon")
  v1=$(cs_cum_next "$(cs_cum0 "$sid/$a")" "$sha")
  CS_AGENT_INIT=conflict CS_AGENT_INIT_ENTRY='' CS_AGENT_INIT_ILEN=0 CS_AGENT_INIT_ISHA=-
  while IFS=$'\t' read -r n e; do
    gzs=()
    for ((i = 0; i < n; i++)); do
      gzs+=("$(cs_eng_seg_fetch "$(cs_jq -c ".segs[$i]" <<<"$e")")") || break
    done
    if ((${#gzs[@]} != n)); then
      CS_AGENT_INIT=retry
      continue
    fi
    if ((n)); then gzip -dc -- "${gzs[@]}" >"$cf"; else : >"$cf"; fi
    xsz=$(stat -c %s -- "$cf")
    if ((xsz == csz)) && cmp -s -- "$canon" "$cf"; then
      CS_AGENT_INIT=equal CS_AGENT_INIT_ILEN=$L
    elif ((xsz < csz)) && head -c "$xsz" -- "$canon" | cmp -s - "$cf"; then
      lines=$(cs_jq -r .lines <<<"$e")
      CS_AGENT_INIT=publish CS_AGENT_INIT_ILEN=$(head -n "$lines" -- "$f" | wc -c)
    elif ((xsz > csz)) && head -c "$csz" -- "$cf" | cmp -s - "$canon"; then
      CS_AGENT_INIT=install
    elif cs_entry_is_ancestor "$e" "$v1"; then
      CS_AGENT_INIT=install
    else
      continue
    fi
    CS_AGENT_INIT_ENTRY=$e
    break
  done < <(for rf in "$CS_HOME"/state/remote/*.json; do
    [[ -f $rf ]] || continue
    e=$(cs_jq -c --arg s "$sid" --arg a "$a" '.sessions[$s].subagents[$a] // empty' "$rf")
    [[ -n $e ]] && printf '%s\t%s\n' "$(cs_jq '.segs | length' <<<"$e")" "$e"
    true
  done | sort -t$'\t' -k1,1nr -s)
  rm -f -- "$canon" "$cf"
  case $CS_AGENT_INIT in
    equal | publish)
      # The base is the remote entry; for a local tail the file looks changed, so that it is published.
      CS_AGENT_INIT_ISHA=$(cs_sha256_range "$f" 0 "$CS_AGENT_INIT_ILEN")
      cs_write_atomic "$st/$a.json" printf '%s\n' "$CS_AGENT_INIT_ENTRY"
      if [[ $CS_AGENT_INIT == equal ]]; then read -r size mt < <(stat -c '%s %Y' -- "$f"); else size=-1 mt=-1; fi
      printf '%s %s %s %s\n' "$CS_AGENT_INIT_ILEN" "$CS_AGENT_INIT_ISHA" "$size" "$mt" >"$st/$a.rec"
      ;;
  esac
  return 0
}

# cs_agent_sync SID DIR: for every agent of the session (local files and other machines' entries): publish local
# changes as segments, install newer remote versions.
cs_agent_sync() {
  local sid=$1 dir=$2 f a ours cand e head n best bestn ilen isha size mt lsize lmt changed exists mid rf
  local sa="$CS_PDIR/$dir/$sid/subagents" st
  st=$(cs_agent_dir "$sid")
  mkdir -p -- "$st"
  local -a ids=()
  mapfile -t ids < <({
    for f in "$sa"/agent-*.jsonl; do [[ -f $f ]] && basename -- "$f" .jsonl; done
    for f in "$CS_HOME"/state/remote/*.json; do
      [[ -f $f ]] && cs_jq -r --arg s "$sid" '.sessions[$s].subagents // {} | keys[]' "$f"
    done
    for f in "$st"/*.json; do [[ -f $f ]] && basename -- "$f" .json; done
    true
  } | sort -u)
  for a in "${ids[@]}"; do
    [[ $a =~ ^agent-[A-Za-z0-9_-]+$ ]] || continue
    f="$sa/$a.jsonl"
    ours=$(cat -- "$st/$a.json" 2>/dev/null || true)
    ilen=0 isha=- lsize=-1 lmt=-1
    [[ -f $st/$a.rec ]] && read -r ilen isha lsize lmt <"$st/$a.rec"
    exists=0 changed=0
    if [[ -f $f ]]; then
      exists=1
      read -r size mt < <(stat -c '%s %Y' -- "$f")
      [[ $size != "$lsize" || $mt != "$lmt" ]] && changed=1
    fi
    # The newest remote version we do not have, if it descends from ours.
    cand='' bestn=-1 best=''
    for rf in "$CS_HOME"/state/remote/*.json; do
      [[ -f $rf ]] || continue
      mid=$(basename -- "$rf" .json)
      e=$(cs_jq -c --arg s "$sid" --arg a "$a" '.sessions[$s].subagents[$a] // empty' "$CS_HOME/state/remote/$mid.json")
      [[ -n $e ]] || continue
      head=$(cs_jq -r .head <<<"$e")
      if [[ -n $ours ]]; then
        [[ $head == "$(cs_jq -r .head <<<"$ours")" ]] && continue
        cs_entry_is_ancestor "$ours" "$head" && continue
        cs_entry_is_ancestor "$e" "$(cs_jq -r .head <<<"$ours")" || continue
      fi
      n=$(cs_jq '.segs | length' <<<"$e")
      ((n > bestn)) && {
        bestn=$n
        best=$e
      }
    done
    cand=$best
    if [[ -n $cand ]]; then
      if ((exists && changed)) && [[ -n $ours || $ilen != 0 ]]; then
        cs_log info "run: subagent $a of $sid changed on both sides; deferred (forks: #20)"
        continue
      fi
      if ((exists && changed)); then
        cs_agent_init "$sid" "$a" "$f"
        case $CS_AGENT_INIT in
          publish) cs_agent_publish "$sid" "$a" "$f" "$CS_AGENT_INIT_ENTRY" "$CS_AGENT_INIT_ILEN" "$CS_AGENT_INIT_ISHA" || cs_eng_note_drv $? ;;
          install) cs_agent_install "$sid" "$dir" "$a" "$CS_AGENT_INIT_ENTRY" '' 0 || cs_eng_note_drv $? ;;
          conflict) cs_log info "run: subagent $a of $sid differs from the copy elsewhere and has no base; deferred (forks: #20)" ;;
        esac
        continue
      fi
      cs_agent_install "$sid" "$dir" "$a" "$cand" "$ours" "$ilen" || cs_eng_note_drv $?
    elif ((exists && changed)); then
      cs_agent_publish "$sid" "$a" "$f" "$ours" "$ilen" "$isha" || cs_eng_note_drv $?
    fi
  done
  # The manifest shows our base entry of every agent (it may have been installed before the session was).
  for f in "$st"/*.json; do
    [[ -f $f ]] || continue
    a=$(basename -- "$f" .json)
    e=$(cat -- "$f")
    [[ $(cs_jq -c --arg s "$sid" --arg a "$a" '.sessions[$s].subagents[$a] // empty' <<<"$(cs_eng_my_manifest)") == "$e" ]] ||
      cs_bundle_man_set "$sid" subagents "$a" "$e"
  done
  return 0
}

# cs_agent_publish SID AGENT FILE OURS ILEN ISHA
cs_agent_publish() {
  local sid=$1 a=$2 f=$3 ours=$4 ilen=${5:-0} isha=${6:--} seed L seg sha len lines id entry prev=0 restart=0 seq st size mt
  seed="$sid/$a"
  st=$(cs_agent_dir "$sid")
  L=$(cs_complete_len "$f")
  if [[ -n $ours ]]; then
    entry=$ours
    if [[ $(cs_sha256_range "$f" 0 "$ilen") == "$isha" ]]; then prev=$ilen; else restart=1; fi
  else
    entry=$(cs_entry_new "$seed")
  fi
  if ((L <= prev && !restart)); then
    read -r size mt < <(stat -c '%s %Y' -- "$f")
    printf '%s %s %s %s\n' "$ilen" "$isha" "$size" "$mt" >"$st/$a.rec"
    return 0
  fi
  seg="$CS_HOME/staging/aseg.$sid.$a.gz"
  tail -c +$((prev + 1)) -- "$f" | head -c $((L - prev)) | cs_transform canon "$CS_ROWS" | gzip -n -c >"$seg"
  sha=$(gzip -dc -- "$seg" | cs_sha256_hex -)
  read -r lines len < <(gzip -dc -- "$seg" | wc -lc)
  seq=$(cs_jq '.segs | length' <<<"$entry")
  id=$(drv_generate_ids 1) || return
  drv_upload "$CS_MY_AREA" "t-$sid-a-$a-$seq-${sha:0:16}.jsonl.gz" "$seg" \
    "{\"csKind\":\"seg\",\"csSha\":\"$sha\",\"csSid\":\"$sid\"}" "$id" >/dev/null || {
    local rc=$?
    rm -f -- "$seg"
    return "$rc"
  }
  rm -f -- "$seg"
  if ((restart)); then
    entry=$(cs_entry_restart "$seed" "$entry" "$CS_ME" "$id" "$len" "$lines" "$sha")
  else
    entry=$(cs_entry_append "$seed" "$entry" "$CS_ME" "$id" "$len" "$lines" "$sha")
  fi
  cs_write_atomic "$st/$a.json" printf '%s\n' "$entry"
  read -r size mt < <(stat -c '%s %Y' -- "$f")
  printf '%s %s %s %s\n' "$L" "$(cs_sha256_range "$f" 0 "$L")" "$size" "$mt" >"$st/$a.rec"
  cs_bundle_man_set "$sid" subagents "$a" "$entry"
  cs_log info "run: published subagent $a of $sid (+$lines lines)"
}

# cs_agent_install SID DIR AGENT CAND OURS ILEN
cs_agent_install() {
  local sid=$1 dir=$2 a=$3 cand=$4 ours=$5 ilen=${6:-0} f st start=0 n i tmp want got size mt
  f="$CS_PDIR/$dir/$sid/subagents/$a.jsonl"
  st=$(cs_agent_dir "$sid")
  if [[ -n $ours && -f $f ]]; then
    start=$(cs_jq --arg b "$(cs_jq -r .head <<<"$ours")" '[.segs[].cum] | index([$b])' <<<"$cand")
    if [[ $start =~ ^[0-9]+$ ]]; then start=$((start + 1)); else start=0 ilen=0; fi
  else
    ilen=0
  fi
  n=$(cs_jq '.segs | length' <<<"$cand")
  local -a gzs=()
  for ((i = start; i < n; i++)); do
    gzs+=("$(cs_eng_seg_fetch "$(cs_jq -c ".segs[$i]" <<<"$cand")")") || return 1
  done
  mkdir -p -- "$(dirname -- "$f")"
  tmp="$f.csync-tmp"
  {
    if ((ilen > 0)); then head -c "$ilen" -- "$f"; fi
    if ((${#gzs[@]})); then gzip -dc -- "${gzs[@]}" | cs_transform local "$CS_ROWS"; fi
  } >"$tmp"
  want=$(cs_jq -r .lines <<<"$cand")
  got=$(wc -l <"$tmp" | tr -d ' ')
  if [[ $got != "$want" ]]; then
    cs_log warn "run: subagent $a of $sid failed its check ($got lines, want $want)"
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$f" || return 1
  read -r size mt < <(stat -c '%s %Y' -- "$f")
  printf '%s %s %s %s\n' "$size" "$(cs_sha256_hex "$f")" "$size" "$mt" >"$st/$a.rec"
  cs_write_atomic "$st/$a.json" printf '%s\n' "$cand"
  cs_log info "run: installed subagent $a of $sid"
}
