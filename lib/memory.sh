# shellcheck shell=bash
# memory: per-project memory files (SPEC §13 "Memory") and plan files (§13 "Plans") by a 3-way merge with a
# local base. Both kinds go through cs_dsync_run; they differ in where the files live and in what happens when
# both sides changed a file (memory: git merge-file; plans: the newer mtime wins).
#   Drive: flat objects in our machine area  m-<project>-<sha16>-<encoded rel>  /  p-<sha16>-<encoded rel>
#   manifest: memory[<project>][<rel>] / plans[<rel>] = {id, sha, deleted, mtime}
#   local:   state/base/<kind>/<scope>/<rel>   the version both sides were last known to share
#            state/base/<kind>/<scope>/.seen/<rel>   every version (sha, or DEL) ever adopted or published,
#            so that a stale manifest of another machine never rolls us back.
# Requires core, platform, version, manifest, store, claude, transform, projects, drive, root, status, engine, bundle.

[[ -n ${CS_MEMORY_LOADED:-} ]] && return 0
CS_MEMORY_LOADED=1

# cs_dsync_name_ok REL KIND: rc 1 for names that are never synced or cannot exist here (SPEC §13).
cs_dsync_name_ok() {
  local rel=$1 kind=$2 part
  local -a parts
  [[ -n $rel && $rel != /* && $rel != *..* && $rel == *.md ]] || return 1
  IFS=/ read -r -a parts <<<"$rel"
  [[ $kind == mem ]] && [[ ${parts[0]} == team || ${parts[0]} == .memory-sync* || ${parts[0]} == .seen ]] && return 1
  for part in "${parts[@]}"; do
    [[ $part == .memory-sync* ]] && return 1
    if [[ ${CS_SEP:-$(cs_sep_style)} == w ]]; then
      # shellcheck disable=SC1003 # a literal backslash
      [[ $part != *[':?*"<>|']* && $part != *'\'* && $part != *. && $part != *' ' ]] || return 1
    fi
  done
  return 0
}

cs_dsync_seen_has() { # BASEDIR REL VALUE
  [[ -f $1/.seen/$2 ]] && grep -qxF -- "$3" "$1/.seen/$2"
}
cs_dsync_seen_add() {
  mkdir -p -- "$(dirname -- "$1/.seen/$2")"
  cs_dsync_seen_has "$1" "$2" "$3" || printf '%s\n' "$3" >>"$1/.seen/$2"
}

# cs_dsync_base_set BASEDIR REL FILE|"": the base becomes FILE's content (or "no file").
cs_dsync_base_set() {
  local sha
  if [[ -n $3 ]]; then
    mkdir -p -- "$(dirname -- "$1/$2")"
    cp -- "$3" "$1/$2.tmp.$$" && mv -f -- "$1/$2.tmp.$$" "$1/$2"
    sha=$(cs_sha256_hex "$1/$2")
    cs_dsync_seen_add "$1" "$2" "$sha"
  else
    rm -f -- "$1/$2"
    cs_dsync_seen_add "$1" "$2" DEL
  fi
}

cs_dsync_man_set() { # KIND SCOPE REL JSON
  local m
  m=$(cs_eng_my_manifest)
  if [[ $1 == mem ]]; then
    m=$(cs_jq -c --arg p "$2" --arg r "$3" --argjson v "$4" '.memory[$p][$r] = $v' <<<"$m")
  else
    m=$(cs_jq -c --arg r "$3" --argjson v "$4" '.plans[$r] = $v' <<<"$m")
  fi
  cs_eng_my_manifest_save "$m"
}

# cs_dsync_conflict KIND SCOPE REL FILE MID: keep the losing content under conflicts/ and report it.
cs_dsync_conflict() {
  local d="$CS_HOME/conflicts/$1/$2" dst
  dst="$d/$3.${5:0:8}.$(date +%s)"
  mkdir -p -- "$(dirname -- "$dst")"
  cp -- "$4" "$dst"
  cs_status_patch '.memory_conflicts = (((.memory_conflicts // []) + [$f]) | unique)' --arg f "$1/$2/$3"
  cs_log warn "run: $1 $3 changed on both sides; the other version is in conflicts/"
}

# cs_dsync_merge LOCAL BASE REMOTE REL OUT: rc 0 merged cleanly into OUT; rc 1 conflict or no git.
cs_dsync_merge() {
  local rc=0
  command -v git >/dev/null 2>&1 || return 1
  git merge-file -p "$1" "$2" "$3" >"$5" 2>/dev/null || rc=$?
  ((rc == 0)) && return 0
  if [[ ${4##*/} == MEMORY.md ]] && ((rc > 0 && rc < 128)); then
    git merge-file -p --union "$1" "$2" "$3" >"$5" 2>/dev/null && return 0
  fi
  return 1
}

