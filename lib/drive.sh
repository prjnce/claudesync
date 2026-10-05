# shellcheck shell=bash
# drive: the narrow storage interface the engine uses (SPEC §9.1, §15.3), with pluggable backends:
#   CS_DRIVE_BACKEND=localfs  a directory that behaves like Drive (tests, SPEC §23.2)   [this file]
#   CS_DRIVE_BACKEND=gdrive   Google Drive over curl (ticket #11)
# Every drv_* function returns: 0 ok, 3 login required, 4 not found, 6 network/timeout,
# 7 retryable server error (429/5xx), 9 conflict (pre-assigned id exists with other content).
# Metadata is printed as one compact JSON object per line:
#   {id, name, mimeType, parents[], appProperties{}, md5Checksum, size, createdTime, modifiedTime, trashed}
# There is deliberately no "empty trash" or permanent delete.
# Requires lib/core.sh and lib/version.sh (cs_jq).

[[ -n ${CS_DRIVE_LOADED:-} ]] && return 0
CS_DRIVE_LOADED=1

CS_DRV_OK=0
CS_DRV_AUTH=3
CS_DRV_NOTFOUND=4
CS_DRV_NET=6
CS_DRV_RETRY=7
CS_DRV_CONFLICT=9
CS_FOLDER_MIME=application/vnd.google-apps.folder

cs_drv() {
  local op=$1
  shift
  case ${CS_DRIVE_BACKEND:-gdrive} in
    localfs) "cs_lfs_$op" "$@" ;;
    gdrive)
      cs_gd_tmp >/dev/null # create the scratch dir in this shell, before any $(...) inside the call
      "cs_gd_$op" "$@"
      ;;
    *) cs_die "$CS_EXIT_ERROR" "unknown CS_DRIVE_BACKEND=${CS_DRIVE_BACKEND}" ;;
  esac
}

drv_generate_ids() { cs_drv generate_ids "$@"; }       # N -> N ids, one per line
drv_create_folder() { cs_drv create_folder "$@"; }     # PARENT NAME PROPS_JSON [ID] -> meta
drv_upload() { cs_drv upload "$@"; }                   # PARENT NAME FILE PROPS_JSON [ID] -> meta (idempotent on ID)
drv_update_content() { cs_drv update_content "$@"; }   # ID FILE -> meta
drv_download() { cs_drv download "$@"; }               # ID OUT
drv_get_meta() { cs_drv get_meta "$@"; }               # ID -> meta (rc 4 if absent; trashed files included)
drv_list_children() { cs_drv list_children "$@"; }     # PARENT -> metas, not trashed
drv_find_by_prop() { cs_drv find_by_prop "$@"; }       # KEY VALUE -> metas with appProperties[KEY]==VALUE, not trashed
drv_changes_start_token() { cs_drv changes_start_token "$@"; } # -> token
drv_changes_list() { cs_drv changes_list "$@"; }       # TOKEN -> changed ids, then a last line "TOKEN <new>"
drv_trash() { cs_drv trash "$@"; }                     # ID -> meta (moved to trash, recoverable)
drv_server_time() { cs_drv server_time "$@"; }         # -> ISO UTC time as the server sees it
drv_about_user() { cs_drv about_user "$@"; }           # -> "Name <email>"

# ---------------------------------------------------------------------------------------------------------
# localfs backend. Layout under $CS_LFS_ROOT:
#   objects/<id>/meta.json, objects/<id>/content     changes.log ("<id>" per line; token = line count)
#   fail.<op>  remaining injected failures for op: "<code> <count>" (see cs_lfs_inject)
# ---------------------------------------------------------------------------------------------------------

cs_lfs_root() {
  [[ -n ${CS_LFS_ROOT:-} ]] || cs_die "$CS_EXIT_ERROR" "CS_LFS_ROOT is not set"
  mkdir -p -- "$CS_LFS_ROOT/objects"
  [[ -f $CS_LFS_ROOT/changes.log ]] || : >"$CS_LFS_ROOT/changes.log"
  printf '%s\n' "$CS_LFS_ROOT"
}

