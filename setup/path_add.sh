#!/usr/bin/env bash
# Adds the shell_scripts folder (the one above this setup folder) to your PATH, so that its
# scripts run by name from any folder: git_status_all.sh instead of
# ~/GitHub/shell_scripts/git_status_all.sh. The setup scripts, which are run once, stay off
# the PATH. It adds one line to ~/.bashrc, which every new terminal reads (and to ~/.zshrc,
# if there is one):
#   export PATH="$HOME/GitHub/shell_scripts:$PATH"
# Running it again changes nothing. A script cannot change the PATH of the terminal it was
# started from: open a new one, or run  source ~/.bashrc  in it. To undo it, delete that
# line from ~/.bashrc.
#   setup/path_add.sh

case "${1:-}" in
  '') ;;
  -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
  *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
esac

# the shell_scripts folder, above this one; also as a line may write it: with $HOME, or ~
folder=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
written=$folder; tilde=$folder
if [[ "$folder" == "$HOME"/* ]]; then
  written="\$HOME${folder#"$HOME"}"; tilde="~${folder#"$HOME"}"
fi
line="export PATH=\"$written:\$PATH\""

files=("$HOME/.bashrc")
[ -f "$HOME/.zshrc" ] && files+=("$HOME/.zshrc")
for file in "${files[@]}"; do
  # a line that sets the PATH with this folder, not in a comment
  if [ -f "$file" ] && grep 'PATH' "$file" | grep -v '^[[:space:]]*#' | grep -qF -e "$folder" -e "$written" -e "$tilde"; then
    echo "Already in $file"
  else
    printf '\n# the scripts of shell_scripts, by name from any folder (added by path_add.sh)\n%s\n' "$line" >> "$file"
    echo "Added to $file:"
    echo "  $line"
  fi
done

case ":$PATH:" in
  *":$folder:"*) echo "This terminal has it already" ;;
  *) echo "Open a new terminal, or run in this one: source ~/.bashrc" ;;
esac
