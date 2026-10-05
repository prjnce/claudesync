# shellcheck shell=bash
# root: the shared "Claude Sync" folder on Drive, its marker, this machine's identity and area
# (SPEC §5.2, §6, §9.1, §16 steps 5-6). Non-interactive; the wizard (lib/setup.sh) asks the questions.
# Layout:  <root>/.claude-sync-root (marker, appProperties csRoot=1, csSchema=1)
#          <root>/machines/<machine_id>/          (appProperties csMachine, csName, csOs)
# Requires lib/core.sh, lib/version.sh, lib/drive.sh, lib/claude.sh.

[[ -n ${CS_ROOT_LOADED:-} ]] && return 0
CS_ROOT_LOADED=1

CS_ROOT_SCHEMA=1

cs_drive_state_file() {
  printf '%s\n' "$CS_HOME/state/drive.json"
}

# cs_drive_state_get KEY: a value from state/drive.json (empty if unset).
cs_drive_state_get() {
  local f
  f=$(cs_drive_state_file)
  [[ -f $f ]] || return 0
  cs_jq -r --arg k "$1" '.[$k] // empty' "$f"
}

# cs_drive_state_set KEY VALUE: set a string value in state/drive.json (atomic).
cs_drive_state_set() {
  local f j
  f=$(cs_drive_state_file)
  mkdir -p -- "${f%/*}"
  if [[ -f $f ]]; then j=$(<"$f"); else j='{}'; fi
  j=$(cs_jq -c --arg k "$1" --arg v "$2" '.[$k] = $v' <<<"$j")
  cs_write_atomic "$f" printf '%s\n' "$j"
}

# cs_root_candidates: "root_id<TAB>marker_id<TAB>marker createdTime<TAB>root name", oldest first. A marker
# counts only if its parent folder exists and is not trashed.
cs_root_candidates() {
  local m mid pid ct meta
  while IFS= read -r m; do
    [[ -n $m ]] || continue
    mid=$(cs_jq -r .id <<<"$m")
    pid=$(cs_jq -r '.parents[0] // empty' <<<"$m")
    ct=$(cs_jq -r .createdTime <<<"$m")
    [[ -n $pid ]] || continue
    meta=$(drv_get_meta "$pid" 2>/dev/null) || continue
    [[ $(cs_jq -r .trashed <<<"$meta") == false ]] || continue
    printf '%s\t%s\t%s\t%s\n' "$pid" "$mid" "$ct" "$(cs_jq -r .name <<<"$meta")"
  done < <(drv_find_by_prop csRoot 1) | sort -t $'\t' -k3,3
}

# cs_root_create NAME: create NAME in My Drive with the marker and machines/; prints "root_id<TAB>marker_id".
cs_root_create() {
  local name=$1 root rid marker mid
  root=$(drv_create_folder root "$name" '{}') || return
  rid=$(cs_jq -r .id <<<"$root")
  marker="$(mktemp)"
  printf 'claude-sync root marker (schema %s). Do not delete: other machines find this folder through it.\n' "$CS_ROOT_SCHEMA" >"$marker"
  mid=$(drv_upload "$rid" .claude-sync-root "$marker" "{\"csRoot\":\"1\",\"csSchema\":\"$CS_ROOT_SCHEMA\"}" | cs_jq -r .id) || {
    rm -f -- "$marker"
    return 1
  }
  rm -f -- "$marker"
  drv_create_folder "$rid" machines '{"csMachines":"1"}' >/dev/null || return
  printf '%s\t%s\n' "$rid" "$mid"
}

# cs_root_use ROOT_ID MARKER_ID: remember the root in config and state.
cs_root_use() {
  cs_config_set root_id "$1"
  cs_drive_state_set root_id "$1"
  cs_drive_state_set marker_id "$2"
}

# cs_root_check: rc 0 if the configured root and its marker still exist and are not trashed;
# rc 4 (ROOT_MISSING) otherwise. Never recreates it (SPEC §14 step 5).
cs_root_check() {
  local rid mid meta
  rid=$(cs_config_get root_id "")
  mid=$(cs_drive_state_get marker_id)
  [[ -n $rid && -n $mid ]] || return 4
  meta=$(drv_get_meta "$rid") || return 4
  [[ $(cs_jq -r .trashed <<<"$meta") == false ]] || return 4
  meta=$(drv_get_meta "$mid") || return 4
  [[ $(cs_jq -r .trashed <<<"$meta") == false ]] || return 4
}

