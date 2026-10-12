# shellcheck shell=bash
# gdrive: the Google Drive backend of the drv_* interface (SPEC §9.1, §15.3), curl + jq.
# Requires lib/core.sh, lib/platform.sh, lib/version.sh, lib/auth.sh; sourced by lib/drive.sh.
# Every request: supportsAllDrives=true; metadata normalized to the drv_* shape (size as a number,
# appProperties {} and md5Checksum null when absent). Never logs tokens or file contents.

[[ -n ${CS_GDRIVE_LOADED:-} ]] && return 0
CS_GDRIVE_LOADED=1

CS_GD_API=${CS_GD_API:-https://www.googleapis.com/drive/v3}
CS_GD_UPLOAD=${CS_GD_UPLOAD:-https://www.googleapis.com/upload/drive/v3}
CS_GD_FIELDS='id,name,mimeType,parents,appProperties,md5Checksum,size,createdTime,modifiedTime,trashed'
CS_GD_MULTIPART_MAX=${CS_GD_MULTIPART_MAX:-5242880}   # <= 5 MB: multipart; larger: resumable
CS_GD_CHUNK=${CS_GD_CHUNK:-4194304}                   # resumable chunk (4 MiB), a multiple of 256 KiB
CS_GD_RETRIES=${CS_GD_RETRIES:-5}
CS_GD_NET_RETRIES=${CS_GD_NET_RETRIES:-3}                # tries for a request that got no answer at all
CS_GD_BACKOFF_BASE=${CS_GD_BACKOFF_BASE:-1}           # seconds; tests set 0
CS_GD_NORM='{id, name, mimeType, parents: (.parents // []), appProperties: (.appProperties // {}),
  md5Checksum: (.md5Checksum // null), size: (if .size then (.size | tonumber) else null end),
  createdTime, modifiedTime, trashed: (.trashed // false)}'

cs_gd_tmp() {
  if [[ -z ${CS_GD_TMPDIR:-} || ! -d $CS_GD_TMPDIR ]]; then
    CS_GD_TMPDIR=$(mktemp -d)
  fi
  printf '%s\n' "$CS_GD_TMPDIR"
}

# cs_gd_backoff ATTEMPT: sleep base * 2^(attempt-1) plus up to 1 s of jitter.
cs_gd_backoff() {
  local s=$((CS_GD_BACKOFF_BASE * (1 << ($1 - 1))))
  ((CS_GD_BACKOFF_BASE == 0)) && return 0
  sleep "$s.$((RANDOM % 1000))"
}

# cs_gd METHOD URL [CURL ARGS...]: one authorized request with retries. Body on stdout (or into the file
# named by GD_OUT); response headers stay in $(cs_gd_tmp)/hdr. rc follows the drv_* convention.
#   401 -> refresh the token once and retry; 403 rate limit, 429, 5xx -> exponential backoff with jitter;
#   404 -> 4; 409 -> 9; other 4xx -> 1; network/timeout -> 6.
cs_gd() {
  local method=$1 url=$2 dir body hdr code attempt=0 rejected='' out=${GD_OUT:-}
  shift 2
  dir=$(cs_gd_tmp)
  body=$dir/body
  hdr=$dir/hdr
  [[ -n $out ]] || out=$body
  while :; do
    cs_access_token_ensure "$rejected" || return
    code=$(nat curl -sS --connect-timeout 10 --max-time "${CS_GD_MAX_TIME:-300}" -X "$method" \
      -H "Authorization: Bearer $CS_ACCESS_TOKEN" -D "$(cs_to_win "$hdr")" -o "$(cs_to_win "$out")" \
      -w '%{http_code}' "$@" "$url" 2>"$dir/err") || code=000
    case $code in
      2??)
        [[ -n ${GD_OUT:-} ]] || tr -d '\r' <"$body"
        return 0
        ;;
      401)
        if [[ -z $rejected ]]; then
          rejected=$CS_ACCESS_TOKEN
          continue
        fi
        return "$CS_DRV_AUTH"
        ;;
      404 | 410)
        [[ -n ${GD_OUT:-} ]] && rm -f -- "$out"
        return "$CS_DRV_NOTFOUND"
        ;;
      409) return "$CS_DRV_CONFLICT" ;;
      403 | 429 | 5??)
        if [[ $code == 403 ]] && ! grep -qE 'rateLimitExceeded|userRateLimitExceeded' "$out" 2>/dev/null; then
          cs_log warn "drive: $method ${url%%\?*} -> 403 $(cs_jq -r '.error.message // empty' <"$out" 2>/dev/null)"
          return 1
        fi
        attempt=$((attempt + 1))
        if ((attempt > CS_GD_RETRIES)); then
          cs_log warn "drive: $method ${url%%\?*} -> $code after $CS_GD_RETRIES retries"
          return "$CS_DRV_RETRY"
        fi
        cs_gd_backoff "$attempt"
        ;;
      000)
        # a request that never got an answer: try again a few times (uploads carry a pre-assigned id, so a repeat is safe)
        attempt=$((attempt + 1))
        cs_log warn "drive: $method ${url%%\?*} -> network error ($(head -c 200 "$dir/err" 2>/dev/null | tr -d '\r' | head -n 1)) attempt $attempt"
        if ((attempt >= CS_GD_NET_RETRIES)); then return "$CS_DRV_NET"; fi
        cs_gd_backoff "$attempt"
        ;;
      *)
        cs_log warn "drive: $method ${url%%\?*} -> $code $(cs_jq -r '.error.message // empty' <"$out" 2>/dev/null)"
        return 1
        ;;
    esac
  done
}

