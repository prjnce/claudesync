#!/usr/bin/env bats
# gdrive backend logic without network (ticket #11): curl is replaced by a function that serves scripted
# responses and records requests. Covers retries, backoff, 401 refresh, error mapping, paging, md5 checks,
# pre-assigned ids, resumable upload and resume.

load test_helper

setup() {
  cs_test_setup
  cs_load platform version drive
  export CS_DRIVE_BACKEND=gdrive CS_GD_BACKOFF_BASE=0
  T=$BATS_TEST_TMPDIR
  mkdir -p "$CLAUDE_SYNC_HOME" "$T/q"
  printf '{"installed":{"client_id":"cid","client_secret":"sec"}}' >"$T/client.json"
  cs_client_install "$T/client.json"
  cs_token_save "{\"refresh_token\":\"RT\",\"access_token\":\"AT1\",\"expires_at\":$(($(date +%s) + 3000))}"
  printf '{"access_token":"AT2","expires_in":3599}' >"$T/refresh.json"
  if cs_is_windows; then CS_OAUTH_TOKEN_EP="file:///$(cygpath -m "$T/refresh.json")"; else CS_OAUTH_TOKEN_EP="file://$T/refresh.json"; fi
  QN=0
  : >"$T/requests.log"
}

# respond CODE [BODY] [HEADER...]: queue the next response.
respond() {
  QN=$((QN + 1))
  local f="$T/q/$(printf '%03d' "$QN")"
  { printf '%s\n' "$1"; shift; local body=${1:-}; shift || true; printf '%s\n' "$@"; printf '\n%s' "$body"; } >"$f"
}

# Fake curl: pops the next queued response. Records "METHOD URL", Authorization, Content-Range and the
# byte count of a stdin body. A response code of NET simulates a curl failure.
curl() {
  # The token endpoint is a file:// mock served by the real curl.
  if [[ " $* " == *" file://"* ]]; then
    command curl "$@"
    return
  fi
  local method=GET hdr= out= w= url= a stdin=0
  local -a hs=()
  while (($#)); do
    case $1 in
      -X) method=$2; shift 2 ;;
      -D) hdr=$2; shift 2 ;;
      -o) out=$2; shift 2 ;;
      -w) w=$2; shift 2 ;;
      -H) hs+=("$2"); shift 2 ;;
      --data-binary) [[ $2 == @- ]] && stdin=1; shift 2 ;;
      -F) shift 2 ;;
      --connect-timeout | --max-time) shift 2 ;;
      -sS) shift ;;
      *) url=$1; shift ;;
    esac
  done
  local n
  n=$(ls "$T/q" | head -n 1)
  [[ -n $n ]] || { echo "fake curl: no response queued for $method $url" >&2; return 99; }
  {
    printf '%s %s\n' "$method" "$url"
    for a in "${hs[@]}"; do [[ $a == Authorization:* || $a == Content-Range:* ]] && printf '  %s\n' "$a"; done
    ((stdin)) && printf '  stdin=%s\n' "$(wc -c | tr -d ' ')"
  } >>"$T/requests.log"
  local code
  code=$(head -n 1 "$T/q/$n")
  if [[ $code == NET ]]; then rm -f "$T/q/$n"; return 7; fi
  # headers: lines 2.. until the first empty line; body: everything after it
  awk 'NR > 1 && /^$/ { exit } NR > 1' "$T/q/$n" >"$hdr"
  awk 'f { print } NR > 1 && /^$/ && !f { f = 1 }' "$T/q/$n" | head -c -1 >"$out" 2>/dev/null || true
  rm -f "$T/q/$n"
  [[ -n $w ]] && printf '%s' "$code"
  return 0
}

reqs() { grep -c '^[A-Z]' "$T/requests.log"; }

@test "get_meta normalizes Drive metadata to the drv_* shape" {
  respond 200 '{"id":"F1","name":"x","mimeType":"text/plain","parents":["P"],"size":"6","md5Checksum":"abc","createdTime":"t","modifiedTime":"t"}'
  m=$(drv_get_meta F1)
  [ "$m" = '{"id":"F1","name":"x","mimeType":"text/plain","parents":["P"],"appProperties":{},"md5Checksum":"abc","size":6,"createdTime":"t","modifiedTime":"t","trashed":false}' ]
  grep -q 'GET https://www.googleapis.com/drive/v3/files/F1?fields=.*supportsAllDrives=true' "$T/requests.log"
  grep -q 'Authorization: Bearer AT1' "$T/requests.log"
}

@test "401 refreshes the token once and retries with the new token" {
  respond 401 '{"error":{"code":401}}'
  respond 200 '{"id":"F1","name":"x","mimeType":"m","parents":[]}'
  drv_get_meta F1 >/dev/null
  [ "$(reqs)" -eq 2 ]
  [ "$(grep -c 'Bearer AT2' "$T/requests.log")" -eq 1 ]
}