cs_root_link() {
  printf 'https://drive.google.com/drive/folders/%s\n' "$1"
}

# cs_machines_folder ROOT_ID: id of <root>/machines (created if missing).
cs_machines_folder() {
  local id
  id=$(drv_list_children "$1" | cs_jq -r 'select(.name == "machines" and .mimeType == "application/vnd.google-apps.folder") | .id' | head -n 1)
  if [[ -z $id ]]; then
    id=$(drv_create_folder "$1" machines '{"csMachines":"1"}' | cs_jq -r .id) || return
  fi
  printf '%s\n' "$id"
}

# cs_machines_list ROOT_ID: "machine_id<TAB>name<TAB>os" for every machine area.
cs_machines_list() {
  local mf
  mf=$(cs_machines_folder "$1") || return
  drv_list_children "$mf" | cs_jq -r 'select(.appProperties.csMachine) | [.appProperties.csMachine, (.appProperties.csName // .name), (.appProperties.csOs // "")] | @tsv'
}

# --- this machine ----------------------------------------------------------------------------------------

# cs_new_uuid: random RFC 4122 version-4 UUID.
cs_new_uuid() {
  local h
  h=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  printf '%s-%s-4%s-%x%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" $((0x${h:16:1} & 0x3 | 0x8)) "${h:17:3}" "${h:20:12}"
}

# cs_default_machine_name: hostname, plus -wsl inside WSL.
cs_default_machine_name() {
  local h=${COMPUTERNAME:-}
  [[ -n $h ]] || h=$(hostname 2>/dev/null) || h=machine
  ((CS_WSL)) && h+=-wsl
  printf '%s\n' "$h"
}

cs_os_kind() {
  if [[ $CS_OS == windows ]]; then printf 'windows\n'; elif ((CS_WSL)); then printf 'wsl\n'; else printf 'linux\n'; fi
}

# cs_machine_init [NAME]: make sure machine_id and machine_name exist in config; prints the machine_id.
cs_machine_init() {
  local id name=${1:-}
  id=$(cs_config_get machine_id "")
  if [[ -z $id ]]; then
    id=$(cs_new_uuid)
    cs_config_set machine_id "$id"
  fi
  [[ -n $name ]] || name=$(cs_config_get machine_name "")
  [[ -n $name ]] || name=$(cs_default_machine_name)
  cs_config_set machine_name "$name"
  printf '%s\n' "$id"
}

cs_owner_file() {
  printf '%s\n' "$(cs_claude_dir)/.claude-sync-owner"
}

# cs_owner_claim MACHINE_ID: write <claude-config>/.claude-sync-owner (refuses to steal another id's claim).
cs_owner_claim() {
  local f cur
  f=$(cs_owner_file)
  if [[ -f $f ]]; then
    cur=$(tr -d '\r\n' <"$f")
    [[ -z $cur || $cur == "$1" ]] || return 1
  fi
  mkdir -p -- "${f%/*}"
  cs_write_atomic "$f" printf '%s\n' "$1"
}

# cs_owner_check: rc 0 if the Claude config dir is owned by this install (or unclaimed); rc 1 if another
# claude-sync install (another machine_id) manages it — SPEC §5.2.
cs_owner_check() {
  local f cur me
  f=$(cs_owner_file)
  [[ -f $f ]] || return 0
  cur=$(tr -d '\r\n' <"$f")
  me=$(cs_config_get machine_id "")
  [[ -z $cur || $cur == "$me" ]]
}

# cs_machine_area_ensure ROOT_ID: create (or find) machines/<machine_id> on Drive; prints its id.
cs_machine_area_ensure() {
  local root=$1 mf id me name os
  me=$(cs_config_get machine_id "")
  [[ -n $me ]] || return 1
  name=$(cs_config_get machine_name "")
  os=$(cs_os_kind)
  mf=$(cs_machines_folder "$root") || return
  id=$(drv_list_children "$mf" | cs_jq -r --arg m "$me" 'select(.appProperties.csMachine == $m) | .id' | head -n 1)
  if [[ -z $id ]]; then
    id=$(drv_create_folder "$mf" "$me" "$(cs_jq -nc --arg m "$me" --arg n "$name" --arg o "$os" '{csMachine: $m, csName: $n, csOs: $o}')" | cs_jq -r .id) || return
  fi
  cs_drive_state_set machine_folder_id "$id"
  printf '%s\n' "$id"
}
