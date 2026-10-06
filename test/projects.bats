#!/usr/bin/env bats
# projects: path forms, remote_keys, map/unmap/exclude, membership, spelling, memory dir, transform rows,
# list/select (ticket #14).

load test_helper

setup() {
  cs_test_setup
  cs_load platform version store claude transform projects ui cmd_projects
  T=$BATS_TEST_TMPDIR
  export CS_CLAUDE_DIR="$T/claude"
  mkdir -p "$CS_CLAUDE_DIR/projects" "$T/work/TransFlowX/apps" "$T/work/other"
  cs_store_init
  unset CS_LAUNCH_CWDS
}

# session SLUGDIR SID CWD_NATIVE: a transcript whose launch cwd is CWD_NATIVE.
session() {
  mkdir -p "$CS_CLAUDE_DIR/projects/$1"
  printf '{"type":"user","cwd":"%s"}\n' "$(cs_json_escape "$3")" >"$CS_CLAUDE_DIR/projects/$1/$2.jsonl"
}

native() { cs_native_path "$1"; }

@test "native path forms" {
  if cs_is_windows; then
    [ "$(cs_native_path /c/Users/x/)" = 'C:\Users\x' ]
    [ "$(cs_native_path 'd:/Projects/X')" = 'D:\Projects\X' ]
    [[ $(cs_native_path /tmp) == [A-Z]:\\* ]]
  else
    [ "$(cs_native_path /home/u/x/)" = /home/u/x ]
  fi
}

@test "path_under: boundary; case-insensitive for Windows and /mnt, exact elsewhere" {
  cs_path_under 'D:\Projects\X\apps' 'd:\projects\x'
  ! cs_path_under 'D:\Projects\XOld' 'D:\Projects\X'
  cs_path_under '/mnt/D/projects/x/y' '/mnt/d/Projects/X'
  ! cs_path_under '/home/u/x' '/home/u/X'
  cs_path_under '/home/u/X' '/home/u/X'
}

@test "git remote normalization: every credential form gives the same key input (SPEC 6.2)" {
  for u in 'https://github.com/Owner/Repo.git' 'https://user:ghp_secret123@github.com/owner/repo' \
    'https://oauth2:glpat-xyz@github.com/owner/repo/' 'git@github.com:owner/repo.git' \
    'ssh://git@github.com:22/owner/repo' 'https://github.com/owner/repo?x=1#frag'; do
    [ "$(cs_git_remote_normalize "$u")" = github.com/owner/repo ] || { echo "bad: $u"; return 1; }
  done
  [ "$(cs_git_remote_normalize 'https://gitlab.example.com/group/sub/repo.git')" = gitlab.example.com/group/sub/repo ]
  run cs_git_remote_normalize /local/path/repo
  [ "$status" -eq 1 ]
  run cs_git_remote_normalize 'file:///x/y'
  [ "$status" -eq 1 ]
}

@test "remote_keys: hashes only; a token in the URL never reaches state, config or logs" {
  command -v git >/dev/null || skip "git missing"
  git -C "$T/work/TransFlowX" init -q
  git -C "$T/work/TransFlowX" remote add origin 'https://oauth2:ghp_SECRETTOKEN@github.com/Owner/TransFlow.git'
  git -C "$T/work/TransFlowX" remote add up 'git@github.com:owner/transflow.git'
  k=$(cs_remote_keys "$(native "$T/work/TransFlowX")")
  [[ $k =~ ^[0-9a-f]{64}$ ]] # both remotes normalize to the same key
  [ "$k" = "$(printf 'claude-sync:remote:github.com/owner/transflow' | cs_sha256_hex -)" ]
  mkdir -p "$CLAUDE_SYNC_HOME/logs"
  cs_project_map TransFlow "$T/work/TransFlowX" >/dev/null 2>&1
  [ "$(cs_tsv_field projects remote_keys "$(cs_project_find TransFlow)" "$(native "$T/work/TransFlowX")")" = "$k" ]
  ! grep -rq 'SECRETTOKEN\|github.com/owner' "$CLAUDE_SYNC_HOME"
  [ -z "$(cs_remote_keys "$(native "$T/work/other")")" ]
}

@test "map: new project, second root joins it, membership uses the longest root" {
  session s-a a1 "$(native "$T/work/TransFlowX/apps")"
  IFS=$'\t' read -r id root state < <(cs_project_map TransFlow "$T/work/TransFlowX" 2>/dev/null)
  [[ $id =~ ^[0-9a-f]{8}$ ]]
  [ "$state" = new ]
  [ "$root" = "$(native "$T/work/TransFlowX")" ]
  IFS=$'\t' read -r id2 _ state2 < <(cs_project_map TransFlow "$T/work/other" 2>/dev/null)
  [ "$id2" = "$id" ]
  [ "$state2" = added ]
  IFS=$'\t' read -r _ _ state3 < <(cs_project_map "$id" "$T/work/other" 2>/dev/null)
  [ "$state3" = existing ]
  [ "$(cs_project_of_cwd "$(native "$T/work/TransFlowX/apps")")" = "$id" ]
  mkdir -p "$T/work/TransFlowX/inner"
  IFS=$'\t' read -r iid _ _ < <(cs_project_map Inner "$T/work/TransFlowX/inner" 2>/dev/null)
  [ "$(cs_project_of_cwd "$(native "$T/work/TransFlowX/inner/z")")" = "$iid" ]
  run cs_project_of_cwd "$(native "$T/elsewhere")"
  [ "$status" -eq 1 ]
}

@test "map warns about nested roots and folders without sessions; a missing folder is an error" {
  run cs_project_map A "$T/work/TransFlowX"
  [[ $output == *'no Claude session on this machine was started under'* ]]
  mkdir -p "$T/work/TransFlowX/sub"
  run cs_project_map B "$T/work/TransFlowX/sub"
  [[ $output == *overlaps* ]]
  run cs_project_map C "$T/nope"
  [ "$status" -eq 1 ]
}

