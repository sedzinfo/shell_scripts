#!/usr/bin/env bash
# Updates the tmux plugins that TPM (the tmux plugin manager) installed, without
# touching your tmux configuration (~/.tmux.conf) or the sessions tmux-resurrect
# saved. For each plugin it:
#   - repairs what copying the plugin folder breaks: lost executable bits (then
#     tmux cannot run the plugin), symlinks turned into copies of what they
#     pointed to, missing submodules, and folders anyone can write to; a plugin
#     with files you edited yourself, or commits of yours in a submodule, is not
#     updated (git -C <plugin> diff shows the edits), and a plugin folder that is
#     a link to one elsewhere is left alone
#   - updates it from GitHub, only forward (git merge --ff-only), so commits of
#     your own are never lost
#   - checks that every script of it can run: the files git marks executable, in
#     the plugin and its submodules, and the *.tmux files TPM runs
# It also says when apt has a newer tmux (and asks before installing it), lists
# the plugins of your configuration that are not installed, and checks at the
# end that your configuration files are unchanged, byte for byte. It first shows
# what it would repair and update, and asks.
#   tmux_update_plugins.sh             repairs and updates every plugin, after asking
#   tmux_update_plugins.sh --yes       without asking
#   tmux_update_plugins.sh --dry-run   only shows what it would do (git still
#                                      fetches what is new from GitHub)
# The plugins are in ~/.config/tmux/plugins when there is a
# ~/.config/tmux/tmux.conf (as TPM has it), or else in ~/.tmux/plugins, or in
# $TMUX_PLUGIN_MANAGER_PATH. The exit code is 1 if a plugin could not be updated
# or a script of it cannot run.

dry_run=0; yes=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --yes)     yes=1 ;;
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

# the git repositories of a plugin: the plugin itself and its submodules
repositories() {
  echo "$1"
  git -C "$1" submodule foreach --quiet --recursive 'echo "$toplevel/$sm_path"' 2> /dev/null
}

