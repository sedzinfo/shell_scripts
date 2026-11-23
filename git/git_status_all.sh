#!/usr/bin/env bash
# One line per git repository in ~/GitHub (or the folder given): what is not yet
# on GitHub. Nothing is changed; the remote branches are fetched first so the
# counts are up to date (add --no-fetch to skip that, e.g. without internet).
#   git_status_all.sh [folder] [--no-fetch]

# the functions that several scripts share
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers.sh" || exit 1

root="$HOME/GitHub"; fetch=1
for arg in "$@"; do
  case "$arg" in
    --no-fetch) fetch=0 ;;
    -h|--help)  sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    *)          root="$arg" ;;
  esac
done

ask_folder

attention=0

shopt -s dotglob
# the repositories; unless --no-fetch, all fetched first, 8 at a time
repos=()
for dir in "$root"/*/; do [ -e "$dir/.git" ] && repos+=("$dir"); done
[ $fetch -eq 1 ] && fetch_all "${repos[@]}"

for dir in "${repos[@]}"; do
  name=$(basename "$dir")
  # the branch, also in a repository without commits yet
  branch=$(git -C "$dir" symbolic-ref -q --short HEAD) || branch=HEAD

  notes=()
  if [ $fetch -eq 1 ]; then
    fetch_result "$dir"
    [ "$fetched" -eq 1 ] || notes+=("${yellow}not fetched${reset}")
  fi
  changed=$(git -C "$dir" status --porcelain | wc -l)
  if [ "$changed" -gt 0 ]; then
    # the date of the uncommitted file changed last: the files inside new folders too,
    # not deleted files (they have no date), and the new name of a renamed file
    latest=0
    while IFS= read -r -d '' entry; do
      state=${entry:0:2}
      path=${entry:3}
      [[ $state == R* || $state == C* ]] && IFS= read -r -d '' _ # the old name of a rename
      [ -e "$dir/$path" ] || continue
      t=$(stat -c %Y "$dir/$path" 2> /dev/null || stat -f %m "$dir/$path" 2> /dev/null) || continue
      [ "$t" -gt "$latest" ] && latest=$t
    done < <(git -C "$dir" status --porcelain -z --untracked-files=all)
    when=""
    if [ "$latest" -gt 0 ]; then
      when=$(date -d "@$latest" '+%d/%m/%Y %H:%M' 2> /dev/null || date -r "$latest" '+%d/%m/%Y %H:%M')
      when=" (latest $when)"
    fi
    notes+=("${red}$changed uncommitted${reset}$when")
  fi
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
