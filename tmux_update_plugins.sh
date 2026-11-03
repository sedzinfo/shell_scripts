#!/usr/bin/env bash
# Updates the tmux plugins that TPM (the tmux plugin manager) installed, without
# touching your tmux configuration (~/.tmux.conf) or the sessions tmux-resurrect
# saved. For each plugin it:
#   - repairs what copying the plugin folder breaks: lost executable bits (then
#     tmux cannot run the plugin), symlinks turned into plain files, missing
#     submodules, and folders anyone can write to; a plugin with files you
#     edited yourself is left as it is (git -C <plugin> diff shows the edits)
#   - updates it from GitHub, only forward (git merge --ff-only), so commits of
#     your own are never lost
# It also says when apt has a newer tmux (and asks before installing it), lists
# the plugins of your configuration that are not installed, and checks at the
# end that your configuration files are unchanged, byte for byte.
#   tmux_update_plugins.sh             repairs and updates every plugin
#   tmux_update_plugins.sh --dry-run   only shows what it would do
# The plugins are in ~/.tmux/plugins, or in ~/.config/tmux/plugins with a
# ~/.config/tmux/tmux.conf, or in $TMUX_PLUGIN_MANAGER_PATH. The exit code is 1
# if a plugin could not be updated.

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    *)         echo "Unknown option: $arg (see --help)"; exit 1 ;;
  esac
done

red=$'\e[31m'; yellow=$'\e[33m'; green=$'\e[32m'; bold=$'\e[1m'; reset=$'\e[0m'

# a line of 80 # characters, between the plugins
separator() { printf '#%.0s' {1..80}; printf '\n'; }

# a count with its noun: 1 symlink, 3 symlinks
plural() { [ "$1" -eq 1 ] && echo "1 $2" || echo "$1 $2s"; }