# cs_gd_header NAME: a header of the last response (case-insensitive name).
cs_gd_header() {
  local h
  h=$(tr -d '\r' <"$(cs_gd_tmp)/hdr" 2>/dev/null | "$CS_AWK" -v n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" '
    { l = tolower($0); if (index(l, n ":") == 1) { v = substr($0, length(n) + 2); sub(/^[ \t]+/, "", v); last = v } }
    END { print last }')
  printf '%s\n' "$h"
}

cs_gd_norm() {
  cs_jq -c "$CS_GD_NORM"
}

# cs_gd_q_literal S: S as a Drive query string literal ('...' with \ and ' escaped).
cs_gd_q_literal() {
  local s=${1//\\/\\\\}
  printf "'%s'\n" "${s//\'/\\\'}"
}

cs_gd_md5() {
  local m
  m=$(md5sum -- "$1")
  m=${m%% *}
  printf '%s\n' "${m#\\}"
}

cs_gd_generate_ids() {
  cs_gd GET "$CS_GD_API/files/generateIds?count=$1&space=drive&type=files" | cs_jq -r '.ids[]'
  return "${PIPESTATUS[0]}"
}

cs_gd_get_meta() {
  local r
  r=$(cs_gd GET "$CS_GD_API/files/$1?fields=$CS_GD_FIELDS&supportsAllDrives=true") || return
  cs_gd_norm <<<"$r"
}

cs_gd_create_folder() {
  local parent=$1 name=$2 props=${3:-'{}'} id=${4:-} meta r rc=0
  meta=$(cs_jq -nc --arg n "$name" --arg p "$parent" --argjson ap "$props" --arg id "$id" --arg mime "$CS_FOLDER_MIME" \
    '{name: $n, mimeType: $mime, parents: [$p], appProperties: $ap} + (if $id != "" then {id: $id} else {} end)')
  r=$(cs_gd POST "$CS_GD_API/files?fields=$CS_GD_FIELDS&supportsAllDrives=true" \
    -H 'Content-Type: application/json; charset=UTF-8' --data-binary "$meta") || rc=$?
  if ((rc == CS_DRV_CONFLICT)) && [[ -n $id ]]; then
    cs_gd_get_meta "$id"
    return
  fi
  ((rc == 0)) || return "$rc"
  cs_gd_norm <<<"$r"
}

# cs_gd_meta_json PARENT NAME PROPS ID -> upload metadata JSON.
cs_gd_meta_json() {
  cs_jq -nc --arg n "$2" --arg p "$1" --argjson ap "${3:-'{}'}" --arg id "${4:-}" \
    '{name: $n, parents: [$p], appProperties: $ap, mimeType: "application/octet-stream"} + (if $id != "" then {id: $id} else {} end)'
}

# cs_gd_check_md5 META FILE: rc 0 if Drive's md5Checksum matches the local file.
cs_gd_check_md5() {
  local want got
  want=$(cs_gd_md5 "$2")
  got=$(cs_jq -r '.md5Checksum // empty' <<<"$1")
  [[ $got == "$want" ]] && return 0
  cs_log warn "drive: md5 mismatch after transfer (local $want, drive ${got:-none})"
  return 1
}

# cs_gd_upload PARENT NAME FILE PROPS [ID]: multipart up to 5 MB, resumable above. With a pre-assigned
# ID an existing object with the same content is reused; other content -> rc 9.
cs_gd_upload() {
  local parent=$1 name=$2 file=$3 props=${4:-'{}'} id=${5:-} size meta mf r rc=0
  size=$(stat -c %s -- "$file")
  if ((size > CS_GD_MULTIPART_MAX)); then
    r=$(cs_gd_upload_resumable "$parent" "$name" "$file" "$props" "$id") || rc=$?
  else
    mf="$(cs_gd_tmp)/meta.json"
    cs_gd_meta_json "$parent" "$name" "$props" "$id" >"$mf"
    r=$(cs_gd POST "$CS_GD_UPLOAD/files?uploadType=multipart&fields=$CS_GD_FIELDS&supportsAllDrives=true" \
      -F "metadata=<$(cs_to_win "$mf");type=application/json;charset=UTF-8" \
      -F "file=@$(cs_to_win "$file");type=application/octet-stream") || rc=$?
  fi
  if ((rc == CS_DRV_CONFLICT)) && [[ -n $id ]]; then
    r=$(cs_gd_get_meta "$id") || return
    cs_gd_check_md5 "$r" "$file" || return "$CS_DRV_CONFLICT"
    printf '%s\n' "$r"
    return 0
  fi
  ((rc == 0)) || return "$rc"
  r=$(cs_gd_norm <<<"$r")
  cs_gd_check_md5 "$r" "$file" || {
    cs_log warn "drive: the uploaded object $name does not have the md5 of the local file"
    return 1
  }
  printf '%s\n' "$r"
}

# cs_gd_upload_resumable PARENT NAME FILE PROPS [ID]: resumable upload in CS_GD_CHUNK pieces. When
# CS_GD_RESUME_FILE names a file, the session URI is kept there so a later run continues the upload.
# Chunks are streamed from the source (no temp copies: first reads of fresh files are slow, SPEC R2).
cs_gd_upload_resumable() {
  local parent=$1 name=$2 file=$3 props=${4:-'{}'} id=${5:-} size uri='' off=0 n code range out rc
  size=$(stat -c %s -- "$file")
  [[ -n ${CS_GD_RESUME_FILE:-} && -s $CS_GD_RESUME_FILE ]] && uri=$(<"$CS_GD_RESUME_FILE")
  if [[ -n $uri ]]; then
    # Ask the session how much it already has.
    code=$(cs_gd_put_chunk "$uri" '*' "$size" /dev/null 0) || code=000
    case $code in
      200 | 201)
        cs_gd_finish_resumable
        return
        ;;
      308)
        range=$(cs_gd_header range)
        [[ $range =~ bytes=0-([0-9]+) ]] && off=$((BASH_REMATCH[1] + 1))
        ;;
      *) uri= ;; # expired or unknown: start a new session
    esac
  fi
  if [[ -z $uri ]]; then
    cs_gd POST "$CS_GD_UPLOAD/files?uploadType=resumable&fields=$CS_GD_FIELDS&supportsAllDrives=true" \
      -H 'Content-Type: application/json; charset=UTF-8' -H 'X-Upload-Content-Type: application/octet-stream' \
      -H "X-Upload-Content-Length: $size" --data-binary "$(cs_gd_meta_json "$parent" "$name" "$props" "$id")" >/dev/null || return
    uri=$(cs_gd_header location)
    [[ -n $uri ]] || return 1
    [[ -n ${CS_GD_RESUME_FILE:-} ]] && printf '%s\n' "$uri" >"$CS_GD_RESUME_FILE"
    off=0
  fi
  local attempt=0
  while ((off < size)); do
    n=$((size - off < CS_GD_CHUNK ? size - off : CS_GD_CHUNK))
    code=$(cs_gd_put_chunk "$uri" "$off" "$size" "$file" "$n") || code=000
    case $code in
      200 | 201)
        cs_gd_finish_resumable
        return
        ;;
      308)
        range=$(cs_gd_header range)
        if [[ $range =~ bytes=0-([0-9]+) ]]; then off=$((BASH_REMATCH[1] + 1)); else off=0; fi
        attempt=0
        ;;
      404 | 410)
        [[ -n ${CS_GD_RESUME_FILE:-} ]] && : >"$CS_GD_RESUME_FILE"
        return "$CS_DRV_NOTFOUND"
        ;;
      *)
        attempt=$((attempt + 1))
        cs_log warn "drive: resumable chunk at $off of $size -> $code $(cs_jq -r '.error.message // empty' <"$(cs_gd_tmp)/body" 2>/dev/null | head -n 1) $(head -c 160 "$(cs_gd_tmp)/err" 2>/dev/null | tr -d '\r' | head -n 1) (attempt $attempt)"
        if ((attempt > CS_GD_RETRIES)); then return "$CS_DRV_RETRY"; fi
        cs_gd_backoff "$attempt"
        # the server may have kept part of the chunk: ask how much it has and go on from there
        code=$(cs_gd_put_chunk "$uri" '*' "$size" /dev/null 0) || code=000
        case $code in
          308)
            range=$(cs_gd_header range)
            if [[ $range =~ bytes=0-([0-9]+) ]]; then off=$((BASH_REMATCH[1] + 1)); else off=0; fi
            ;;
          200 | 201)
            cs_gd_finish_resumable
            return
            ;;
          404 | 410)
            [[ -n ${CS_GD_RESUME_FILE:-} ]] && : >"$CS_GD_RESUME_FILE"
            return "$CS_DRV_NOTFOUND"
            ;;
        esac
        ;;
    esac
  done
  rc=1
  return "$rc"
}

