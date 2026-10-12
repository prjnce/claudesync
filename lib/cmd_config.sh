# shellcheck shell=bash
# cmd_config: `claude-sync config get|set` (SPEC §20). Requires core, scheduler (for interval), ui.

[[ -n ${CS_CMD_CONFIG_LOADED:-} ]] && return 0
CS_CMD_CONFIG_LOADED=1

# The keys a user may set, with their allowed values (a regex) and defaults.
cs_config_spec() { # KEY -> "regex<TAB>default" (rc 1 for an unknown key)
  case $1 in
    interval) printf '^[0-9]+$\t5\n' ;; # 1..1440 minutes, checked by cs_interval_ok
    guard) printf '^(block|warn|off)$\tblock\n' ;;
    throttle_live_min) printf '^[0-9]+$\t15\n' ;;
    lang) printf '^(en|vi)$\ten\n' ;;
    mode) printf '^(all|selected)$\tall\n' ;;
    scan_dirs) printf '^.*$\t\n' ;;
    wsl_distro | wsl_user) printf '^[A-Za-z0-9._-]*$\t\n' ;;
    machine_name) printf '^[^[:cntrl:]]+$\t\n' ;;
    *) return 1 ;;
  esac
}

cmd_config() {
  local sub=${1:-get} key val spec re def k
  shift || true
  case $sub in
    get)
      if (($# == 0)); then
        for k in interval guard throttle_live_min lang mode scan_dirs machine_name wsl_distro wsl_user; do
          IFS=$'\t' read -r _ def <<<"$(cs_config_spec "$k")"
          printf '%s=%s\n' "$k" "$(cs_config_get "$k" "$def")"
        done
        return 0
      fi
      key=$1
      spec=$(cs_config_spec "$key") || cs_die_t "$CS_EXIT_USAGE" config.unknown_key "$key"
      IFS=$'\t' read -r _ def <<<"$spec"
      cs_config_get "$key" "$def"
      ;;
    set)
      (($# == 2)) || cs_die_t "$CS_EXIT_USAGE" config.usage
      key=$1 val=$2
      spec=$(cs_config_spec "$key") || cs_die_t "$CS_EXIT_USAGE" config.unknown_key "$key"
      IFS=$'\t' read -r re _ <<<"$spec"
      [[ $val =~ $re ]] || cs_die_t "$CS_EXIT_USAGE" config.bad_value "$val" "$key"
      if [[ $key == interval ]]; then
        cs_interval_ok "$val" || cs_die_t "$CS_EXIT_USAGE" config.bad_value "$val" "$key"
        val=$((10#$val))
      fi
      cs_config_set "$key" "$val"
      [[ $key == interval ]] && cs_sched_set_interval "$val"
      cs_say config.set "$key" "$val"
      ;;
    *) cs_die_t "$CS_EXIT_USAGE" config.usage ;;
  esac
}
