#!/usr/bin/env bats
# Drive interface contract (tickets #09, #11). Only drv_* functions are used, so the same tests run on:
#   - the localfs backend (default, CI)
#   - real Google Drive:  CS_TEST_GDRIVE=1 [CS_TEST_GDRIVE_HOME=~/.claude-sync] test/vendor/bats-core/bin/bats test/drive_contract.bats
#     Needs a prior "claude-sync login". Everything is created inside a fresh folder under the
#     "Claude Sync (dev)" spike folder (appProperties csSpike=1) and that folder is trashed afterwards.
#     Nothing outside it is touched and nothing is deleted permanently.

load test_helper

setup() {
  cs_test_setup
  cs_load platform version drive
  T=$BATS_TEST_TMPDIR
  printf 'hello\n' >"$T/a.txt"
  printf 'other\n' >"$T/b.txt"
  KEY=csTest
  VAL=v$RANDOM$RANDOM
  if [[ ${CS_TEST_GDRIVE:-0} == 1 ]]; then
    BACKEND=gdrive
    export CS_DRIVE_BACKEND=gdrive
    local src=${CS_TEST_GDRIVE_HOME:-$(cs_win_to_posix "${USERPROFILE:-$HOME}")/.claude-sync}
    [[ $OSTYPE == linux* ]] && src=${CS_TEST_GDRIVE_HOME:-/root/.claude-sync}
    mkdir -p "$CLAUDE_SYNC_HOME"
    cp "$src/oauth-client.json" "$CLAUDE_SYNC_HOME/"
    cp "$src"/token.* "$CLAUDE_SYNC_HOME/"
    local dev='' try rc=0
    for try in 1 2 3; do
      dev=$(drv_find_by_prop csSpike 1 | head -n 1 | cs_jq -r .id) && rc=0 || rc=$?
      [[ -n $dev ]] && break
      sleep 2
    done
    [[ -n $dev ]] || skip "no 'Claude Sync (dev)' folder found (rc=$rc; run docs/prototypes/m0_login_spike.sh first)"
    P=$(drv_create_folder "$dev" "contract-$(date -u +%Y%m%dT%H%M%S)-$RANDOM" '{}' | cs_jq -r .id)
  else
    BACKEND=localfs
    export CS_DRIVE_BACKEND=localfs CS_LFS_ROOT="$T/drive"
    P=root
  fi
}

teardown() {
  if [[ ${BACKEND:-} == gdrive && -n ${P:-} ]]; then drv_trash "$P" >/dev/null || true; fi
}

jf() { cs_jq -r "$1" <<<"$2"; }

@test "generate_ids returns N distinct ids" {
  run drv_generate_ids 5
  [ "${#lines[@]}" -eq 5 ]
  [ "$(printf '%s\n' "${lines[@]}" | sort -u | wc -l)" -eq 5 ]
}

@test "folders: create, nest, find by appProperties, list children" {
  f=$(drv_create_folder "$P" 'Claude Sync' "{\"$KEY\":\"$VAL\"}")
  fid=$(jf .id "$f")
  [ "$(jf .mimeType "$f")" = application/vnd.google-apps.folder ]
  drv_create_folder "$fid" machines '{}' >/dev/null
  run drv_find_by_prop "$KEY" "$VAL"
  [ "${#lines[@]}" -eq 1 ]
  [ "$(jf .id "${lines[0]}")" = "$fid" ]
  run drv_list_children "$fid"
  [ "${#lines[@]}" -eq 1 ]
  [ "$(jf .name "${lines[0]}")" = machines ]
}

@test "folder created with a pre-assigned id is idempotent" {
  id=$(drv_generate_ids 1)
  a=$(drv_create_folder "$P" x '{}' "$id")
  b=$(drv_create_folder "$P" x '{}' "$id")
  [ "$(jf .id "$a")" = "$id" ]
  [ "$(jf .id "$b")" = "$id" ]
  [ "$(drv_list_children "$P" | wc -l)" -eq 1 ]
}

@test "upload/download: content, md5, size and appProperties round trip" {
  m=$(drv_upload "$P" a.txt "$T/a.txt" '{"csSha":"abc"}')
  [ "$(jf .md5Checksum "$m")" = "$(md5sum "$T/a.txt" | cut -d' ' -f1)" ]
  [ "$(jf .size "$m")" = 6 ]
  [ "$(jf .appProperties.csSha "$m")" = abc ]
  drv_download "$(jf .id "$m")" "$T/out.txt"
  cmp "$T/a.txt" "$T/out.txt"
}

@test "upload with a pre-assigned id is idempotent; different content is a conflict (rc 9)" {
  id=$(drv_generate_ids 1)
  m1=$(drv_upload "$P" a.txt "$T/a.txt" '{}' "$id")
  m2=$(drv_upload "$P" a.txt "$T/a.txt" '{}' "$id")
  [ "$(jf .id "$m1")" = "$id" ]
  [ "$(jf .id "$m2")" = "$id" ]
  [ "$(drv_list_children "$P" | wc -l)" -eq 1 ]
  run drv_upload "$P" a.txt "$T/b.txt" '{}' "$id"
  [ "$status" -eq 9 ]
}

