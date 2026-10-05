#!/usr/bin/env bats
# Drive interface contract, run against the localfs backend (ticket #09). Only drv_* functions are used
# in the contract tests, so the same file can later run against gdrive (#11).

load test_helper

setup() {
  cs_test_setup
  cs_load version drive
  export CS_DRIVE_BACKEND=localfs CS_LFS_ROOT="$BATS_TEST_TMPDIR/drive"
  T=$BATS_TEST_TMPDIR
  printf 'hello\n' >"$T/a.txt"
  printf 'other\n' >"$T/b.txt"
}

jf() { cs_jq -r "$1" <<<"$2"; }

@test "generate_ids returns N distinct ids" {
  run drv_generate_ids 5
  [ "${#lines[@]}" -eq 5 ]
  [ "$(printf '%s\n' "${lines[@]}" | sort -u | wc -l)" -eq 5 ]
}

@test "folders: create in root, nest, find by appProperties, list children" {
  root=$(drv_create_folder root 'Claude Sync' '{"csRoot":"1"}')
  rid=$(jf .id "$root")
  [ "$(jf .mimeType "$root")" = application/vnd.google-apps.folder ]
  sub=$(drv_create_folder "$rid" machines '{}')
  run drv_find_by_prop csRoot 1
  [ "${#lines[@]}" -eq 1 ]
  [ "$(jf .id "${lines[0]}")" = "$rid" ]
  run drv_list_children "$rid"
  [ "${#lines[@]}" -eq 1 ]
  [ "$(jf .name "${lines[0]}")" = machines ]
}

@test "upload/download: content, md5, size and appProperties round trip" {
  f=$(drv_create_folder root d '{}')
  m=$(drv_upload "$(jf .id "$f")" a.txt "$T/a.txt" '{"csSha":"abc"}')
  [ "$(jf .md5Checksum "$m")" = "$(md5sum "$T/a.txt" | cut -d' ' -f1)" ]
  [ "$(jf .size "$m")" = 6 ]
  [ "$(jf .appProperties.csSha "$m")" = abc ]
  drv_download "$(jf .id "$m")" "$T/out.txt"
  cmp "$T/a.txt" "$T/out.txt"
}

@test "upload with a pre-assigned id is idempotent; different content is a conflict (rc 9)" {
  f=$(jf .id "$(drv_create_folder root d '{}')")
  id=$(drv_generate_ids 1)
  m1=$(drv_upload "$f" a.txt "$T/a.txt" '{}' "$id")
  m2=$(drv_upload "$f" a.txt "$T/a.txt" '{}' "$id")
  [ "$(jf .id "$m1")" = "$id" ]
  [ "$m1" = "$m2" ]
  [ "$(drv_list_children "$f" | wc -l)" -eq 1 ]
  run drv_upload "$f" a.txt "$T/b.txt" '{}' "$id"
  [ "$status" -eq 9 ]
}

@test "update_content changes md5 and modifiedTime" {
  f=$(jf .id "$(drv_create_folder root d '{}')")
  CS_LFS_NOW=2026-10-05T00:00:00.000Z m1=$(drv_upload "$f" a.txt "$T/a.txt" '{}')
  id=$(jf .id "$m1")
  m2=$(CS_LFS_NOW=2026-10-05T01:00:00.000Z drv_update_content "$id" "$T/b.txt")
  [ "$(jf .md5Checksum "$m2")" = "$(md5sum "$T/b.txt" | cut -d' ' -f1)" ]
  [ "$(jf .modifiedTime "$m2")" = 2026-10-05T01:00:00.000Z ]
  drv_download "$id" "$T/o"
  cmp "$T/b.txt" "$T/o"
}

@test "trash hides from list/find, keeps the object readable; there is no permanent delete" {
  f=$(jf .id "$(drv_create_folder root d '{"k":"v"}')")
  drv_trash "$f" >/dev/null
  [ -z "$(drv_find_by_prop k v)" ]
  [ -z "$(drv_list_children root)" ]
  [ "$(jf .trashed "$(drv_get_meta "$f")")" = true ]
  ! grep -rqiE 'emptyTrash|drv_delete|cs_(lfs|gd)_delete' "$CS_ROOT/lib"
}

@test "missing objects and parents are rc 4" {
  run drv_get_meta nope
  [ "$status" -eq 4 ]
  run drv_download nope "$T/x"
  [ "$status" -eq 4 ]
  run drv_upload nope a "$T/a.txt" '{}'
  [ "$status" -eq 4 ]
  run drv_update_content nope "$T/a.txt"
  [ "$status" -eq 4 ]
}

@test "changes: ids changed since a token, deduplicated, then a new token" {
  f=$(jf .id "$(drv_create_folder root d '{}')")
  tok=$(drv_changes_start_token)
  a=$(jf .id "$(drv_upload "$f" a "$T/a.txt" '{}')")
  b=$(jf .id "$(drv_upload "$f" b "$T/b.txt" '{}')")
  drv_update_content "$a" "$T/b.txt" >/dev/null
  run drv_changes_list "$tok"
  [ "${lines[0]}" = "$a" ]
  [ "${lines[1]}" = "$b" ]
  [[ ${lines[2]} == "TOKEN "* ]]
  [ "${#lines[@]}" -eq 3 ]
  new=${lines[2]#TOKEN }
  run drv_changes_list "$new"
  [ "${#lines[@]}" -eq 1 ]
}

@test "server time and user identity" {
  [ "$(CS_LFS_NOW=2026-10-05T04:10:35.173Z drv_server_time)" = 2026-10-05T04:10:35.173Z ]
  [[ $(drv_server_time) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$ ]]
  [ "$(drv_about_user)" = 'Local Test <test@localhost>' ]
}

@test "concurrent uploads from several processes get distinct ids and all appear in changes" {
  f=$(jf .id "$(drv_create_folder root d '{}')")
  tok=$(drv_changes_start_token)
  local pids=() i
  for i in 1 2 3 4 5 6; do
    (drv_upload "$f" "x$i" "$T/a.txt" '{}' >/dev/null) 3>&- &
    pids+=($!)
  done
  for i in "${pids[@]}"; do wait "$i"; done
  [ "$(drv_list_children "$f" | wc -l)" -eq 6 ]
  [ "$(drv_changes_list "$tok" | grep -vc '^TOKEN')" -eq 6 ]
}

# --- localfs-only: failure injection used by engine tests ---------------------------------------------

@test "localfs: injected failures fire COUNT times, then the call succeeds" {
  f=$(jf .id "$(drv_create_folder root d '{}')")
  id=$(jf .id "$(drv_upload "$f" a "$T/a.txt" '{}')")
  cs_lfs_inject download 7 2
  run drv_download "$id" "$T/o"
  [ "$status" -eq 7 ]
  run drv_download "$id" "$T/o"
  [ "$status" -eq 7 ]
  drv_download "$id" "$T/o"
  cmp "$T/a.txt" "$T/o"
}

@test "unknown backend is an error" {
  CS_DRIVE_BACKEND=nope run drv_get_meta x
  [ "$status" -eq 1 ]
}