# the files of a repository whose executable bit is not the one git has for
# them (100755: a script, 100644: not); with "fix" it sets them right (755 or
# 644). With "top" (the plugin itself), its *.tmux files are left to
# check_tmux_files, which wants them executable whatever git has. Prints how many
# there were
check_modes() {
  local repo=$1 fix=${2:-} top=${3:-} entry mode file path count=0
  while IFS= read -r -d '' entry; do
    mode=${entry%% *}; file=${entry#*$'\t'}; path=$repo/$file
    [ -n "$top" ] && [[ "$file" == *.tmux && "$file" != */* ]] && continue
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    if [ "$mode" = 100755 ] && [ ! -x "$path" ]; then
      count=$((count + 1)); [ -n "$fix" ] && chmod 755 "$path"
    elif [ "$mode" = 100644 ] && [ -x "$path" ]; then
      count=$((count + 1)); [ -n "$fix" ] && chmod 644 "$path"
    fi
  done < <(git -C "$repo" ls-files -s -z 2> /dev/null)
  echo "$count"
}

# TPM runs every *.tmux file at the top of a plugin, so each must be executable
# (even if its author forgot to mark it so in git); with "fix" it makes them so.
# Prints how many were not
check_tmux_files() {
  local count=0 file
  for file in "$1"/*.tmux; do
    [ -f "$file" ] && [ ! -x "$file" ] || continue
    count=$((count + 1)); [ -n "${2:-}" ] && chmod 755 "$file"
  done
  echo "$count"
}

# the scripts of a plugin that must be able to run: what git marks executable in
# the plugin and its submodules, and its *.tmux files
count_scripts() {
  local repo total=0
  while IFS= read -r repo; do
    total=$((total + $(git -C "$repo" ls-files -s 2> /dev/null | grep -c '^100755')))
  done < <(repositories "$1")
  for file in "$1"/*.tmux; do
    [ -f "$file" ] && ! git -C "$1" ls-files -s -- "$(basename "$file")" 2> /dev/null | grep -q '^100755' && total=$((total + 1))
  done
  echo "$total"
}

# how many files of a plugin have the wrong permissions: scripts that cannot run,
# or files git does not mark executable that are
count_wrong_modes() {
  local repo total=0
  while IFS= read -r repo; do
    total=$((total + $(check_modes "$repo" "" "$([ "$repo" = "$1" ] && echo top)")))
  done < <(repositories "$1")
  echo $((total + $(check_tmux_files "$1")))
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
elif [ -f "$xdg/tmux.conf" ]; then
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
[ $dry_run -eq 1 ] && echo "Dry run: nothing is changed (git fetches what is new from GitHub)"

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

updated=(); current=(); skipped=(); failed=(); cannot_run=(); changes=0

# how many files and folders anyone can write to, as words
writable() { [ "$1" -eq 1 ] && echo "1 file or folder anyone could write to" || echo "$1 files and folders anyone could write to"; }

# the plugins folder and the one it is in (~/.tmux): whoever can write to them
# can replace a plugin with a folder of their own, which tmux then runs
check_folders() {
  local folder
  for folder in "$plugins" "$(dirname "$plugins")"; do
    [ "$folder" = "$HOME" ] || [ "$folder" = "$(dirname "$xdg")" ] && continue
    [ -n "$(find "$folder" -maxdepth 0 -perm -o+w 2> /dev/null)" ] || continue
    if [ $dry_run -eq 1 ]; then
      echo "${yellow}anyone can write to $folder: would remove that${reset}"; changes=$((changes + 1))
    else
      chmod go-w "$folder" && echo "${green}anyone could write to $folder: removed${reset}"
    fi
  done
}

# repairs and updates one plugin; the arrays above collect what happened to it
update_plugin() {
  local dir=$1 name meta path old_mode wrong open repo before behind ahead target resolved
  local links=() submodules=() edits=() repairs=()
  name=$(basename "$dir")
  if [ ! -d "$dir/.git" ]; then
    echo "${bold}$name${reset}  not a git repository: not updated"
    wrong=$(check_tmux_files "$dir")
    open=$(find "$dir" -perm -o+w ! -type l 2> /dev/null | wc -l)
    [ "$wrong" -gt 0 ] && repairs+=("$(plural "$wrong" "*.tmux file") not executable")
    [ "$open" -gt 0 ] && repairs+=("$(writable "$open")")
    if [ ${#repairs[@]} -gt 0 ] && [ $dry_run -eq 1 ]; then
      echo "  would repair: $(IFS=,; echo "${repairs[*]}" | sed 's/,/, /g')"; changes=$((changes + 1))
    elif [ ${#repairs[@]} -gt 0 ]; then
      check_tmux_files "$dir" fix > /dev/null
      chmod -R go-w "$dir"
      echo "  ${green}repaired: $(IFS=,; echo "${repairs[*]}" | sed 's/,/, /g')${reset}"
    fi
    skipped+=("$name"); return
  fi
  echo "${bold}$name${reset}  ($(git -C "$dir" remote get-url origin 2> /dev/null))"

  # what copying broke, told apart from edits: git's own list of what differs from
  # the last commit, ignoring file modes. A symlink (120000) that is gone or now a
  # copy of what it pointed to, and a submodule (160000) that is not there, are
  # damage; a symlink replaced by something else, a submodule at another commit
  # (your commits) and any other difference are edits, and stay as they are
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    old_mode=${meta:1:6}
    case "$old_mode" in
      120000)
        target=$(git -C "$dir" cat-file -p "HEAD:$path" 2> /dev/null)
        case "$target" in /*) resolved=$target ;; *) resolved=$(dirname "$dir/$path")/$target ;; esac
        if [ ! -e "$dir/$path" ] && [ ! -L "$dir/$path" ]; then
          links+=("$path")
        elif [ -f "$dir/$path" ] && [ ! -L "$dir/$path" ] && [ -f "$resolved" ] && cmp -s "$dir/$path" "$resolved"; then
          links+=("$path")
        elif [ -d "$dir/$path" ] && [ ! -L "$dir/$path" ] && [ -d "$resolved" ] && diff -rq "$dir/$path" "$resolved" > /dev/null 2>&1; then
          links+=("$path")
        else
          edits+=("$path")
        fi ;;
      160000)
        case "$(git -C "$dir" submodule status -- "$path" 2> /dev/null)" in
          +*) edits+=("$path (submodule at another commit)") ;;
          *)  submodules+=("$path") ;;
        esac ;;
      *) edits+=("$path") ;;
    esac
  done < <(git -C "$dir" -c core.fileMode=false diff --raw -z HEAD 2> /dev/null)
  wrong=$(count_wrong_modes "$dir")
  # .git too: a hook planted there would run when git updates the plugin
  open=$(find "$dir" -perm -o+w ! -type l 2> /dev/null | wc -l)

  [ "$wrong" -gt 0 ] && repairs+=("$(plural "$wrong" "file permission")")
  [ ${#links[@]} -gt 0 ] && repairs+=("$(plural ${#links[@]} symlink)")
  [ ${#submodules[@]} -gt 0 ] && repairs+=("$(plural ${#submodules[@]} submodule)")
  [ "$open" -gt 0 ] && repairs+=("$(writable "$open")")
  if [ ${#repairs[@]} -gt 0 ]; then
    if [ $dry_run -eq 1 ]; then
      echo "  would repair: $(IFS=,; echo "${repairs[*]}" | sed 's/,/, /g')"; changes=$((changes + 1))
    else
      # a symlink whose copy is a folder goes first, so that git can put the link back
      for path in "${links[@]}"; do
        [ -d "$dir/$path" ] && [ ! -L "$dir/$path" ] && rm -rf -- "${dir:?}/$path"
      done
      [ ${#links[@]} -gt 0 ] && git -C "$dir" checkout HEAD -- "${links[@]}"
      [ ${#submodules[@]} -gt 0 ] && git -C "$dir" submodule update --init --recursive --quiet -- "${submodules[@]}"
      # permissions as git has them (755 for scripts, 644 for the rest), in the
      # plugin and in its submodules, and every *.tmux file executable
      while IFS= read -r repo; do
        check_modes "$repo" fix "$([ "$repo" = "$dir" ] && echo top)" > /dev/null
      done < <(repositories "$dir")
      check_tmux_files "$dir" fix > /dev/null
      chmod -R go-w "$dir"
      echo "  ${green}repaired: $(IFS=,; echo "${repairs[*]}" | sed 's/,/, /g')${reset}"
    fi
  fi

  if [ ${#edits[@]} -gt 0 ]; then
    echo "  ${yellow}your own edits in $(plural ${#edits[@]} file) (${edits[*]:0:3}): not updated, so they are kept${reset}"
    echo "    git -C $dir diff shows them"
    skipped+=("$name"); return
  fi

  before=$(git -C "$dir" rev-parse --short HEAD)
  # --prune: a branch that was renamed or deleted on GitHub would otherwise look up to date
  if ! git -C "$dir" fetch --prune --quiet origin 2> /dev/null; then
    echo "  ${red}could not reach $(git -C "$dir" remote get-url origin)${reset}"
    failed+=("$name"); return
  fi
  if ! git -C "$dir" rev-parse --verify --quiet '@{u}' > /dev/null; then
    echo "  ${yellow}branch $(git -C "$dir" rev-parse --abbrev-ref HEAD) follows no branch on GitHub (renamed or deleted there?): skipped${reset}"
    skipped+=("$name"); return
  fi
  behind=$(git -C "$dir" rev-list --count 'HEAD..@{u}')
  ahead=$(git -C "$dir" rev-list --count '@{u}..HEAD')
  if [ "$ahead" -gt 0 ]; then
    echo "  ${yellow}$ahead commits of your own: not updated, so they are kept${reset}"
    skipped+=("$name"); return
  fi
  if [ "$behind" -eq 0 ]; then
    echo "  up to date ($before)"
    current+=("$name"); return
  fi
  if [ $dry_run -eq 1 ]; then
    echo "  would update: $behind new commits"; changes=$((changes + 1))
    git -C "$dir" log --format='    %cs %s' --max-count=5 'HEAD..@{u}'
    return
  fi
  if ! git -C "$dir" merge --ff-only --quiet '@{u}'; then
    echo "  ${red}the update failed; the plugin is as it was${reset}"
    failed+=("$name"); return
  fi
  if ! git -C "$dir" submodule update --init --recursive --quiet; then
    echo "  ${red}updated $before -> $(git -C "$dir" rev-parse --short HEAD), but its submodules could not be updated${reset}"
    failed+=("$name"); return
  fi
  echo "  ${green}updated $before -> $(git -C "$dir" rev-parse --short HEAD), $behind new commits${reset}"
  git -C "$dir" log --format='    %cs %s' --max-count=5 "$before..HEAD"
  updated+=("$name")
}

# every plugin repaired and updated; with dry_run=1, what would be done, counted in changes
process_plugins() {
  local dir wrong
  updated=(); current=(); skipped=(); failed=(); cannot_run=(); changes=0
  check_folders
  for dir in "$plugins"/*/; do
    dir=${dir%/}
    [ -d "$dir" ] || continue   # no plugins at all
    echo
    separator
    # a link to a plugin elsewhere (a working copy, say): repairs would change that
    if [ -L "$dir" ]; then
      echo "${bold}$(basename "$dir")${reset}  a link to $(readlink -f "$dir"): left alone"
      skipped+=("$(basename "$dir")"); continue
    fi
    update_plugin "$dir"
    # whatever happened above, every script of the plugin must be able to run
    if [ $dry_run -eq 0 ]; then
      wrong=$(count_wrong_modes "$dir")
      if [ "$wrong" -eq 0 ]; then
        echo "  can run: all $(plural "$(count_scripts "$dir")" script)"
      else
        echo "  ${red}$(plural "$wrong" file) still with the wrong permissions${reset}"
        cannot_run+=("$(basename "$dir")")
      fi
    fi
  done
}

if [ $dry_run -eq 1 ]; then
  process_plugins
else
  # first what would be done, then the question, then that
  dry_run=1; process_plugins; dry_run=0
  if [ $changes -gt 0 ]; then
    echo
    if [ $yes -eq 0 ]; then
      if [ ! -t 0 ]; then
        echo "Not a terminal, so nothing can be asked: add --yes to change them"; exit 1
      fi
      yes_no "Repair and update the plugins as above?" || { echo "Nothing was changed"; exit 0; }
    fi
    echo
    echo "${bold}Repairing and updating${reset}"
    process_plugins
  fi
fi

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
[ ${#cannot_run[@]} -gt 0 ] && echo "${red}Files with the wrong permissions left in: ${cannot_run[*]}${reset}"
[ ${#missing[@]} -gt 0 ] && echo "${yellow}In your configuration but not installed: ${missing[*]} ($plugins/tpm/bin/install_plugins installs them)${reset}"
if [ "$(config_sum)" = "$config_before" ]; then
  [ ${#configs[@]} -gt 0 ] && echo "${green}Unchanged: ${configs[*]}${reset}"
else
  echo "${red}A configuration file changed while this ran: ${configs[*]}${reset}"
fi
if [ $dry_run -eq 0 ] && [ ${#updated[@]} -gt 0 ] && tmux info > /dev/null 2>&1; then
  echo "tmux is running: tmux source-file ${configs[0]:-~/.tmux.conf} loads the updated plugins"
fi
[ ${#failed[@]} -eq 0 ] && [ ${#cannot_run[@]} -eq 0 ]
