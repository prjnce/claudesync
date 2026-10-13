# shellcheck shell=bash
# projects: project identity and mapping (SPEC §6, §6.2, §16 step 8). A project has an 8-hex id, an alias
# and one or more roots on this machine, stored in state/projects.tsv (one row per root):
#   project_id cwd_root alias real_root mem_dir enabled remote_keys
# cwd_root is spelled exactly as Claude writes it into "cwd" (native form: D:\x on Windows, /x on Linux).
# Requires core, platform, store, claude, transform, version.

[[ -n ${CS_PROJECTS_LOADED:-} ]] && return 0
CS_PROJECTS_LOADED=1

# --- path forms -------------------------------------------------------------------------------------------

# cs_native_path PATH: the form Claude records on this OS. Windows: C:\x\y from C:\x, C:/x, /c/x;
# a trailing separator is dropped. Linux: unchanged (minus a trailing /).
cs_native_path() {
  local p=$1
  if [[ $CS_OS == windows ]]; then
    if [[ $p == /* && $p != //* ]]; then
      p=$(cygpath -w -- "$p") # /c/x, /tmp/x, /home/x -> C:\...
    fi
    p=${p//\//\\}
    if [[ $p =~ ^([A-Za-z]):(.*)$ ]]; then p="${BASH_REMATCH[1]^^}:${BASH_REMATCH[2]}"; fi
  fi
  while [[ ${#p} -gt 3 && ( $p == */ || $p == *\\ ) ]]; do p=${p%?}; done
  printf '%s\n' "$p"
}

# cs_posix_of_native PATH: a path this shell can open (Windows C:\x -> /c/x).
cs_posix_of_native() {
  if [[ $CS_OS == windows ]]; then cs_win_to_posix "$1"; else printf '%s\n' "$1"; fi
}

# cs_path_ci PATH: rc 0 if PATH compares case-insensitively (Windows drive paths, UNC, /mnt/<x>).
cs_path_ci() {
  [[ $1 =~ ^[A-Za-z]:([\\/]|$) || $1 == \\\\* || $1 =~ ^/mnt/[A-Za-z](/|$) ]]
}

