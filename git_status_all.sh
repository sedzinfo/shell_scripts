#!/usr/bin/env bash
# One line per git repository in ~/GitHub (or the folder given): what is not yet
# on GitHub. Nothing is changed; the remote branches are fetched first so the
# counts are up to date (add --no-fetch to skip that, e.g. without internet).
#   git_status_all.sh [folder] [--no-fetch]

root="$HOME/GitHub"; fetch=1
for arg in "$@"; do
  case "$arg" in
    --no-fetch) fetch=0 ;;
    -h|--help)  sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    *)          root="$arg" ;;
  esac
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

shopt -s dotglob
for dir in "$root"/*/; do
  [ -e "$dir/.git" ] || continue
  name=$(basename "$dir")
  # the branch, also in a repository without commits yet
  branch=$(git -C "$dir" symbolic-ref -q --short HEAD) || branch=HEAD

  notes=()
  if [ $fetch -eq 1 ] && ! git -C "$dir" fetch -q 2> /dev/null; then
    notes+=("${yellow}not fetched${reset}")
  fi
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
  # the other branches with commits that are on no branch of GitHub, and the stashes
  others=0
  while IFS= read -r ref; do
    [ "$ref" = "refs/heads/$branch" ] && continue
    [ "$(git -C "$dir" rev-list --count "$ref" --not --remotes)" -gt 0 ] && others=$((others + 1))
  done < <(git -C "$dir" for-each-ref --format='%(refname)' refs/heads)
  [ $others -eq 1 ] && notes+=("${red}1 other branch not on GitHub${reset}")
  [ $others -gt 1 ] && notes+=("${red}$others other branches not on GitHub${reset}")
  stashes=$(git -C "$dir" stash list | wc -l)
  [ "$stashes" -gt 0 ] && notes+=("${red}$stashes stashed${reset}")

  if [ ${#notes[@]} -eq 0 ]; then
    printf '%-32s %-12s %s\n' "$name" "$branch" "${green}clean${reset}"
  else
    attention=$((attention + 1))
    printf '%-32s %-12s %s\n' "$name" "$branch" "$(IFS=,; echo "${notes[*]}" | sed 's/,/, /g')"
  fi
done

echo
[ $attention -eq 0 ] && echo "${green}Everything is on GitHub${reset}" || echo "$attention repositories need attention"
