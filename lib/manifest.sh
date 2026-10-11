# shellcheck shell=bash
# manifest: per-machine manifest.json.gz and live.json (SPEC §9.2, §9.3). Pure local I/O, no Drive.
# Written with sorted keys and gzip -n, so identical content always gives identical bytes (only write
# when changed, F9). Requires lib/core.sh and lib/version.sh.

[[ -n ${CS_MANIFEST_LOADED:-} ]] && return 0
CS_MANIFEST_LOADED=1

CS_MANIFEST_SCHEMA=1

# cs_manifest_new MACHINE_ID NAME OS CLAUDE_VERSION INTERVAL_MIN -> manifest JSON.
cs_manifest_new() {
  cs_jq -nc --arg mid "$1" --arg name "$2" --arg os "$3" --arg cv "$4" --argjson iv "$5" --argjson schema "$CS_MANIFEST_SCHEMA" \
    '{schema: $schema, machine_id: $mid, name: $name, os: $os, claude_version: $cv, interval_min: $iv,
      updated: "", projects: {}, sessions: {}, memory: {}, plans: {}}'
}

# cs_manifest_read FILE.gz -> JSON on stdout; rc 1 if missing, unreadable or of an unknown schema.
cs_manifest_read() {
  [[ -f $1 ]] || return 1
  local j
  j=$(gzip -dc -- "$1" 2>/dev/null | tr -d '\r') || return 1
  cs_jq -e --argjson s "$CS_MANIFEST_SCHEMA" 'select(type == "object" and .schema == $s)' <<<"$j" 2>/dev/null || return 1
}

# cs_manifest_normal JSON -> canonical compact JSON with sorted keys.
cs_manifest_normal() {
  cs_jq -cS . <<<"$1"
}

# cs_manifest_same A B: rc 0 if the manifests differ only in "updated".
cs_manifest_same() {
  [[ $(cs_jq -cS 'del(.updated)' <<<"$1") == "$(cs_jq -cS 'del(.updated)' <<<"$2")" ]]
}

# cs_manifest_write FILE.gz JSON [UPDATED_ISO]: write atomically unless the content (minus "updated")
# equals what FILE.gz already holds. rc 0 = written, rc 3 = unchanged (nothing written).
cs_manifest_write() {
  local f=$1 j=$2 ts=${3:-} old
  if old=$(cs_manifest_read "$f") && cs_manifest_same "$old" "$j"; then
    return 3
  fi
  [[ -n $ts ]] || TZ=UTC printf -v ts '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  j=$(cs_jq -cS --arg ts "$ts" '.updated = $ts' <<<"$j")
  cs_write_atomic "$f" cs_manifest_gz "$j"
}

cs_manifest_gz() {
  printf '%s\n' "$1" | gzip -n -c
}

# cs_manifest_session MANIFEST SID -> the session entry (rc 1 if absent).
cs_manifest_session() {
  cs_jq -ce --arg s "$2" '.sessions[$s] // empty' <<<"$1"
}

# cs_manifest_put_session MANIFEST SID ENTRY [PROJECT_ID] [LAUNCH] -> manifest with the entry replaced.
# Other fields of an existing entry (project, launch, plan_slug, files, subagents, forked) are kept
# unless given.
cs_manifest_put_session() {
  cs_jq -c --arg s "$2" --argjson e "$3" --arg p "${4:-}" --arg l "${5:-}" '
    (.sessions[$s] // {}) as $old
    | .sessions[$s] = ($old + $e
      + (if ($old.files // $e.files) then {files: (($old.files // {}) + ($e.files // {}))} else {} end)
      + (if ($old.subagents // $e.subagents) then {subagents: (($old.subagents // {}) + ($e.subagents // {}))} else {} end)
      + (if ($old.forked // $e.forked) then {forked: (($old.forked // {}) + ($e.forked // {}))} else {} end)
      + (if $p != "" then {project: $p} else {} end)
      + (if $l != "" then {launch: $l} else {} end))' <<<"$1"
}

# cs_live_json SID...: the live.json body (SPEC §9.3).
cs_live_json() {
  if (($#)); then
    printf '%s\n' "$@" | cs_jq -Rsc 'split("\n") | map(select(length > 0)) | {sessions: .}'
  else
    printf '{"sessions":[]}\n'
  fi
}
