#!/usr/bin/env bash
# Pulls every git repository in ~/GitHub.
# --ff-only: a repository is only moved forward; if it has diverged from GitHub
# it is skipped (and listed at the end) instead of being merged or rebased.

root="${1:-$HOME/GitHub}"

# ask for the folder until one that exists is given (Tab completes paths, ~ works)
while [ ! -d "$root" ]; do
  echo "Folder not found: $root"
  read -e -r -p "Folder with the repositories (empty to quit): " root || exit 1
  [ -z "$root" ] && exit 1
  root="${root/#\~/$HOME}"
done
ok=(); failed=()

for dir in "$root"/*/; do
  [ -d "$dir/.git" ] || continue
  name=$(basename "$dir")
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
  echo "=== $name ($branch)"

  if [ "$branch" = "HEAD" ]; then
    echo "    detached HEAD, skipped"
    failed+=("$name: detached HEAD")
    continue
  fi

  if git -C "$dir" pull --ff-only; then
    ok+=("$name")
  elif git -C "$dir" rev-parse --verify -q "@{u}" > /dev/null; then
    # show what a reset would throw away, then ask (anything but y/yes means no)
    echo "    --- local commits that are not on GitHub:"
    git -C "$dir" log --oneline "@{u}..HEAD" | sed 's/^/    /'
    echo "    --- uncommitted changes:"
    git -C "$dir" status -s | sed 's/^/    /'
    read -r -p "    git reset --hard $(git -C "$dir" rev-parse --abbrev-ref "@{u}")? This DELETES the above [y/N]: " answer
    if [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
      git -C "$dir" reset --hard "@{u}" && ok+=("$name (reset --hard)") || failed+=("$name")
    else
      failed+=("$name")
    fi
  else
    failed+=("$name: no upstream branch")
  fi
  echo
done

echo "==============================="
echo "Pulled: ${#ok[@]}"
if [ ${#failed[@]} -gt 0 ]; then
  echo "Not pulled (${#failed[@]}):"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