cs_gd_finish_resumable() {
  [[ -n ${CS_GD_RESUME_FILE:-} ]] && : >"$CS_GD_RESUME_FILE"
  tr -d '\r' <"$(cs_gd_tmp)/body"
}

# cs_gd_put_chunk URI OFFSET|'*' SIZE FILE N: PUT N bytes of FILE from OFFSET to the session URI (or ask
# its status with OFFSET '*'); prints the HTTP code.
cs_gd_put_chunk() {
  local uri=$1 off=$2 size=$3 file=$4 n=$5 dir range
  dir=$(cs_gd_tmp)
  cs_access_token_ensure || return
  if [[ $off == '*' ]]; then
    range="bytes */$size"
    nat curl -sS --connect-timeout 10 --max-time 60 -X PUT -H "Authorization: Bearer $CS_ACCESS_TOKEN" \
      -H "Content-Range: $range" -H 'Content-Length: 0' -D "$(cs_to_win "$dir/hdr")" -o "$(cs_to_win "$dir/body")" \
      -w '%{http_code}' "$uri" 2>"$dir/err"
  else
    range="bytes $off-$((off + n - 1))/$size"
    tail -c +$((off + 1)) -- "$file" | head -c "$n" |
      nat curl -sS --connect-timeout 10 --max-time "${CS_GD_MAX_TIME:-300}" -X PUT \
        -H "Authorization: Bearer $CS_ACCESS_TOKEN" -H "Content-Range: $range" -H 'Content-Type: application/octet-stream' \
        --data-binary @- -D "$(cs_to_win "$dir/hdr")" -o "$(cs_to_win "$dir/body")" -w '%{http_code}' "$uri" 2>"$dir/err"
  fi
}