@test "unmap one root or the whole project; exclude removes it from membership" {
  IFS=$'\t' read -r id _ _ < <(cs_project_map P "$T/work/TransFlowX" 2>/dev/null)
  cs_project_map P "$T/work/other" >/dev/null 2>&1
  cs_project_unmap P "$T/work/other"
  [ "$(cs_tsv_rows projects | wc -l)" -eq 1 ]
  cs_project_set_enabled P 0
  run cs_project_of_cwd "$(native "$T/work/TransFlowX")"
  [ "$status" -eq 1 ]
  cs_project_set_enabled P 1
  [ "$(cs_project_of_cwd "$(native "$T/work/TransFlowX")")" = "$id" ]
  cs_project_unmap "$id"
  [ -z "$(cs_tsv_rows projects)" ]
}

@test "Windows: the root takes the spelling Claude uses in transcripts (P2)" {
  cs_is_windows || skip "Windows only"
  n=$(native "$T/work/TransFlowX")
  claude_spelling="${n,,}" # transcripts say c:\...\transflowx
  session s-a a1 "$claude_spelling\\apps"
  session s-a a2 "$claude_spelling"
  run cs_project_map T "$T/work/TransFlowX"
  [[ $output == *"Claude writes it as $claude_spelling"* ]]
  [ "$(cs_tsv_rows projects | cut -f2)" = "$claude_spelling" ]
}

@test "Linux: a symlinked folder maps to its physical path like Claude's cwd (P2)" {
  cs_is_windows && skip "Linux only"
  ln -s "$T/work/TransFlowX" "$T/link"
  IFS=$'\t' read -r _ root _ < <(cs_project_map T "$T/link" 2>/dev/null)
  [ "$root" = "$(cd "$T/work/TransFlowX" && pwd -P)" ]
}

@test "memory dir: slug of the main work tree, existing on-disk spelling, autoMemoryDirectory override" {
  r=$(native "$T/work/TransFlowX")
  m=$(cs_mem_dir "$r")
  [ "$m" = "$(native "$CS_CLAUDE_DIR")$(cs_is_windows && echo '\projects\' || echo /projects/)$(cc_slug "$r")$(cs_is_windows && echo '\memory' || echo /memory)" ]
  if cs_is_windows; then
    odd=$(cc_slug "$r")
    odd="${odd,,}"
    mkdir -p "$CS_CLAUDE_DIR/projects/$odd/memory"
    [[ $(cs_mem_dir "$r") == *"\\$odd\\memory" ]]
  fi
  mkdir -p "$T/work/TransFlowX/.claude"
  printf '{"autoMemoryDirectory":"%s"}' "$(cs_json_escape "$(native "$T/mem")")" >"$T/work/TransFlowX/.claude/settings.json"
  [ "$(cs_mem_dir "$r")" = "$(native "$T/mem")" ]
}

@test "transform rows: P, R and MEM per enabled project, plus {CFG}/plans" {
  IFS=$'\t' read -r id _ _ < <(cs_project_map TransFlow "$T/work/TransFlowX" 2>/dev/null)
  rows=$(cs_project_rows)
  [ "$(cut -f1,2 <<<"$rows" | tr '\t\n' ' |')" = "P {P:$id}|R {R:$id}|A {MEM:$id}|A {CFG}/plans|" ]
  cs_project_set_enabled TransFlow 0
  [ "$(cs_project_rows | cut -f2)" = '{CFG}/plans' ]
}

@test "list shows mapped projects and unmapped folders; select maps the chosen ones" {
  session s-a a1 "$(native "$T/work/TransFlowX/apps")"
  session s-b b1 "$(native "$T/work/other")"
  session s-b b2 "$(native "$T/work/other")"
  run cs_projects_list
  [[ $output == *'(none yet'* ]]
  [[ $output == *"$(native "$T/work/other")"* ]]
  unset CS_LAUNCH_CWDS
  out=$(printf '2\n' | cs_projects_select 2>&1)
  [ "$(cs_config_get mode)" = selected ]
  [ "$(cs_tsv_rows projects | wc -l)" -eq 1 ]
  unset CS_LAUNCH_CWDS
  out=$(printf 'a\n' | cs_projects_select 2>&1)
  [ "$(cs_config_get mode)" = all ]
  [ "$(cs_tsv_rows projects | wc -l)" -eq 2 ]
  unset CS_LAUNCH_CWDS
  run cs_projects_list
  [[ $output != *'not synced'* ]]
}

@test "select never merges two different folders that share a name" {
  mkdir -p "$T/a/app" "$T/b/app"
  session s-1 x1 "$(native "$T/a/app")"
  session s-2 x2 "$(native "$T/b/app")"
  printf 'a\n' | cs_projects_select >/dev/null 2>&1
  [ "$(cs_tsv_rows projects | cut -f1 | sort -u | wc -l)" -eq 2 ]
}

@test "CLI: projects map/list/mode/exclude/include/unmap and usage errors" {
  run cli projects map Demo "$T/work/TransFlowX"
  [ "$status" -eq 0 ]
  [[ $output == *'Mapped Demo'* ]]
  run cli projects list
  [[ $output == *Demo* ]]
  run cli projects mode selected
  [ "$(cs_config_get mode)" = selected ]
  run cli projects exclude Demo
  [[ $output == *Excluded* ]]
  run cli projects include Demo
  run cli projects unmap Demo
  [ "$status" -eq 0 ]
  run cli projects map onlyone
  [ "$status" -eq 2 ]
  run cli projects mode nope
  [ "$status" -eq 2 ]
}
