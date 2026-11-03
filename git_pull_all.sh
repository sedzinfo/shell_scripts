#!/usr/bin/env bash
# Pulls every git repository in ~/GitHub (or the folder given).
# --ff-only: a repository is only moved forward; if it has diverged from GitHub,
# it shows what a reset to GitHub's version would delete and asks; otherwise it
# is skipped (and listed at the end), never merged or rebased.
#   git_pull_all.sh [folder]

case "${1:-}" in
  -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
esac
root="${1:-$HOME/GitHub}"

# ask for the folder until one that exists is given (Tab completes paths, ~ works)
while [ ! -d "$root" ]; do
  echo "Folder not found: $root"
  read -e -r -p "Folder with the repositories (empty to quit): " root || exit 1
  [ -z "$root" ] && exit 1
  root="${root/#\~/$HOME}"
done
pulled=(); current=0; failed=()

shopt -s dotglob
for dir in "$root"/*/; do
  [ -e "$dir/.git" ] || continue
  name=$(basename "$dir")
  # the branch, also in a repository without commits yet
  branch=$(git -C "$dir" symbolic-ref -q --short HEAD) || branch=HEAD
  echo "=== $name ($branch)"

  if [ "$branch" = "HEAD" ]; then
    echo "    detached HEAD, skipped"
    failed+=("$name: detached HEAD")
    continue
  fi
  if [ -z "$(git -C "$dir" config "branch.$branch.merge")" ]; then
    echo "    no upstream branch, skipped"
    failed+=("$name: no upstream branch")
    continue
  fi
  # fetch first, so that a reset is offered only when GitHub could be reached
  if ! git -C "$dir" fetch -q; then
    failed+=("$name: fetch failed (no connection?)")
    echo; continue
  fi
  if ! git -C "$dir" rev-parse -q --verify "@{u}" > /dev/null; then
    echo "    its branch is not on GitHub (deleted there?), skipped"
    failed+=("$name: its branch is not on GitHub")
    continue
  fi

  before=$(git -C "$dir" rev-parse -q --verify HEAD)
  if git -C "$dir" -c advice.diverging=false merge --ff-only "@{u}"; then
    if [ "$(git -C "$dir" rev-parse -q --verify HEAD)" = "$before" ]; then
      current=$((current + 1))
    else
      pulled+=("$name")
    fi
  else
    # show what a reset would throw away, then ask (anything but y/yes means no)
    echo "    --- local commits that are not on GitHub:"
    git -C "$dir" log --oneline "@{u}..HEAD" | sed 's/^/    /'
    echo "    --- uncommitted changes:"
    git -C "$dir" status -s --untracked-files=no | sed 's/^/    /'
    # files git does not track here that GitHub's version has: the reset replaces
    # them with GitHub's. The other untracked files are kept
    replaced=$(comm -13 <(git -C "$dir" -c core.quotePath=false ls-tree -r --name-only HEAD 2> /dev/null | sort) \
      <(git -C "$dir" -c core.quotePath=false ls-tree -r --name-only "@{u}" | sort) |
      while IFS= read -r file; do [ -e "$dir/$file" ] && printf '%s\n' "$file"; done)
    if [ -n "$replaced" ]; then
      echo "    --- files git does not track here, which the GitHub version replaces:"
      sed 's/^/    /' <<< "$replaced"
    fi
    read -r -p "    git reset --hard $(git -C "$dir" rev-parse --abbrev-ref "@{u}")? This DELETES the above [y/N]: " answer
    if [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
      git -C "$dir" reset --hard "@{u}" && pulled+=("$name (reset --hard)") || failed+=("$name")
    else
      failed+=("$name")
    fi
  fi
  echo
done

echo "==============================="
echo "Pulled: ${#pulled[@]}"
[ ${#pulled[@]} -gt 0 ] && printf '  %s\n' "${pulled[@]}"
echo "Already up to date: $current"
if [ ${#failed[@]} -gt 0 ]; then
  echo "Not pulled (${#failed[@]}):"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
