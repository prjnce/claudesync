#!/usr/bin/env bats
# New paths: detection, candidates, confirmation (ticket #31). A is Windows-like (D:\Projects\TransFlow); B and C are POSIX.

load test_helper
load sim_helper

SID=0b7a1c2e-1111-4222-8333-444455556666

setup() {
  cs_test_setup
  cs_load platform version
  sim_init
  sim_machine A w 'D:\Projects\TransFlow'
  sim_exec A 'cs_tsv_upsert projects p1 "$1" TransFlow "$1" "$2" 1 "$3"' 'D:\Projects\TransFlow' 'C:\x' "${KEYS:-}"
  mkdir -p "$SIM/B/projects/TransFlowY" "$SIM/C/projects/TransFlowX"
  sim_machine B p "$SIM/B/projects/TransFlowY"
  sim_machine C p "$SIM/C/projects/TransFlowX"
  for m in B C; do
    sim_exec "$m" 'cs_tsv_delete projects p1 "$1"' "$SIM/$m/projects/$([[ $m == B ]] && echo TransFlowY || echo TransFlowX)"
    sim_exec "$m" 'cs_config_set scan_dirs "$1"' "$SIM/$m/projects $SIM/$m/code"
  done
}

aline() { printf '{"type":"user","uuid":"u-%s","cwd":"D:\\\\Projects\\\\TransFlow"}' "$1"; }
pend() { sim_exec "$1" 'cat "$CS_HOME/state/pending_map.tsv"' | tail -n +2; }
sj() { jq -c "$2" "$SIM/$1/home/.claude-sync/state/status.json" | tr -d '\r'; }

@test "B and C see TransFlow waiting; the best candidates are the similar names; nothing is mapped by itself" {
  sim_write A D--Projects-TransFlow "$SID" "$(aline 1)"
  sim_run A >/dev/null
  for i in 1 2 3; do sim_run B >/dev/null; sim_run C >/dev/null; done
  run pend B
  echo "$output"
  [[ $output == remote*p1*TransFlow* ]]
  [[ $output == *"TransFlowY|name|43"* ]]
  [[ $(pend C) == *"TransFlowX|name|43"* ]]
  [ -z "$(sim_exec B 'cs_tsv_rows projects')" ]
  [ -z "$(sim_find B "$SID")" ]
  [ "$(sj B '.waiting_map | length')" = 1 ]
  [ "$(sj B '.waiting_map[0].alias')" = '"TransFlow"' ]
}

@test "a path-equivalent folder ranks first" {
  mkdir -p "$SIM/B/equiv"
  run sim_exec B 'cs_pend_equiv() { printf "%s\n" "$1"; }; cs_pend_cands_remote TransFlow "$1" "" | sort -n | head -n 1' "$SIM/B/equiv"
  [[ $output == *10*path_equivalent* ]]
  run sim_exec B 'cs_pend_equiv "D:\\Projects\\TransFlow"; cs_pend_equiv /mnt/d/projects/x'
  [ "${lines[0]}" = /mnt/d/Projects/TransFlow ]
  [ "${lines[1]}" = 'D:\projects\x' ]
}

