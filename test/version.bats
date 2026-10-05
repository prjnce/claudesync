#!/usr/bin/env bats
# version chains and manifests (ticket #16). Reference hashes were computed independently with node.

load test_helper

SID=0b7a1c2e-1111-4222-8333-444455556666
CUM0=afccf70f815f6a38889aa907602349c122a6c330abcfe36034bc7342f45f385d
SHA1=e346432021b04179518d9614f3560ccd71354a4ee101ddcb893d6959a9d6301c
CUM1=160682e7f6dde3d159e2e645db3a375842120012904f8b315ae5d5e90e09314b
SHA2=1e127bc94448937cab293be6e9875322ce513be563e8fccb261daef7ccb6316e
CUM2=3fd6068406d9c06c526ce2f576330e762930f4983a02b0ee4aaa387d4b2197cd
SHAW=ef1c3cd9cd7c0cf0b0b7b745afbc853d1c7eebe134f3ab5b89650ff06c431e37
CUMW=517ec9ce762d51ec2d3709b85d6c97775cae28c20d94b78325b62fdc0428175c

setup() {
  cs_test_setup
  cs_load version manifest
  T=$BATS_TEST_TMPDIR
  printf '{"a":1}\n' >"$T/s1"
  printf '{"b":2}\n{"c":3}\n' >"$T/s2"
}

two_seg_entry() {
  local e
  e=$(cs_entry_new "$SID")
  e=$(cs_entry_append "$SID" "$e" mA F1 8 1 "$SHA1")
  cs_entry_append "$SID" "$e" mB F2 16 2 "$SHA2"
}

@test "segment hashes and cum chain match the reference vectors" {
  [ "$(cs_sha256_hex "$T/s1")" = "$SHA1" ]
  [ "$(cs_sha256_hex <"$T/s2")" = "$SHA2" ]
  [ "$(cs_cum0 "$SID")" = "$CUM0" ]
  run cs_chain_cums "$SID" "$SHA1" "$SHA2"
  [ "${lines[0]}" = "$CUM1" ]
  [ "${lines[1]}" = "$CUM2" ]
}

@test "byte-range hash equals the hash of the extracted bytes" {
  cat "$T/s1" "$T/s2" >"$T/all"
  [ "$(cs_sha256_range "$T/all" 8 16)" = "$SHA2" ]
  [ "$(cs_sha256_range "$T/all" 0 24)" = "$SHAW" ]
}

@test "append: head, len, lines and per-segment owner machine" {
  e=$(two_seg_entry)
  [ "$(jq -r .head <<<"$e" | tr -d '\r')" = "$CUM2" ]
  [ "$(jq -r '.len, .lines' <<<"$e" | tr -d '\r' | tr '\n' ' ')" = "24 3 " ]
  [ "$(jq -r '[.segs[].m] | join(",")' <<<"$e" | tr -d '\r')" = mA,mB ]
  cs_entry_verify "$SID" "$e"
}

@test "verify rejects a tampered chain" {
  e=$(two_seg_entry | jq -c '.segs[0].sha = "00"' | tr -d '\r')
  ! cs_entry_verify "$SID" "$e"
}

@test "ancestry: head, every segment cum, and nothing else" {
  e=$(two_seg_entry)
  cs_entry_is_ancestor "$e" "$CUM2"
  cs_entry_is_ancestor "$e" "$CUM1"
  ! cs_entry_is_ancestor "$e" "$CUMW"
  ! cs_entry_is_ancestor "$e" "${CUM1:0:63}"
}

@test "restart (rewrite or compaction): new single-segment chain, old versions move to from[]" {
  e=$(two_seg_entry)
  r=$(cs_entry_restart "$SID" "$e" mA F9 24 3 "$SHAW")
  [ "$(jq -r .head <<<"$r" | tr -d '\r')" = "$CUMW" ]
  [ "$(jq '.segs | length' <<<"$r" | tr -d '\r')" = 1 ]
  cs_entry_is_ancestor "$r" "$CUM1"
  cs_entry_is_ancestor "$r" "$CUM2"
  cs_entry_verify "$SID" "$r"
}

@test "from[] accumulates across successive rewrites and stays duplicate-free" {
  e=$(two_seg_entry)
  r1=$(cs_entry_restart "$SID" "$e" mA F9 24 3 "$SHAW")
  r1=$(cs_entry_append "$SID" "$r1" mA F10 8 1 "$SHA1")
  mid=$(jq -r .head <<<"$r1" | tr -d '\r')
  r2=$(cs_entry_restart "$SID" "$r1" mB F11 32 4 "$SHA2")
  for v in "$CUM1" "$CUM2" "$CUMW" "$mid"; do cs_entry_is_ancestor "$r2" "$v"; done
  [ "$(jq '.from | length' <<<"$r2" | tr -d '\r')" = "$(jq '.from | unique | length' <<<"$r2" | tr -d '\r')" ]
}

@test "compaction threshold" {
  e=$(cs_entry_new "$SID")
  for i in $(seq 1 51); do e=$(cs_entry_append "$SID" "$e" m "F$i" 8 1 "$SHA1"); done
  cs_entry_needs_compaction "$e"
  e2=$(jq -c '.segs |= .[0:50]' <<<"$e" | tr -d '\r')
  ! cs_entry_needs_compaction "$e2"
}

@test "manifest: write/read round trip, deterministic bytes, unchanged content is not rewritten (F9)" {
  m=$(cs_manifest_new mid-A Frank-win windows 2.1.289 5)
  m=$(cs_manifest_put_session "$m" "$SID" "$(two_seg_entry)" p1 '{P:p1}/apps')
  cs_manifest_write "$T/m.gz" "$m" 2026-10-05T00:00:00Z
  r=$(cs_manifest_read "$T/m.gz")
  [ "$(jq -r '.sessions["'"$SID"'"].project' <<<"$r" | tr -d '\r')" = p1 ]
  [ "$(jq -r .updated <<<"$r" | tr -d '\r')" = 2026-10-05T00:00:00Z ]
  cp "$T/m.gz" "$T/m1.gz"
  run cs_manifest_write "$T/m.gz" "$m" 2026-10-06T00:00:00Z
  [ "$status" -eq 3 ]
  cmp "$T/m.gz" "$T/m1.gz"
  cs_manifest_write "$T/m2.gz" "$m" 2026-10-05T00:00:00Z
  cmp "$T/m1.gz" "$T/m2.gz"
}

@test "manifest: put_session keeps fields it is not given; unknown schema is refused" {
  m=$(cs_manifest_new mid-A n linux 2.1.289 10)
  m=$(cs_manifest_put_session "$m" "$SID" "$(two_seg_entry)" p1 '{P:p1}')
  m=$(cs_manifest_put_session "$m" "$SID" '{"head":"x"}')
  [ "$(jq -r '.sessions["'"$SID"'"] | .project + " " + .launch + " " + .head' <<<"$m" | tr -d '\r')" = 'p1 {P:p1} x' ]
  printf '{"schema":99}\n' | gzip -n >"$T/bad.gz"
  run cs_manifest_read "$T/bad.gz"
  [ "$status" -eq 1 ]
  run cs_manifest_read "$T/missing.gz"
  [ "$status" -eq 1 ]
}

@test "live.json body" {
  [ "$(cs_live_json a b)" = '{"sessions":["a","b"]}' ]
  [ "$(cs_live_json)" = '{"sessions":[]}' ]
}