# cs_lfs_inject OP RC COUNT: make the next COUNT calls of OP fail with RC (tests only).
cs_lfs_inject() {
  printf '%s %s\n' "$2" "$3" >"$(cs_lfs_root)/fail.$1"
}

cs_lfs_maybe_fail() {
  local f rc n
  f="$(cs_lfs_root)/fail.$1"
  [[ -f $f ]] || return 0
  read -r rc n <"$f"
  if ((n <= 1)); then rm -f -- "$f"; else printf '%s %s\n' "$rc" $((n - 1)) >"$f"; fi
  return "$rc"
}

cs_lfs_now() {
  if [[ -n ${CS_LFS_NOW:-} ]]; then
    printf '%s\n' "$CS_LFS_NOW"
  else
    date -u +%Y-%m-%dT%H:%M:%S.%3NZ
  fi
}

cs_lfs_new_id() {
  printf 'lfs%s\n' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
}

cs_lfs_log_change() {
  printf '%s\n' "$1" >>"$(cs_lfs_root)/changes.log"
}

cs_lfs_generate_ids() {
  cs_lfs_maybe_fail generate_ids || return
  local i
  for ((i = 0; i < $1; i++)); do cs_lfs_new_id; done
}

# cs_lfs_put_meta ID JSON: write meta atomically and record the change.
cs_lfs_put_meta() {
  local d
  d="$(cs_lfs_root)/objects/$1"
  mkdir -p -- "$d"
  cs_write_atomic "$d/meta.json" printf '%s\n' "$2"
  cs_lfs_log_change "$1"
}

cs_lfs_get_meta() {
  cs_lfs_maybe_fail get_meta || return
  local f
  f="$(cs_lfs_root)/objects/$1/meta.json"
  [[ -n $1 && -f $f ]] || return "$CS_DRV_NOTFOUND"
  cs_jq -c . "$f"
}

cs_lfs_parent_ok() {
  [[ $1 == root || -f "$(cs_lfs_root)/objects/$1/meta.json" ]]
}

cs_lfs_create_folder() {
  cs_lfs_maybe_fail create_folder || return
  local parent=$1 name=$2 props=${3:-'{}'} id=${4:-} now meta
  cs_lfs_parent_ok "$parent" || return "$CS_DRV_NOTFOUND"
  [[ -n $id ]] || id=$(cs_lfs_new_id)
  if [[ -f "$(cs_lfs_root)/objects/$id/meta.json" ]]; then
    cs_lfs_get_meta "$id"
    return
  fi
  now=$(cs_lfs_now)
  meta=$(cs_jq -nc --arg id "$id" --arg n "$name" --arg p "$parent" --argjson ap "$props" --arg t "$now" --arg mime "$CS_FOLDER_MIME" \
    '{id: $id, name: $n, mimeType: $mime, parents: [$p], appProperties: $ap, md5Checksum: null, size: null,
      createdTime: $t, modifiedTime: $t, trashed: false}')
  cs_lfs_put_meta "$id" "$meta"
  printf '%s\n' "$meta"
}