# cs_path_under PATH ROOT: rc 0 if PATH equals ROOT or lies below it (path boundary; case rule of ROOT).
cs_path_under() {
  local p=$1 r=$2
  if cs_path_ci "$r"; then
    p=${p,,}
    r=${r,,}
    p=${p//\\//}
    r=${r//\\//}
  fi
  [[ $p == "$r" || $p == "$r"/* ]]
}

# --- remote_keys (SPEC §6.2) ------------------------------------------------------------------------------

# cs_git_remote_normalize URL -> host/owner/repo (lower case, no scheme, userinfo, port, query, .git);
# rc 1 if URL is not a recognisable remote. Credentials never survive this function.
cs_git_remote_normalize() {
  local u=$1 host path
  u=${u%%#*}
  u=${u%%\?*}
  if [[ $u =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
    u=${u#*://}
    host=${u%%/*}
    path=${u#"$host"}
    host=${host##*@}  # userinfo: user, user:password, oauth2:token
    host=${host%%:*}  # port
  elif [[ $u =~ ^([^@/:]+@)?([^/:]+):(.+)$ ]]; then
    host=${BASH_REMATCH[2]} # scp-like git@host:owner/repo
    path=/${BASH_REMATCH[3]}
  else
    return 1
  fi
  [[ $host == *.* || $host == localhost ]] || return 1
  path=${path%/}
  path=${path%.git}
  path=${path#/}
  [[ $path == */* ]] || return 1
  printf '%s/%s\n' "${host,,}" "${path,,}"
}

# cs_remote_keys DIR: comma-separated sha256 keys of every git remote of DIR (empty if not a git repo).
# The raw URL and the normalized form live only in local variables.
cs_remote_keys() {
  local d=$1 url norm keys=() k
  command -v git >/dev/null 2>&1 || return 0
  while IFS= read -r url; do
    norm=$(cs_git_remote_normalize "$url") || continue
    k=$(printf 'claude-sync:remote:%s' "$norm" | cs_sha256_hex -)
    [[ " ${keys[*]} " == *" $k "* ]] || keys+=("$k")
  done < <(git -C "$(cs_posix_of_native "$d")" remote -v 2>/dev/null | tr -d '\r' | "$CS_AWK" '{ print $2 }' | sort -u)
  local IFS=,
  printf '%s\n' "${keys[*]}"
}

# --- root discovery ---------------------------------------------------------------------------------------

# cs_git_toplevel DIR: native path of the git work tree containing DIR (rc 1 if none).
cs_git_toplevel() {
  local t
  command -v git >/dev/null 2>&1 || return 1
  t=$(git -C "$(cs_posix_of_native "$1")" rev-parse --show-toplevel 2>/dev/null | tr -d '\r') || return 1
  [[ -n $t ]] || return 1
  cs_native_path "$t"
}

# cs_git_main_worktree DIR: native path of the MAIN work tree (memory is keyed by it, not by a linked one).
cs_git_main_worktree() {
  local t
  command -v git >/dev/null 2>&1 || return 1
  t=$(git -C "$(cs_posix_of_native "$1")" worktree list --porcelain 2>/dev/null | tr -d '\r' | sed -n '1s/^worktree //p') || return 1
  [[ -n $t ]] || return 1
  cs_native_path "$t"
}

# cs_mem_dir ROOT: the memory dir Claude uses for ROOT (autoMemoryDirectory wins; SPEC §6).
cs_mem_dir() {
  local root=$1 base auto f
  for f in "$(cs_posix_of_native "$root")/.claude/settings.local.json" "$(cs_posix_of_native "$root")/.claude/settings.json" "$(cs_claude_dir)/settings.json"; do
    [[ -f $f ]] || continue
    auto=$(cs_jq -r '.autoMemoryDirectory // empty' "$f" 2>/dev/null) || auto=
    [[ -n $auto ]] && {
      cs_native_path "$auto"
      return 0
    }
  done
  base=$(cs_git_main_worktree "$root") || base=$root
  base=$(cs_root_spelling "$base")
  local slug pdir d
  slug=$(cs_claude_slug "$base")
  pdir="$(cs_claude_dir)/projects"
  # Claude keys memory by the cwd spelling (d: from VS Code, D: from a terminal); on a case-insensitive
  # disk both are one directory, so use the name that exists (SPEC §8 rule 2).
  if cs_path_ci "$base" && [[ -d $pdir ]]; then
    for d in "$pdir"/*/; do
      d=${d%/}
      d=${d##*/}
      [[ ${d,,} == "${slug,,}" ]] && {
        slug=$d
        break
      }
    done
  fi
  cs_native_path "$(cs_claude_dir)/projects/$slug/memory"
}

# cs_native_of_posix PATH: this shell's path in the form Claude writes (/c/x -> C:\x on Windows).
cs_native_of_posix() {
  cs_native_path "$1"
}

# cs_launch_cache_init: compute cs_local_launch_cwds once and keep it in CS_LAUNCH_CWDS (current shell).
cs_launch_cache_init() {
  [[ -n ${CS_LAUNCH_CWDS+set} ]] && return 0
  CS_LAUNCH_CWDS=$(cs_local_launch_cwds_scan)
}

# cs_local_launch_cwds: "launch cwd<TAB>sessions<TAB>bytes" for every local transcript.
cs_local_launch_cwds() {
  if [[ -n ${CS_LAUNCH_CWDS+set} ]]; then
    [[ -n $CS_LAUNCH_CWDS ]] && printf '%s\n' "$CS_LAUNCH_CWDS"
    return 0
  fi
  cs_local_launch_cwds_scan
}

# cs_local_launch_cwds_scan: "launch cwd<TAB>sessions<TAB>bytes". Reading a launch cwd means reading the transcript, so the
# answer per transcript is remembered in state/launch_cache.tsv (sid, size, mtime, cwd) and recomputed only for
# transcripts whose size or mtime changed (R2: a 58 MB transcript must not be read again every cycle).
cs_local_launch_cwds_scan() {
  local dir slug sid size mt cwd cache="" tmp key csize cmt ccwd
  local -A c_size=() c_mt=() c_cwd=()
  dir="$(cs_claude_dir)/projects"
  if [[ -n ${CS_HOME:-} && -d $CS_HOME/state ]]; then
    cache="$CS_HOME/state/launch_cache.tsv"
    if [[ -f $cache ]]; then
      while IFS=$'\t' read -r key csize cmt ccwd; do
        [[ -n $key ]] || continue
        c_size[$key]=$csize c_mt[$key]=$cmt c_cwd[$key]=$ccwd
      done <"$cache"
    fi
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/cs-launch.XXXXXX")
  while IFS=$'\t' read -r slug sid size mt; do
    [[ -n $sid && $slug =~ ^[A-Za-z0-9_-]+$ ]] || continue
    key="$slug/$sid"
    if [[ ${c_size[$key]:-} == "$size" && ${c_mt[$key]:-} == "$mt" && -n ${c_cwd[$key]:-} ]]; then
      cwd=${c_cwd[$key]}
    else
      cwd=$(cs_launch_cwd "$dir/$slug/$sid.jsonl") || continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$key" "$size" "$mt" "$cwd" >>"$tmp"
  done < <(cs_claude_scan)
  if [[ -n $cache ]]; then
    cp -- "$tmp" "$cache.tmp.$$" && mv -f -- "$cache.tmp.$$" "$cache"
  fi
  "$CS_AWK" -F'\t' -v OFS='\t' '{ n[$4]++; b[$4] += $2 } END { for (c in n) print c, n[c], b[c] }' "$tmp" | sort
  rm -f -- "$tmp"
}

# cs_root_spelling ROOT: the spelling of ROOT that local transcripts use (case-insensitive match on
# Windows, most frequent wins); ROOT itself when no transcript matches.
cs_root_spelling() {
  local root=$1 best
  cs_path_ci "$root" || {
    printf '%s\n' "$root"
    return 0
  }
  best=$(cs_local_launch_cwds | R=$root "$CS_AWK" -F'\t' '
    BEGIN { r = tolower(ENVIRON["R"]); gsub(/\\/, "/", r); rl = length(r) }
    { c = $1; lc = tolower(c); gsub(/\\/, "/", lc)
      if (lc == r || substr(lc, 1, rl + 1) == r "/") { s = substr(c, 1, rl); cnt[s] += $2 } }
    END { m = 0; for (s in cnt) if (cnt[s] > m) { m = cnt[s]; b = s } print b }')
  printf '%s\n' "${best:-$root}"
}

# cs_root_of_launch CWD: candidate project root for a launch dir: its git top level when that exists on
# this machine, else the dir itself.
cs_root_of_launch() {
  local top
  if top=$(cs_git_toplevel "$1" 2>/dev/null); then
    cs_root_spelling "$top"
  else
    printf '%s\n' "$1"
  fi
}

# --- the projects table ----------------------------------------------------------------------------------

cs_new_project_id() {
  od -An -N4 -tx1 /dev/urandom | tr -d ' \n'
  printf '\n'
}

# cs_project_find ALIAS_OR_ID: the project_id with that id or alias (case-insensitive alias); rc 1 if none.
cs_project_find() {
  cs_tsv_rows projects | A=$1 "$CS_AWK" -F'\t' '$1 == ENVIRON["A"] || tolower($3) == tolower(ENVIRON["A"]) { print $1; exit }' | grep . || return 1
}

# cs_project_of_cwd CWD: id of the enabled project whose root contains CWD (longest root wins); rc 1 if none.
cs_project_of_cwd() {
  local id root en best='' bl=0
  while IFS=$'\t' read -r id root _ _ _ en _; do
    [[ $en == 1 ]] || continue
    cs_path_under "$1" "$root" || continue
    ((${#root} > bl)) && {
      best=$id
      bl=${#root}
    }
  done < <(cs_tsv_rows projects)
  [[ -n $best ]] || return 1
  printf '%s\n' "$best"
}

# cs_project_map ALIAS_OR_ID PATH [PROJECT_ID]: map PATH as a root of an existing project, or of a new project
# named ALIAS (with PROJECT_ID when it is given). Prints "project_id<TAB>cwd_root<TAB>new|added|existing". Warnings go to stderr.
cs_project_map() {
  local name=$1 path=$2 posix native root real mem keys id state=added other
  posix=$(cs_posix_of_native "$(cs_native_path "$path")")
  [[ $CS_OS == linux ]] && posix=$path
  [[ -d $posix ]] || cs_die_t "$CS_EXIT_ERROR" projects.no_dir "$path"
  if [[ $CS_OS == linux ]]; then
    native=$(cd -- "$posix" && pwd -P)
  else
    native=$(cs_native_path "$path")
  fi
  cs_launch_cache_init
  root=$(cs_root_spelling "$native")
  [[ $root == "$native" ]] || cs_say projects.spelling "$native" "$root" >&2
  local c found=0
  while IFS=$'\t' read -r c _; do
    [[ -n $c ]] && cs_path_under "$c" "$root" && {
      found=1
      break
    }
  done <<<"$CS_LAUNCH_CWDS"
  ((found)) || cs_say projects.no_sessions_here "$root" >&2
  # Overlap with other projects' roots (nested roots are allowed but worth a warning).
  while IFS=$'\t' read -r other orow _; do
    if [[ $other != "$(cs_project_find "$name" 2>/dev/null)" ]] && { cs_path_under "$root" "$orow" || cs_path_under "$orow" "$root"; }; then
      cs_say projects.nested "$root" "$orow" >&2
    fi
  done < <(cs_tsv_rows projects)
  real=$(cs_realpath_disk "$(cs_posix_of_native "$root")" 2>/dev/null) || real=$root
  [[ -n $real ]] || real=$root
  mem=$(cs_mem_dir "$root")
  keys=$(cs_remote_keys "$root")
  if id=$(cs_project_find "$name"); then
    cs_tsv_get projects "$id" "$root" >/dev/null && state=existing
  else
    id=${3:-$(cs_new_project_id)} # a project from another machine keeps its project_id
    state=new
  fi
  local alias
  alias=$(cs_tsv_rows projects | I=$id "$CS_AWK" -F'\t' '$1 == ENVIRON["I"] { print $3; exit }')
  [[ -n $alias ]] || alias=$name
  [[ $state == new && $name =~ ^[0-9a-f]{8}$ ]] && alias=${root##*[\\/]}
  cs_tsv_upsert projects "$id" "$root" "$alias" "$real" "$mem" 1 "$keys"
  printf '%s\t%s\t%s\n' "$id" "$root" "$state"
}

# cs_project_published ID: rc 0 if anything of project ID already left this machine's state (a session row, a
# manifest session or memory scope, memory base files). Published segments carry {P:id} tokens, so such a
# project can no longer change its id.
cs_project_published() {
  local id=$1 m
  cs_tsv_rows sessions | I=$id "$CS_AWK" -F'\t' '$2 == ENVIRON["I"] { f = 1 } END { exit !f }' && return 0
  [[ -d $CS_HOME/state/base/mem/$id ]] && [[ -n $(find "$CS_HOME/state/base/mem/$id" -type f -print -quit 2>/dev/null) ]] && return 0
  m="$CS_HOME/state/manifest.json" # read directly: this file is also used by commands that do not load the engine
  [[ -f $m ]] || return 1
  cs_jq -e --arg p "$id" '([(.sessions // {})[] | select(.project == $p)] | length > 0) or ((.memory // {}) | has($p))' "$m" >/dev/null 2>&1
}

# cs_project_rekey OLD_ID NEW_ID: give a local project the project_id of the same project on another machine.
# Only while nothing of OLD_ID was published (cs_project_published); rc 1 with a message otherwise.
cs_project_rekey() {
  local old=$1 new=$2 rows root
  [[ $new =~ ^[A-Za-z0-9_-]+$ ]] || cs_die_t "$CS_EXIT_ERROR" projects.unknown "$new"
  cs_tsv_rows projects | cut -f1 | grep -qx -- "$old" || cs_die_t "$CS_EXIT_ERROR" projects.unknown "$old"
  [[ $old == "$new" ]] && return 0
  if cs_tsv_rows projects | cut -f1 | grep -qx -- "$new"; then
    cs_say projects.rekey_exists "$new" >&2
    return 1
  fi
  if cs_project_published "$old"; then
    cs_say projects.rekey_published "$old" >&2
    return 1
  fi
  # Read everything first: rewriting a file another process still reads fails on Windows.
  rows=$(cs_tsv_rows projects | I=$old N=$new "$CS_AWK" -F'\t' -v OFS='\t' '$1 == ENVIRON["I"] { old = $1; $1 = ENVIRON["N"]; print old, $0 }')
  while IFS=$'\t' read -r _ _ root _; do
    [[ -n $root ]] && cs_tsv_delete projects "$old" "$root"
  done <<<"$rows"
  printf '%s\n' "$rows" | cut -f2- | cs_tsv_upsert_many projects
}

# cs_project_unmap ALIAS_OR_ID [PATH]: remove one root, or every root of the project.
cs_project_unmap() {
  local id root
  local rows want=
  id=$(cs_project_find "$1") || cs_die_t "$CS_EXIT_ERROR" projects.unknown "$1"
  [[ -n ${2:-} ]] && want=$(cs_native_path "$2")
  rows=$(cs_tsv_rows projects)
  while IFS=$'\t' read -r pid root _; do
    [[ $pid == "$id" ]] || continue
    if [[ -z $want ]] || { cs_path_under "$root" "$want" && cs_path_under "$want" "$root"; }; then
      cs_tsv_delete projects "$pid" "$root"
    fi
  done <<<"$rows"
}

# cs_project_set_enabled ALIAS_OR_ID 0|1: (exclude/include) every root of the project.
cs_project_set_enabled() {
  local id rows
  id=$(cs_project_find "$1") || cs_die_t "$CS_EXIT_ERROR" projects.unknown "$1"
  # Read everything first: rewriting a file another process still reads fails on Windows.
  rows=$(cs_tsv_rows projects | I=$id E=$2 "$CS_AWK" -F'\t' -v OFS='\t' '$1 == ENVIRON["I"] { $6 = ENVIRON["E"]; print }')
  [[ -n $rows ]] && printf '%s\n' "$rows" | cs_tsv_upsert_many projects
}

# cs_project_rows MODE: transform rows (lib/transform.sh) for every enabled project of this machine, plus
# {CFG}/plans. A project with several roots: the first row of each token is its primary root.
cs_project_rows() {
  local id root alias real mem en keys
  while IFS=$'\t' read -r id root alias real mem en keys; do
    [[ $en == 1 ]] || continue
    cs_transform_row P "{P:$id}" "$root"
    cs_transform_row R "{R:$id}" "$real"
    [[ -n $mem ]] && cs_transform_row A "{MEM:$id}" "$mem"
  done < <(cs_tsv_rows projects)
  cs_transform_row A '{CFG}/plans' "$(cs_native_of_posix "$(cs_claude_dir)")$([[ $CS_OS == windows ]] && echo '\plans' || echo /plans)"
}