@test "same git remote beats a similar name even when the folder name is unrelated; the manifest only has hashes" {
  command -v git >/dev/null
  mkdir -p "$SIM/C/code/tf-server"
  git -C "$SIM/C/code/tf-server" init -q
  git -C "$SIM/C/code/tf-server" remote add origin 'https://user:SECRET-TOKEN-123@github.com/acme/transflow.git'
  KEYS=$(sim_exec C 'cs_remote_keys "$1"' "$SIM/C/code/tf-server" | tr -d '\r')
  [[ $KEYS =~ ^[0-9a-f]{64}$ ]]
  sim_exec A 'cs_tsv_upsert projects p1 "$1" TransFlow "$1" "$2" 1 "$3"' 'D:\Projects\TransFlow' 'C:\x' "$KEYS"
  sim_write A D--Projects-TransFlow "$SID" "$(aline 1)"
  sim_run A >/dev/null
  sim_run C >/dev/null
  c=$(pend C)
  echo "$c"
  [[ $c == *"tf-server|same_git_remote|30;"* ]]
  [[ $c == *"TransFlowX|name|43"* ]]
  gz=$(grep -l '"csMachine":"A-0000-4000-8000-000000000000"' "$SIM"/drive/objects/*/meta.json | xargs grep -l '"csKind":"manifest"' | head -n 1)
  m=$(gzip -dc "$(dirname "$gz")/content")
  [[ $m == *"$KEYS"* ]]
  [[ $m != *github* && $m != *SECRET* ]]
}

@test "skip asks again only when sessions grow; exclude never asks again" {
  sim_write A D--Projects-TransFlow "$SID" "$(aline 1)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  printf 's
' | sim_cli B projects map >/dev/null
  [ "$(sj B '.waiting_map | length')" = 0 ]
  sim_run B >/dev/null
  [ "$(sj B '.waiting_map | length')" = 0 ]
  sim_write A D--Projects-TransFlow 0b7a1c2e-1111-4222-8333-44445555aaaa "$(aline 2)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  [ "$(sj B '.waiting_map | length')" = 1 ]
  printf 'x
' | sim_cli B projects map >/dev/null
  sim_write A D--Projects-TransFlow 0b7a1c2e-1111-4222-8333-44445555bbbb "$(aline 3)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  [ "$(sj B '.waiting_map | length')" = 0 ]
}

@test "confirming candidate 1 maps the project under the same project_id and the sessions are installed with translated paths" {
  sim_write A D--Projects-TransFlow "$SID" "$(aline 1)" "$(aline 2)"
  sim_run A >/dev/null
  sim_run B >/dev/null
  printf '1
' | sim_cli B projects map
  [ "$(sim_exec B 'cs_tsv_rows projects | cut -f1' | tr -d '\r')" = p1 ]
  run sim_run B
  [[ $output == *'1 installed'* ]]
  f=$(sim_find B "$SID")
  [ -n "$f" ]
  root=$(sim_exec B 'cs_tsv_rows projects | cut -f2' | tr -d '\r')
  [ "$(head -n 1 "$f" | jq -r .cwd | tr -d '\r')" = "$root" ]
  [ "$(sj B '.waiting_map | length')" = 0 ]
}

@test "mode all: a folder that resembles nothing becomes a project by itself; a renamed folder asks to be a second root" {
  mkdir -p "$SIM/B/projects/Other" "$SIM/B/projects/TransFlowY2"
  # B maps TransFlowY as p1 (it already did in setup, then deleted); remap
  sim_exec B 'cs_project_map TransFlow "$1" >/dev/null' "$SIM/B/projects/TransFlowY"
  sim_write B "$(cc_slug "$SIM/B/projects/Other")" "$SID" "{\"type\":\"user\",\"cwd\":\"$SIM/B/projects/Other\"}"
  sim_write B "$(cc_slug "$SIM/B/projects/TransFlowY2")" 0b7a1c2e-1111-4222-8333-44445555aaaa "{\"type\":\"user\",\"cwd\":\"$SIM/B/projects/TransFlowY2\"}"
  sim_run B >/dev/null
  [ -n "$(sim_exec B 'cs_tsv_rows projects' | grep Other)" ]
  [ -z "$(sim_exec B 'cs_tsv_rows projects' | grep TransFlowY2)" ]
  [[ $(pend B) == *"local"*"TransFlowY2"* ]]
  [ "$(sj B '.auto_added[0]')" = '"Other"' ]
}

@test "mode selected: a new folder is never added or queued" {
  mkdir -p "$SIM/B/projects/Other"
  sim_exec B 'cs_config_set mode selected'
  sim_write B "$(cc_slug "$SIM/B/projects/Other")" "$SID" "{\"type\":\"user\",\"cwd\":\"$SIM/B/projects/Other\"}"
  run sim_run B
  [[ $output == *'0 published'* ]]
  [ -z "$(sim_exec B 'cs_tsv_rows projects')" ]
  [ -z "$(pend B)" ]
}

@test "looking for candidates stays within its time budget on a scan folder with thousands of directories" {
  mkdir -p "$SIM/B/code"
  mkdir -p "$SIM/B/code"/d{1..1500}/sub
  sim_write A D--Projects-TransFlow "$SID" "$(aline 1)"
  sim_run A >/dev/null
  start=$SECONDS
  CS_PEND_SCAN_BUDGET=0 sim_run B >/dev/null
  ((SECONDS - start < 60))
  n1=$(wc -l <"$SIM/B/home/.claude-sync/state/scan_cache.tsv")
  CS_PEND_SCAN_BUDGET=2 sim_run B >/dev/null
  n2=$(wc -l <"$SIM/B/home/.claude-sync/state/scan_cache.tsv")
  ((n2 > n1))
}