cs_lfs_upload() {
  cs_lfs_maybe_fail upload || return
  local parent=$1 name=$2 file=$3 props=${4:-'{}'} id=${5:-} d md5 size now meta old
  cs_lfs_parent_ok "$parent" || return "$CS_DRV_NOTFOUND"
  [[ -f $file ]] || cs_die "$CS_EXIT_ERROR" "drv_upload: no such file: $file"
  md5=$(md5sum -- "$file")
  md5=${md5%% *}
  md5=${md5#\\}
  size=$(stat -c %s -- "$file")
  [[ -n $id ]] || id=$(cs_lfs_new_id)
  d="$(cs_lfs_root)/objects/$id"
  if [[ -f $d/meta.json ]]; then
    # Retry with a pre-assigned id (SPEC §9.1): same content -> reuse; other content -> conflict.
    old=$(cs_lfs_get_meta "$id")
    [[ $(cs_jq -r .md5Checksum <<<"$old") == "$md5" ]] || return "$CS_DRV_CONFLICT"
    printf '%s\n' "$old"
    return 0
  fi
  mkdir -p -- "$d"
  cp -- "$file" "$d/content.tmp" && mv -f -- "$d/content.tmp" "$d/content"
  now=$(cs_lfs_now)
  meta=$(cs_jq -nc --arg id "$id" --arg n "$name" --arg p "$parent" --argjson ap "$props" --arg t "$now" \
    --arg md5 "$md5" --argjson size "$size" \
    '{id: $id, name: $n, mimeType: "application/octet-stream", parents: [$p], appProperties: $ap,
      md5Checksum: $md5, size: $size, createdTime: $t, modifiedTime: $t, trashed: false}')
  cs_lfs_put_meta "$id" "$meta"
  printf '%s\n' "$meta"
}

cs_lfs_update_content() {
  cs_lfs_maybe_fail update_content || return
  local id=$1 file=$2 d md5 size meta
  d="$(cs_lfs_root)/objects/$id"
  [[ -f $d/meta.json ]] || return "$CS_DRV_NOTFOUND"
  md5=$(md5sum -- "$file")
  md5=${md5%% *}
  md5=${md5#\\}
  size=$(stat -c %s -- "$file")
  cp -- "$file" "$d/content.tmp" && mv -f -- "$d/content.tmp" "$d/content"
  meta=$(cs_jq -c --arg md5 "$md5" --argjson size "$size" --arg t "$(cs_lfs_now)" \
    '.md5Checksum = $md5 | .size = $size | .modifiedTime = $t' "$d/meta.json")
  cs_lfs_put_meta "$id" "$meta"
  printf '%s\n' "$meta"
}

cs_lfs_download() {
  cs_lfs_maybe_fail download || return
  local d
  d="$(cs_lfs_root)/objects/$1"
  [[ -f $d/content ]] || return "$CS_DRV_NOTFOUND"
  cp -- "$d/content" "$2"
}

cs_lfs_all_metas() {
  local r
  r=$(cs_lfs_root)
  compgen -G "$r/objects/*/meta.json" >/dev/null || return 0
  cs_jq -c . "$r"/objects/*/meta.json
}

cs_lfs_list_children() {
  cs_lfs_maybe_fail list_children || return
  cs_lfs_all_metas | cs_jq -c --arg p "$1" 'select(.trashed | not) | select(.parents | index([$p]))'
}

cs_lfs_find_by_prop() {
  cs_lfs_maybe_fail find_by_prop || return
  cs_lfs_all_metas | cs_jq -c --arg k "$1" --arg v "$2" 'select(.trashed | not) | select(.appProperties[$k] == $v)'
}

cs_lfs_changes_start_token() {
  cs_lfs_maybe_fail changes_start_token || return
  wc -l <"$(cs_lfs_root)/changes.log" | tr -d ' '
}

cs_lfs_changes_list() {
  cs_lfs_maybe_fail changes_list || return
  local tok=$1 log total
  [[ $tok =~ ^[0-9]+$ ]] || return "$CS_DRV_NOTFOUND"
  log="$(cs_lfs_root)/changes.log"
  total=$(wc -l <"$log" | tr -d ' ')
  tail -n +$((tok + 1)) -- "$log" | "$CS_AWK" '!seen[$0]++'
  printf 'TOKEN %s\n' "$total"
}

cs_lfs_trash() {
  cs_lfs_maybe_fail trash || return
  local f meta
  f="$(cs_lfs_root)/objects/$1/meta.json"
  [[ -f $f ]] || return "$CS_DRV_NOTFOUND"
  meta=$(cs_jq -c --arg t "$(cs_lfs_now)" '.trashed = true | .modifiedTime = $t' "$f")
  cs_lfs_put_meta "$1" "$meta"
  printf '%s\n' "$meta"
}

cs_lfs_server_time() {
  cs_lfs_maybe_fail server_time || return
  cs_lfs_now
}

cs_lfs_about_user() {
  cs_lfs_maybe_fail about_user || return
  printf '%s\n' "${CS_LFS_USER:-Local Test <test@localhost>}"
}

# cs_drive_whoami: "Name <email>" of the signed-in account (shown after login).
cs_drive_whoami() {
  drv_about_user
}

# shellcheck source=lib/auth.sh
source "${BASH_SOURCE[0]%/*}/auth.sh"
# shellcheck source=lib/gdrive.sh
source "${BASH_SOURCE[0]%/*}/gdrive.sh"