# cs_dsync_run KIND SCOPE LOCALDIR REL...: one 3-way pass over the named files (plus those other machines list).
cs_dsync_run() {
  local kind=$1 scope=$2 ldir=$3 base rel lf bf rf Lv bv rv st mid rid rmt bsha ms
  shift 3
  base="$CS_HOME/state/base/$kind/$scope"
  mkdir -p -- "$base" 2>/dev/null || return 0
  mkdir -p -- "$ldir" 2>/dev/null || return 0
  local -A rem=() want=()
  local r f del sha id m mt
  for r in "$@"; do want[$r]=1; done
  for f in "$CS_HOME"/state/remote/*.json; do
    [[ -f $f ]] || continue
    m=$(basename -- "$f" .json)
    while IFS=$'\t' read -r r del sha id mt; do
      [[ -n $r ]] || continue
      rem[$r]+="$del"$'\t'"$sha"$'\t'"$id"$'\t'"$m"$'\t'"$mt"$'\n'
      [[ $kind == mem ]] && want[$r]=1
      [[ $kind == plans && -n ${CS_PLAN_PREFIXES:-} ]] && {
        local pfx
        for pfx in $CS_PLAN_PREFIXES; do [[ $r == "$pfx"* ]] && want[$r]=1; done
      }
    done < <(if [[ $kind == mem ]]; then
      cs_jq -r --arg p "$scope" '.memory[$p] // {} | to_entries[] | [.key, (.value.deleted // false | tostring), (.value.sha | if (. // "") == "" then "-" else . end), (.value.id | if (. // "") == "" then "-" else . end), (.value.mtime // 0 | tostring)] | @tsv' "$f"
    else
      cs_jq -r '.plans // {} | to_entries[] | [.key, (.value.deleted // false | tostring), (.value.sha | if (. // "") == "" then "-" else . end), (.value.id | if (. // "") == "" then "-" else . end), (.value.mtime // 0 | tostring)] | @tsv' "$f"
    fi)
  done
  while IFS= read -r rel; do
    [[ -n $rel ]] && want[$rel]=1
  done < <(cd "$base" 2>/dev/null && find . -path ./.seen -prune -o -type f -name '*.md' -print | sed 's#^\./##'; cd "$ldir" 2>/dev/null && find . -type f -name '*.md' -print | sed 's#^\./##')
  for rel in "${!want[@]}"; do
    cs_dsync_name_ok "$rel" "$kind" || {
      [[ -n ${rem[$rel]:-} ]] && cs_log warn "run: $kind file skipped (name not allowed here)"
      continue
    }
    lf="$ldir/$rel"
    bf="$base/$rel"
    [[ -f $lf ]] && Lv=$(cs_sha256_hex "$lf") || Lv=DEL
    [[ -f $bf ]] && bv=$(cs_sha256_hex "$bf") || bv=DEL
    # The remote version to look at: not the base, never adopted before; the highest machine id wins.
    rv='' rid='' mid='' rmt=0
    while IFS=$'\t' read -r del sha id m mt; do
      [[ -n $m ]] || continue
      if [[ $del == true ]]; then st=DEL; else st=$sha; fi
      [[ $st == "$bv" ]] && continue
      cs_dsync_seen_has "$base" "$rel" "$st" && continue
      if [[ -z $mid || $m > $mid ]]; then rv=$st rid=$id mid=$m rmt=$mt; fi
    done <<<"${rem[$rel]:-}"
    rf=''
    if [[ -n $rv ]]; then
      if [[ $rv != DEL ]]; then
        rf="$CS_HOME/staging/dsync.$$.remote"
        drv_download "$rid" "$rf" || {
          cs_eng_note_drv $?
          continue
        }
        [[ $(cs_sha256_hex "$rf") == "$rv" ]] || {
          cs_log warn "run: $kind file has the wrong content; skipped"
          rm -f -- "$rf"
          continue
        }
      fi
      if [[ $Lv == "$rv" ]]; then
        cs_dsync_base_set "$base" "$rel" "$([[ $rv == DEL ]] || echo "$lf")"
        if [[ $rv == DEL ]]; then
          cs_dsync_man_set "$kind" "$scope" "$rel" '{"id":"","sha":"","deleted":true,"mtime":0}'
        else
          cs_dsync_man_set "$kind" "$scope" "$rel" "$(cs_jq -nc --arg id "$rid" --arg sha "$rv" --argjson mt "$rmt" '{id: $id, sha: $sha, deleted: false, mtime: $mt}')"
        fi
      elif [[ $Lv == "$bv" ]]; then
        cs_dsync_apply "$kind" "$scope" "$ldir" "$rel" "$rv" "$rf" "$rid" "$rmt" || continue
      elif [[ $rv == DEL ]]; then
        cs_log info "run: $kind $rel was deleted elsewhere but changed here; kept"
        cs_dsync_base_set "$base" "$rel" ""
      elif [[ $Lv == DEL ]]; then
        cs_dsync_apply "$kind" "$scope" "$ldir" "$rel" "$rv" "$rf" "$rid" "$rmt" || continue
      elif [[ $kind == plans ]]; then
        ms=$(stat -c %Y -- "$lf")
        if ((rmt > ms)); then
          cs_dsync_conflict "$kind" "$scope" "$rel" "$lf" "$CS_ME"
          cs_dsync_apply "$kind" "$scope" "$ldir" "$rel" "$rv" "$rf" "$rid" "$rmt" || continue
        else
          cs_dsync_conflict "$kind" "$scope" "$rel" "$rf" "$mid"
          cs_dsync_base_set "$base" "$rel" "$rf"
        fi
      else
        local mf="$CS_HOME/staging/dsync.$$.merged" bsrc="$bf"
        [[ -f $bf ]] || {
          bsrc="$CS_HOME/staging/dsync.$$.empty"
          : >"$bsrc"
        }
        if cs_dsync_merge "$lf" "$bsrc" "$rf" "$rel" "$mf"; then
          cs_dsync_write "$mf" "$lf"
          cs_dsync_base_set "$base" "$rel" "$rf"
          cs_log info "run: memory $rel merged"
        else
          cs_dsync_conflict "$kind" "$scope" "$rel" "$rf" "$mid"
          cs_dsync_base_set "$base" "$rel" "$rf"
        fi
        rm -f -- "$mf" "$CS_HOME/staging/dsync.$$.empty"
      fi
      [[ -n $rf ]] && rm -f -- "$rf"
    fi
    if cs_dsync_publish "$kind" "$scope" "$ldir" "$rel" && [[ -z $rv && $Lv != "$bv" ]]; then
      # Only a change made here: what we published is the new base.
      cs_dsync_base_set "$base" "$rel" "$([[ $Lv == DEL ]] || echo "$lf")"
    fi
  done
}

# cs_dsync_write SRC DEST: atomic replace.
cs_dsync_write() {
  mkdir -p -- "$(dirname -- "$2")"
  cp -- "$1" "$2.csync-tmp" && mv -f -- "$2.csync-tmp" "$2"
}

# cs_dsync_apply KIND SCOPE LDIR REL RV RF RID RMTIME: take the remote version (RV = sha or DEL) and advertise its object.
cs_dsync_apply() {
  local base="$CS_HOME/state/base/$1/$2" lf="$3/$4" bk mt
  if [[ $5 == DEL ]]; then
    cs_dsync_man_set "$1" "$2" "$4" '{"id":"","sha":"","deleted":true,"mtime":0}'
  else
    cs_dsync_man_set "$1" "$2" "$4" "$(cs_jq -nc --arg id "$7" --arg sha "$5" --argjson mt "${8:-0}" '{id: $id, sha: $sha, deleted: false, mtime: $mt}')"
  fi
  if [[ $5 == DEL ]]; then
    if [[ -f $lf ]]; then
      bk="$CS_HOME/backups/$1-$(date +%Y%m%dT%H%M%S)/$2/$4"
      mkdir -p -- "$(dirname -- "$bk")"
      mv -f -- "$lf" "$bk"
      cs_log info "run: $1 $4 deleted elsewhere; removed here (backup kept)"
    fi
    cs_dsync_base_set "$base" "$4" ""
  else
    cs_dsync_write "$6" "$lf"
    cs_dsync_base_set "$base" "$4" "$6"
  fi
}

# cs_dsync_publish KIND SCOPE LDIR REL: make our manifest say what the local file is (upload when it differs).
cs_dsync_publish() {
  local kind=$1 scope=$2 lf="$3/$4" cur sha id name mt prefix m
  m=$(cs_eng_my_manifest)
  if [[ $kind == mem ]]; then
    cur=$(cs_jq -c --arg p "$scope" --arg r "$4" '.memory[$p][$r] // empty' <<<"$m")
  else
    cur=$(cs_jq -c --arg r "$4" '.plans[$r] // empty' <<<"$m")
  fi
  if [[ -f $lf ]]; then
    sha=$(cs_sha256_hex "$lf")
    [[ -n $cur && $(cs_jq -r '.sha' <<<"$cur") == "$sha" && $(cs_jq -r '.deleted // false' <<<"$cur") == false ]] && return 0
    id=$(drv_generate_ids 1) || return
    if [[ $kind == mem ]]; then prefix="m-$scope"; else prefix=p; fi
    name="$prefix-${sha:0:16}-$(cs_bundle_enc "$4")"
    drv_upload "$CS_MY_AREA" "$name" "$lf" "{\"csKind\":\"$kind\",\"csSha\":\"$sha\"}" "$id" >/dev/null || {
      cs_eng_note_drv $?
      return 1
    }
    mt=$(stat -c %Y -- "$lf")
    cs_dsync_man_set "$kind" "$scope" "$4" "$(cs_jq -nc --arg id "$id" --arg sha "$sha" --argjson mt "$mt" '{id: $id, sha: $sha, deleted: false, mtime: $mt}')"
  else
    [[ -n $cur ]] || [[ -f $CS_HOME/state/base/$kind/$scope/$4 ]] || return 0
    [[ -n $cur && $(cs_jq -r '.deleted // false' <<<"$cur") == true ]] && return 0
    cs_dsync_man_set "$kind" "$scope" "$4" '{"id":"","sha":"","deleted":true,"mtime":0}'
  fi
}

# --- entry points -------------------------------------------------------------------------------------------

# cs_mem_sync: every mapped project's memory directory.
cs_mem_sync() {
  local pid memdir
  while IFS=$'\t' read -r pid memdir; do
    [[ -n $pid && -n $memdir && $memdir != - ]] || continue
    cs_dsync_run mem "$pid" "$(cs_posix_of_native "$memdir")" || true
  done < <(cs_tsv_rows projects | "$CS_AWK" -F'\t' -v OFS='\t' '$6 == 1 && !($1 in s) { s[$1] = 1; print $1, $5 }')
}

# cs_plans_sync: plan files of the slugs that our synced sessions mention.
cs_plans_sync() {
  local sid dir f slug cc pdir
  local -A slugs=()
  cc=$(cs_claude_dir)
  pdir="$cc/plans"
  while IFS=$'\t' read -r sid dir; do
    f="$CS_PDIR/$dir/$sid.jsonl"
    [[ -f $f ]] || continue
    slug=$(grep -a -o -m1 '"slug":"[A-Za-z0-9._-]*"' -- "$f" | head -n 1 | sed 's/^"slug":"//;s/"$//') || slug=''
    [[ -n $slug ]] && slugs[$slug]=1
  done < <(cs_tsv_rows sessions | "$CS_AWK" -F'\t' -v OFS='\t' '$10 == "synced" && $8 != "-" { print $1, $3 }')
  ((${#slugs[@]})) || return 0
  local -a files=()
  for slug in "${!slugs[@]}"; do
    for f in "$pdir/$slug"*.md; do
      [[ -f $f ]] && files+=("${f#"$pdir"/}")
    done
  done
  CS_PLAN_PREFIXES="${!slugs[*]}" cs_dsync_run plans plans "$pdir" "${files[@]}" || true
}