yes_no() {
  local answer
  read -r -p "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

for program in git tmux; do
  command -v "$program" > /dev/null || { echo "$program is needed (sudo apt install $program)"; exit 1; }
done

# the configuration files tmux reads, and the folder TPM installs plugins in
xdg="${XDG_CONFIG_HOME:-$HOME/.config}/tmux"
configs=()
for file in "$HOME/.tmux.conf" "$xdg/tmux.conf"; do
  [ -f "$file" ] && configs+=("$file")
done
if [ -n "${TMUX_PLUGIN_MANAGER_PATH:-}" ]; then
  plugins="${TMUX_PLUGIN_MANAGER_PATH%/}"
elif [ ! -f "$HOME/.tmux.conf" ] && [ -f "$xdg/tmux.conf" ]; then
  plugins="$xdg/plugins"
else
  plugins="$HOME/.tmux/plugins"
fi
if [ ! -d "$plugins" ]; then
  echo "No plugins in $plugins: TPM is not installed (https://github.com/tmux-plugins/tpm)"; exit 1
fi

# a checksum of the configuration, to show at the end that it was not touched
config_sum() { [ ${#configs[@]} -gt 0 ] && sha256sum "${configs[@]}"; }
config_before=$(config_sum)

echo "tmux $(tmux -V | cut -d' ' -f2), plugins in $plugins"
[ $dry_run -eq 1 ] && echo "Dry run: nothing is changed"

# a newer tmux from apt; installing it never touches your configuration
if command -v apt > /dev/null; then
  newer=$(apt list --upgradable 2> /dev/null | grep '^tmux/' | cut -d' ' -f2)
  if [ -n "$newer" ]; then
    echo "${yellow}apt has tmux $newer${reset}"
    if [ $dry_run -eq 0 ] && [ -t 0 ] && yes_no "Install it with sudo apt install --only-upgrade tmux?"; then
      sudo apt install --only-upgrade -y tmux
    fi
  fi
fi

# the plugins your configuration asks for: set -g @plugin 'owner/name' (or a git URL, or name#branch)
wanted=()
if [ ${#configs[@]} -gt 0 ]; then
  while IFS= read -r spec; do
    spec=${spec%%#*}; spec=${spec%.git}; wanted+=("${spec##*/}")
  done < <(sed -nE "s/^[[:space:]]*set(-option)?[[:space:]]+(-g[[:space:]]+)?@plugin[[:space:]]+['\"]([^'\"]+)['\"].*/\3/p" "${configs[@]}")
fi

updated=(); current=(); skipped=(); failed=()
for dir in "$plugins"/*/; do
  dir=${dir%/}
  name=$(basename "$dir")
  echo
  separator
  if [ ! -d "$dir/.git" ]; then
    echo "${bold}$name${reset}  not a git repository: skipped"
    skipped+=("$name"); continue
  fi
  echo "${bold}$name${reset}  ($(git -C "$dir" remote get-url origin 2> /dev/null))"

  # what copying broke, told apart from edits: git's own list of what differs from
  # the last commit, ignoring file modes; a symlink (120000) or submodule (160000)
  # that is now something else is damage, any other difference is an edit
  links=(); submodules=0; edits=()
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    old_mode=${meta:1:6}
    case "$old_mode" in
      120000) links+=("$path") ;;
      160000) submodules=1 ;;
      *)      edits+=("$path") ;;
    esac
  done < <(git -C "$dir" -c core.fileMode=false diff --raw -z HEAD 2> /dev/null)
  modes=$(git -C "$dir" -c core.fileMode=true diff --summary HEAD 2> /dev/null | grep -c 'mode change')
  # .git too: a hook planted there would run when git updates the plugin
  open=$(find "$dir" -perm -o+w ! -type l 2> /dev/null | wc -l)

  repairs=()
  [ "$modes" -gt 0 ] && repairs+=("$(plural "$modes" "file permission")")
  [ ${#links[@]} -gt 0 ] && repairs+=("$(plural ${#links[@]} symlink)")
  [ $submodules -eq 1 ] && repairs+=("submodules")
  [ "$open" -gt 0 ] && repairs+=("$open files and folders anyone could write to")
  if [ ${#repairs[@]} -gt 0 ]; then
    if [ $dry_run -eq 1 ]; then
      echo "  would repair: $(IFS=,; echo "${repairs[*]}" | sed 's/,/, /g')"
    else
      # file modes as git has them: 755 for scripts, 644 for the rest
      while IFS= read -r -d '' entry; do
        mode=${entry%% *}; path=${entry#*$'\t'}
        [ -f "$dir/$path" ] && [ ! -L "$dir/$path" ] || continue
        case "$mode" in
          100755) chmod 755 "$dir/$path" ;;
          100644) chmod 644 "$dir/$path" ;;
        esac
      done < <(git -C "$dir" ls-files -s -z)
      [ ${#links[@]} -gt 0 ] && git -C "$dir" checkout HEAD -- "${links[@]}"
      [ $submodules -eq 1 ] && git -C "$dir" submodule update --init --recursive --quiet
      chmod -R go-w "$dir"
      echo "  ${green}repaired: $(IFS=,; echo "${repairs[*]}" | sed 's/,/, /g')${reset}"
    fi
  fi

  if [ ${#edits[@]} -gt 0 ]; then
    echo "  ${yellow}your own edits in $(plural ${#edits[@]} file) (${edits[*]:0:3}): not updated, so they are kept${reset}"
    echo "    git -C $dir diff shows them"
    skipped+=("$name"); continue
  fi

  before=$(git -C "$dir" rev-parse --short HEAD)
  if ! git -C "$dir" fetch --quiet origin 2> /dev/null; then
    echo "  ${red}could not reach $(git -C "$dir" remote get-url origin)${reset}"
    failed+=("$name"); continue
  fi
  if ! git -C "$dir" rev-parse --verify --quiet '@{u}' > /dev/null; then
    echo "  ${yellow}branch $(git -C "$dir" rev-parse --abbrev-ref HEAD) follows no branch on GitHub: skipped${reset}"
    skipped+=("$name"); continue
  fi
  behind=$(git -C "$dir" rev-list --count 'HEAD..@{u}')
  ahead=$(git -C "$dir" rev-list --count '@{u}..HEAD')
  if [ "$ahead" -gt 0 ]; then
    echo "  ${yellow}$ahead commits of your own: not updated, so they are kept${reset}"
    skipped+=("$name"); continue
  fi
  if [ "$behind" -eq 0 ]; then
    echo "  up to date ($before)"
    current+=("$name"); continue
  fi
  if [ $dry_run -eq 1 ]; then
    echo "  would update: $behind new commits"
    git -C "$dir" log --format='    %cs %s' --max-count=5 'HEAD..@{u}'
    continue
  fi
  if git -C "$dir" merge --ff-only --quiet '@{u}' && git -C "$dir" submodule update --init --recursive --quiet; then
    echo "  ${green}updated $before -> $(git -C "$dir" rev-parse --short HEAD), $behind new commits${reset}"
    git -C "$dir" log --format='    %cs %s' --max-count=5 "$before..HEAD"
    updated+=("$name")
  else
    echo "  ${red}the update failed; the plugin is as it was${reset}"
    failed+=("$name")
  fi
done

echo
separator
missing=()
for name in "${wanted[@]}"; do
  [ -d "$plugins/$name" ] || missing+=("$name")
done
[ ${#updated[@]} -gt 0 ] && echo "${green}Updated: ${updated[*]}${reset}"
[ ${#current[@]} -gt 0 ] && echo "Up to date: ${current[*]}"
[ ${#skipped[@]} -gt 0 ] && echo "${yellow}Left as they are: ${skipped[*]}${reset}"
[ ${#failed[@]} -gt 0 ] && echo "${red}Could not update: ${failed[*]}${reset}"
[ ${#missing[@]} -gt 0 ] && echo "${yellow}In your configuration but not installed: ${missing[*]} ($plugins/tpm/bin/install_plugins installs them)${reset}"
if [ "$(config_sum)" = "$config_before" ]; then
  [ ${#configs[@]} -gt 0 ] && echo "${green}Unchanged: ${configs[*]}${reset}"
else
  echo "${red}A configuration file changed while this ran: ${configs[*]}${reset}"
fi
if [ $dry_run -eq 0 ] && [ ${#updated[@]} -gt 0 ] && tmux info > /dev/null 2>&1; then
  echo "tmux is running: tmux source-file ${configs[0]:-~/.tmux.conf} loads the updated plugins"
fi
[ ${#failed[@]} -eq 0 ]