@test "update_content changes md5 and content" {
  id=$(jf .id "$(drv_upload "$P" a.txt "$T/a.txt" '{}')")
  m2=$(drv_update_content "$id" "$T/b.txt")
  [ "$(jf .md5Checksum "$m2")" = "$(md5sum "$T/b.txt" | cut -d' ' -f1)" ]
  drv_download "$id" "$T/o"
  cmp "$T/b.txt" "$T/o"
}

@test "trash hides from list/find but keeps the object readable" {
  f=$(jf .id "$(drv_create_folder "$P" d "{\"$KEY\":\"$VAL\"}")")
  drv_trash "$f" >/dev/null
  [ -z "$(drv_find_by_prop "$KEY" "$VAL")" ]
  [ -z "$(drv_list_children "$P")" ]
  [ "$(jf .trashed "$(drv_get_meta "$f")")" = true ]
}

@test "there is no permanent delete or empty-trash anywhere in lib/" {
  ! grep -rqiE 'emptyTrash|drv_delete|cs_(lfs|gd)_delete|-X DELETE' "$CS_ROOT/lib"
}

@test "missing objects and parents are rc 4" {
  run drv_get_meta nope0000000000000000000
  [ "$status" -eq 4 ]
  run drv_download nope0000000000000000000 "$T/x"
  [ "$status" -eq 4 ]
  run drv_update_content nope0000000000000000000 "$T/a.txt"
  [ "$status" -eq 4 ]
}

@test "changes since a token include what we changed, deduplicated, then a new token" {
  tok=$(drv_changes_start_token)
  a=$(jf .id "$(drv_upload "$P" a "$T/a.txt" '{}')")
  b=$(jf .id "$(drv_upload "$P" b "$T/b.txt" '{}')")
  drv_update_content "$a" "$T/b.txt" >/dev/null
  # Drive's change feed can lag a little behind the writes.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    out=$(drv_changes_list "$tok")
    grep -qx "$a" <<<"$out" && grep -qx "$b" <<<"$out" && break
    sleep 2
  done
  grep -qx "$a" <<<"$out"
  grep -qx "$b" <<<"$out"
  [ "$(grep -vc '^TOKEN ' <<<"$out")" -eq "$(grep -v '^TOKEN ' <<<"$out" | sort -u | wc -l)" ]
  [[ $(tail -n 1 <<<"$out") == "TOKEN "* ]]
  new=$(tail -n 1 <<<"$out")
  new=${new#TOKEN }
  run drv_changes_list "$new"
  [ "$status" -eq 0 ]
  [[ ${lines[-1]} == "TOKEN "* ]]
  # localfs never repeats a change; real Drive may report a file again while it finishes processing it,
  # so the engine must tolerate repeats (it compares manifests, never trusts the feed alone).
  if [[ $BACKEND == localfs ]]; then ! printf '%s\n' "${lines[@]}" | grep -qx "$a"; fi
}

@test "server time is an ISO UTC timestamp" {
  [[ $(drv_server_time) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$ ]]
}

@test "about_user names the account" {
  [[ $(drv_about_user) == *"<"*"@"*">" ]]
}

@test "concurrent uploads from several processes get distinct ids" {
  local pids=() i
  for i in 1 2 3 4; do
    (drv_upload "$P" "x$i" "$T/a.txt" '{}' >/dev/null) 3>&- &
    pids+=($!)
  done
  for i in "${pids[@]}"; do wait "$i"; done
  [ "$(drv_list_children "$P" | wc -l)" -eq 4 ]
  [ "$(drv_list_children "$P" | cs_jq -r .id | sort -u | wc -l)" -eq 4 ]
}

# --- localfs only ------------------------------------------------------------------------------------------

@test "localfs: injected failures fire COUNT times, then the call succeeds" {
  [[ $BACKEND == localfs ]] || skip "localfs only"
  id=$(jf .id "$(drv_upload "$P" a "$T/a.txt" '{}')")
  cs_lfs_inject download 7 2
  run drv_download "$id" "$T/o"
  [ "$status" -eq 7 ]
  run drv_download "$id" "$T/o"
  [ "$status" -eq 7 ]
  drv_download "$id" "$T/o"
  cmp "$T/a.txt" "$T/o"
}

@test "localfs: server time override and default identity" {
  [[ $BACKEND == localfs ]] || skip "localfs only"
  [ "$(CS_LFS_NOW=2026-10-05T04:10:35.173Z drv_server_time)" = 2026-10-05T04:10:35.173Z ]
  [ "$(drv_about_user)" = 'Local Test <test@localhost>' ]
}

@test "unknown backend is an error" {
  CS_DRIVE_BACKEND=nope run drv_get_meta x
  [ "$status" -eq 1 ]
}