@test "a second 401 after refreshing means login required" {
  respond 401 '{}'
  respond 401 '{}'
  run drv_get_meta F1
  [ "$status" -eq 3 ]
}

@test "429, 503 and 403 rateLimitExceeded are retried with backoff; giving up returns 7" {
  respond 429 '{}'
  respond 503 '{}'
  respond 403 '{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}'
  respond 200 '{"id":"F","name":"n","mimeType":"m","parents":[]}'
  drv_get_meta F >/dev/null
  [ "$(reqs)" -eq 4 ]
  : >"$T/requests.log"
  CS_GD_RETRIES=2
  respond 500 '{}'
  respond 502 '{}'
  respond 503 '{}'
  run drv_get_meta F
  [ "$status" -eq 7 ]
  [ "$(reqs)" -eq 3 ]
}

@test "403 without a rate-limit reason is not retried (rc 1); 404 -> 4; network failure -> 6" {
  respond 403 '{"error":{"message":"insufficientFilePermissions"}}'
  run drv_get_meta F
  [ "$status" -eq 1 ]
  respond 404 '{}'
  run drv_get_meta F
  [ "$status" -eq 4 ]
  respond NET
  run drv_get_meta F
  [ "$status" -eq 6 ]
}

@test "create_folder with an existing pre-assigned id (409) returns that folder" {
  respond 409 '{}'
  respond 200 '{"id":"PRE","name":"Claude Sync","mimeType":"application/vnd.google-apps.folder","parents":["root"]}'
  m=$(drv_create_folder root 'Claude Sync' '{"csRoot":"1"}' PRE)
  [ "$(cs_jq -r .id <<<"$m")" = PRE ]
}

@test "list_children pages through results with the right query" {
  respond 200 '{"nextPageToken":"p2","files":[{"id":"a","name":"a","mimeType":"m","parents":["P"]}]}'
  respond 200 '{"files":[{"id":"b","name":"b","mimeType":"m","parents":["P"]}]}'
  run drv_list_children P
  [ "${#lines[@]}" -eq 2 ]
  grep -q "q=%27P%27%20in%20parents%20and%20trashed%3Dfalse" "$T/requests.log"
  grep -q 'pageToken=p2' "$T/requests.log"
}

@test "find_by_prop escapes quotes in the Drive query" {
  respond 200 '{"files":[]}'
  drv_find_by_prop csRoot "o'k"
  grep -q "key%3D%27csRoot%27%20and%20value%3D%27o%5C%27k%27" "$T/requests.log"
}

@test "changes: all pages, deduplicated, and the LAST page's newStartPageToken" {
  respond 200 '{"nextPageToken":"n2","changes":[{"fileId":"a"},{"fileId":"b"}]}'
  respond 200 '{"newStartPageToken":"T9","changes":[{"fileId":"a"},{"fileId":"c"}]}'
  run drv_changes_list T1
  [ "$output" = $'a\nb\nc\nTOKEN T9' ]
  [ "$(reqs)" -eq 2 ]
}

@test "multipart upload checks Drive's md5 against the local file" {
  printf 'hello\n' >"$T/f"
  md5=$(md5sum "$T/f" | cut -d' ' -f1)
  respond 200 "{\"id\":\"U1\",\"name\":\"f\",\"mimeType\":\"m\",\"parents\":[\"P\"],\"md5Checksum\":\"$md5\",\"size\":\"6\"}"
  m=$(drv_upload P f "$T/f" '{"csSha":"s"}')
  [ "$(cs_jq -r .size <<<"$m")" = 6 ]
  grep -q 'POST https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart' "$T/requests.log"
  respond 200 '{"id":"U2","name":"f","mimeType":"m","parents":["P"],"md5Checksum":"bad","size":"6"}'
  run drv_upload P f "$T/f" '{}'
  [ "$status" -eq 1 ]
}

@test "upload retry with a pre-assigned id: same content is reused, other content is a conflict" {
  printf 'hello\n' >"$T/f"
  md5=$(md5sum "$T/f" | cut -d' ' -f1)
  respond 409 '{}'
  respond 200 "{\"id\":\"PRE\",\"name\":\"f\",\"mimeType\":\"m\",\"parents\":[\"P\"],\"md5Checksum\":\"$md5\",\"size\":\"6\"}"
  m=$(drv_upload P f "$T/f" '{}' PRE)
  [ "$(cs_jq -r .id <<<"$m")" = PRE ]
  respond 409 '{}'
  respond 200 '{"id":"PRE","name":"f","mimeType":"m","parents":["P"],"md5Checksum":"other","size":"6"}'
  run drv_upload P f "$T/f" '{}' PRE
  [ "$status" -eq 9 ]
}

