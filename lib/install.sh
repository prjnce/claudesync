# shellcheck shell=bash
# install: `claude-sync install` copies the runtime (bin/, lib/, launcher/) to $CS_HOME/app and writes the
# `claude-sync` shim that starts it. After that the unpacked release (or the clone) can be deleted or moved: the
# service and the hooks only ever use the copy. Running it again from a newer release upgrades the copy.
# It does not touch ~/.claude, Google Drive or the service (setup / service install do that).
# Requires core, platform, store, scheduler, ui.

[[ -n ${CS_INSTALL_LOADED:-} ]] && return 0
CS_INSTALL_LOADED=1

# cs_install_shim_dir: the directory the shim is written to (Windows Git Bash: ~/bin, else ~/.local/bin).
cs_install_shim_dir() {
  case ${CS_SCHED_KIND:-$CS_OS} in
    windows) printf '%s\n' "$HOME/bin" ;;
    *) cs_sched_shim_path | sed 's|/[^/]*$||' ;;
  esac
}

# cs_install_copy: the runtime to $CS_HOME/app, through a temporary directory so a failed copy leaves the old app.
cs_install_copy() {
  local dst="$CS_HOME/app" tmp="$CS_HOME/app.new.$$" old="$CS_HOME/app.old.$$" part
  mkdir -p -- "$tmp"
  for part in bin lib launcher; do
    [[ -d $CS_APP_DIR/$part ]] || continue
    cp -R -- "$CS_APP_DIR/$part" "$tmp/$part" || { rm -rf -- "$tmp"; cs_die_t "$CS_EXIT_ERROR" install.copy_failed "$dst"; }
  done
  chmod +x -- "$tmp/bin/claude-sync"
  if [[ -d $dst ]]; then
    mv -- "$dst" "$old" || { rm -rf -- "$tmp"; cs_die_t "$CS_EXIT_ERROR" install.in_use "$dst"; }
  fi
  if ! mv -- "$tmp" "$dst"; then
    [[ -d $old ]] && mv -- "$old" "$dst"
    rm -rf -- "$tmp"
    cs_die_t "$CS_EXIT_ERROR" install.copy_failed "$dst"
  fi
  rm -rf -- "$old"
}

# cs_install: see the header.
cs_install() {
  (($# == 0)) || cs_die_t "$CS_EXIT_USAGE" cli.unknown_command "install $1"
  local dst="$CS_HOME/app" dir
  mkdir -p -- "$CS_HOME"
  if [[ -d $dst && $(cd -- "$dst" && pwd -P) == "$CS_APP_DIR" ]]; then
    cs_say install.already "$dst"
  else
    cs_install_copy
    cs_say install.copied "$CS_VERSION" "$dst"
  fi
  case ${CS_SCHED_KIND:-$CS_OS} in
    windows) cs_sched_win_shim ;;
    *) cs_sched_shim_install ;;
  esac
  dir=$(cs_install_shim_dir)
  cs_say install.shim "$dir/claude-sync"
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) cs_say install.path_hint "$dir" "$dir" ;;
  esac
  cs_say install.next
}
