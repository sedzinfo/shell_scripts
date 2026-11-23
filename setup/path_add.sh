#!/usr/bin/env bash
# Adds the shell_scripts folder (the one above this setup folder) and its monitor folder to
# your PATH, so that their scripts run by name from any folder: git_status_all.sh instead of
# ~/GitHub/shell_scripts/git_status_all.sh, and hwrt.sh instead of
# ~/GitHub/shell_scripts/monitor/hwrt.sh. The setup scripts, which are run once, stay off
# the PATH. It adds one line to ~/.bashrc, which every new terminal reads (and to ~/.zshrc,
# if there is one):
#   export PATH="$HOME/GitHub/shell_scripts:$HOME/GitHub/shell_scripts/monitor:$PATH"
# Running it again changes nothing; after an older run that added only the shell_scripts
# folder, it adds a line with the monitor folder alone. A script cannot change the PATH of
# the terminal it was started from: open a new one, or run  source ~/.bashrc  in it. To
# undo it, delete the lines it added from ~/.bashrc.
#   setup/path_add.sh

case "${1:-}" in
  '') ;;
  -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
  *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
esac

# the shell_scripts folder, above this one, and its folders of scripts to run by name;
# setup/ (run once) and lib/ (loaded by the scripts, never run) stay off the PATH
top=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
folders=("$top")
[ -d "$top/monitor" ] && folders+=("$top/monitor")

# a folder as the line writes it: with $HOME, when it is in the home folder
written() {
  if [[ "$1" == "$HOME"/* ]]; then echo "\$HOME${1#"$HOME"}"; else echo "$1"; fi
}

# whether a line of the file, not a comment, sets the PATH with the folder: written as it
# is, with $HOME or with ~, and followed by : or " or the end of the line, so that the
# shell_scripts folder is not taken for its monitor folder
listed_in() {
  local file=$1 folder=$2 line form comment='^[[:space:]]*#'
  local -a forms=("$folder" "$(written "$folder")")
  [[ "$folder" == "$HOME"/* ]] && forms+=("~${folder#"$HOME"}")
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" == *PATH* && ! "$line" =~ $comment ]] || continue
    for form in "${forms[@]}"; do
      [[ "$line" == *"$form:"* || "$line" == *"$form\""* || "$line" == *"$form" ]] && return 0
    done
  done < "$file"
  return 1
}

files=("$HOME/.bashrc")
[ -f "$HOME/.zshrc" ] && files+=("$HOME/.zshrc")
for file in "${files[@]}"; do
  # the folders this file does not put on the PATH yet
  missing=()
  for folder in "${folders[@]}"; do
    listed_in "$file" "$folder" || missing+=("$(written "$folder")")
  done
  if [ ${#missing[@]} -eq 0 ]; then
    echo "Already in $file"
  else
    line="export PATH=\"$(IFS=:; echo "${missing[*]}"):\$PATH\""
    printf '\n# the scripts of shell_scripts, by name from any folder (added by path_add.sh)\n%s\n' "$line" >> "$file"
    echo "Added to $file:"
    echo "  $line"
  fi
done

for folder in "${folders[@]}"; do
  case ":$PATH:" in
    *":$folder:"*) ;;
    *) echo "Open a new terminal, or run in this one: source ~/.bashrc"; exit 0 ;;
  esac
done
echo "This terminal has it already"