cs_gd_update_content() {
  local id=$1 file=$2 r
  r=$(cs_gd PATCH "$CS_GD_UPLOAD/files/$id?uploadType=media&fields=$CS_GD_FIELDS&supportsAllDrives=true" \
    -H 'Content-Type: application/octet-stream' --data-binary "@$(cs_to_win "$file")") || return
  r=$(cs_gd_norm <<<"$r")
  cs_gd_check_md5 "$r" "$file" || return 1
  printf '%s\n' "$r"
}

cs_gd_download() {
  GD_OUT=$2 cs_gd GET "$CS_GD_API/files/$1?alt=media&supportsAllDrives=true"
}

# cs_gd_list Q: every non-trashed file matching the Drive query Q (all pages), normalized.
cs_gd_list() {
  local q page='' r
  q=$(cs_urlenc "$1")
  while :; do
    r=$(cs_gd GET "$CS_GD_API/files?q=$q&pageSize=1000&fields=nextPageToken,files($CS_GD_FIELDS)&supportsAllDrives=true&includeItemsFromAllDrives=true${page:+&pageToken=$(cs_urlenc "$page")}") || return
    cs_jq -c ".files[] | $CS_GD_NORM" <<<"$r"
    page=$(cs_jq -r '.nextPageToken // empty' <<<"$r")
    [[ -n $page ]] || return 0
  done
}

