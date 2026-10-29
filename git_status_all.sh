#!/usr/bin/env bash
# One line per git repository in ~/GitHub (or the folder given): what is not yet
# on GitHub. Nothing is changed; the remote branches are fetched first so the
# counts are up to date (add --no-fetch to skip that, e.g. without internet).
#   git_status_all.sh [folder] [--no-fetch]

root="$HOME/GitHub"; fetch=1
for arg in "$@"; do
  [ "$arg" = "--no-fetch" ] && fetch=0 || root="$arg"
done

# ask for the folder until one that exists is given (Tab completes paths, ~ works)
while [ ! -d "$root" ]; do
  echo "Folder not found: $root"
  read -e -r -p "Folder with the repositories (empty to quit): " root || exit 1
  [ -z "$root" ] && exit 1
  root="${root/#\~/$HOME}"
done

red=$'\e[31m'; yellow=$'\e[33m'; green=$'\e[32m'; reset=$'\e[0m'
attention=0

for dir in "$root"/*/; do
  [ -d "$dir/.git" ] || continue
  name=$(basename "$dir")
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
  [ $fetch -eq 1 ] && git -C "$dir" fetch -q 2> /dev/null

  notes=()
  changed=$(git -C "$dir" status --porcelain | wc -l)
  [ "$changed" -gt 0 ] && notes+=("${red}$changed uncommitted${reset}")
  if git -C "$dir" rev-parse --verify -q "@{u}" > /dev/null; then
    ahead=$(git -C "$dir" rev-list --count "@{u}..HEAD")
    behind=$(git -C "$dir" rev-list --count "HEAD..@{u}")
    [ "$ahead" -gt 0 ] && notes+=("${red}$ahead to push${reset}")
    [ "$behind" -gt 0 ] && notes+=("${yellow}$behind to pull${reset}")
  elif [ "$branch" = "HEAD" ]; then
    notes+=("${yellow}detached HEAD${reset}")
  else
    notes+=("${yellow}no upstream branch${reset}")
  fi

  if [ ${#notes[@]} -eq 0 ]; then
    printf '%-32s %-12s %s\n' "$name" "$branch" "${green}clean${reset}"
  else
    attention=$((attention + 1))
    printf '%-32s %-12s %s\n' "$name" "$branch" "$(IFS=,; echo "${notes[*]}" | sed 's/,/, /g')"
  fi
done

echo
[ $attention -eq 0 ] && echo "${green}Everything is on GitHub${reset}" || echo "$attention repositories need attention"