@test "resumable upload: session, 256 KiB-multiple chunks streamed from the file, final metadata" {
  head -c 600000 /dev/urandom >"$T/big"
  md5=$(md5sum "$T/big" | cut -d' ' -f1)
  export CS_GD_MULTIPART_MAX=100 CS_GD_CHUNK=262144
  respond 200 '' 'Location: https://upload.example/session1'
  respond 308 '' 'Range: bytes=0-262143'
  respond 308 '' 'Range: bytes=0-524287'
  respond 200 "{\"id\":\"R1\",\"name\":\"big\",\"mimeType\":\"m\",\"parents\":[\"P\"],\"md5Checksum\":\"$md5\",\"size\":\"600000\"}"
  m=$(drv_upload P big "$T/big" '{}')
  [ "$(cs_jq -r .id <<<"$m")" = R1 ]
  grep -q 'uploadType=resumable' "$T/requests.log"
  grep -q 'Content-Range: bytes 0-262143/600000' "$T/requests.log"
  grep -q 'Content-Range: bytes 262144-524287/600000' "$T/requests.log"
  grep -q 'Content-Range: bytes 524288-599999/600000' "$T/requests.log"
  [ "$(grep -c 'stdin=262144' "$T/requests.log")" -eq 2 ]
  grep -q 'stdin=75712' "$T/requests.log"
}

@test "resumable upload continues from a saved session URI after a crash" {
  head -c 600000 /dev/urandom >"$T/big"
  md5=$(md5sum "$T/big" | cut -d' ' -f1)
  export CS_GD_MULTIPART_MAX=100 CS_GD_CHUNK=262144 CS_GD_RESUME_FILE="$T/resume"
  printf 'https://upload.example/session7\n' >"$CS_GD_RESUME_FILE"
  respond 308 '' 'Range: bytes=0-262143'
  respond 308 '' 'Range: bytes=0-524287'
  respond 201 "{\"id\":\"R7\",\"name\":\"big\",\"mimeType\":\"m\",\"parents\":[\"P\"],\"md5Checksum\":\"$md5\",\"size\":\"600000\"}"
  m=$(drv_upload P big "$T/big" '{}')
  [ "$(cs_jq -r .id <<<"$m")" = R7 ]
  ! grep -q 'uploadType=resumable' "$T/requests.log"
  grep -q 'Content-Range: bytes \*/600000' "$T/requests.log"
  grep -q 'Content-Range: bytes 262144-524287/600000' "$T/requests.log"
  [ ! -s "$CS_GD_RESUME_FILE" ]
}

@test "server time comes from Drive's Date header, not the local clock" {
  respond 200 '{"kind":"drive#about"}' 'Date: Mon, 05 Oct 2026 04:10:35 GMT'
  [ "$(drv_server_time)" = 2026-10-05T04:10:35.000Z ]
}

@test "about_user formats name and email" {
  respond 200 '{"user":{"displayName":"Frank Nguyễn","emailAddress":"x@gmail.com"}}'
  [ "$(drv_about_user)" = 'Frank Nguyễn <x@gmail.com>' ]
}

@test "requests never put the token in the URL" {
  respond 200 '{"id":"F","name":"n","mimeType":"m","parents":[]}'
  drv_get_meta F >/dev/null
  ! grep -E '^[A-Z]+ .*AT1' "$T/requests.log"
}

@test "resumable upload with pipefail on (as in bin/claude-sync): every chunk of a big file succeeds on the first try" {
  # tail is cut off by head, which gave the chunk the status 141 (SIGPIPE) and so the code 000: each chunk then needed
  # a status query and a backoff, and a file of more than CS_GD_RETRIES+1 chunks (about 25 MB) was never uploaded
  set -o pipefail
  local k size=$((262144 * 8 + 1000))
  head -c "$size" /dev/urandom >"$T/big"
  md5=$(md5sum "$T/big" | cut -d' ' -f1)
  export CS_GD_MULTIPART_MAX=100 CS_GD_CHUNK=262144
  respond 200 '' 'Location: https://upload.example/session1'
  for k in 1 2 3 4 5 6 7 8; do respond 308 '' "Range: bytes=0-$((262144 * k - 1))"; done
  respond 200 "{\"id\":\"R1\",\"name\":\"big\",\"mimeType\":\"m\",\"parents\":[\"P\"],\"md5Checksum\":\"$md5\",\"size\":\"$size\"}"
  m=$(drv_upload P big "$T/big" '{}')
  [ "$(cs_jq -r .id <<<"$m")" = R1 ]
  [ "$(grep -c 'Content-Range: bytes [*]/' "$T/requests.log")" -eq 0 ]
  [ "$(grep -c '^PUT' "$T/requests.log")" -eq 9 ]
}