cs_gd_list_children() {
  cs_gd_list "$(cs_gd_q_literal "$1") in parents and trashed=false"
}

cs_gd_find_by_prop() {
  cs_gd_list "appProperties has { key=$(cs_gd_q_literal "$1") and value=$(cs_gd_q_literal "$2") } and trashed=false"
}

cs_gd_changes_start_token() {
  cs_gd GET "$CS_GD_API/changes/startPageToken?supportsAllDrives=true" | cs_jq -r '.startPageToken'
  return "${PIPESTATUS[0]}"
}

# cs_gd_changes_list TOKEN: changed file ids since TOKEN (all pages, deduplicated), then "TOKEN <new>".
# The new token is the newStartPageToken of the LAST page; asking for a fresh start token instead would
# silently drop changes made while the pages were being read.
cs_gd_changes_list() {
  local tok=$1 r next new='' ids
  ids="$(cs_gd_tmp)/changes"
  : >"$ids"
  while :; do
    r=$(cs_gd GET "$CS_GD_API/changes?pageToken=$(cs_urlenc "$tok")&pageSize=1000&includeRemoved=true&supportsAllDrives=true&includeItemsFromAllDrives=true&fields=nextPageToken,newStartPageToken,changes(fileId)") || return
    cs_jq -r '.changes[].fileId' <<<"$r" >>"$ids"
    next=$(cs_jq -r '.nextPageToken // empty' <<<"$r")
    if [[ -n $next ]]; then
      tok=$next
      continue
    fi
    new=$(cs_jq -r '.newStartPageToken // empty' <<<"$r")
    break
  done
  [[ -n $new ]] || return 1
  "$CS_AWK" '!seen[$0]++' "$ids"
  printf 'TOKEN %s\n' "$new"
}

cs_gd_trash() {
  local r
  r=$(cs_gd PATCH "$CS_GD_API/files/$1?fields=$CS_GD_FIELDS&supportsAllDrives=true" \
    -H 'Content-Type: application/json; charset=UTF-8' --data-binary '{"trashed":true}') || return
  cs_gd_norm <<<"$r"
}

# cs_gd_server_time: Drive's clock (Date header) as ISO UTC — SPEC §9.3 never trusts the local clock.
cs_gd_server_time() {
  cs_gd GET "$CS_GD_API/about?fields=kind" >/dev/null || return
  local d
  d=$(cs_gd_header date)
  [[ -n $d ]] || return 1
  date -u -d "$d" +%Y-%m-%dT%H:%M:%S.000Z
}

cs_gd_about_user() {
  local r
  r=$(cs_gd GET "$CS_GD_API/about?fields=user(displayName,emailAddress)") || return
  cs_jq -r '.user | "\(.displayName) <\(.emailAddress)>"' <<<"$r"
}
