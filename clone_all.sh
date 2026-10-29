#!/usr/bin/env bash
# Clones every repository of a GitHub user into ~/GitHub (or the folder given).
# Repositories that are already there are skipped, so it is safe to run again.
#   clone_all.sh [folder] [user]
# Private repositories are included only if a token is set:
#   GITHUB_TOKEN=ghp_... clone_all.sh
# Needs curl and jq.

root="${1:-$HOME/GitHub}"
user="${2:-sedzinfo}"

# ask for the folder until one that exists is given (Tab completes paths, ~ works)
while [ ! -d "$root" ]; do
  echo "Folder not found: $root"
  read -e -r -p "Folder to clone into (empty to quit): " root || exit 1
  [ -z "$root" ] && exit 1
  root="${root/#\~/$HOME}"
done

# the list of repositories, 100 per page
if [ -n "$GITHUB_TOKEN" ]; then
  url="https://api.github.com/user/repos?affiliation=owner"   # public and private
  auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
else
  url="https://api.github.com/users/$user/repos?type=owner"   # public only
  auth=()
fi

repos=()
page=1
while :; do
  response=$(curl -fsS "${auth[@]}" "$url&per_page=100&page=$page") || { echo "Could not reach GitHub"; exit 1; }
  mapfile -t batch < <(jq -r '.[] | "\(.name) \(.ssh_url)"' <<< "$response")
  [ ${#batch[@]} -eq 0 ] && break
  repos+=("${batch[@]}")
  page=$((page + 1))
done
echo "Found ${#repos[@]} repositories of $user"
echo

cloned=(); skipped=(); failed=()

for line in "${repos[@]}"; do
  name="${line%% *}"
  ssh_url="${line#* }"
  if [ -e "$root/$name" ]; then
    skipped+=("$name")
    continue
  fi
  echo "=== $name"
  if git clone "$ssh_url" "$root/$name"; then
    cloned+=("$name")
  else
    failed+=("$name")
  fi
  echo
done

echo "==============================="
echo "Cloned: ${#cloned[@]}"
[ ${#cloned[@]} -gt 0 ] && printf '  %s\n' "${cloned[@]}"
echo "Already there, skipped: ${#skipped[@]}"
if [ ${#failed[@]} -gt 0 ]; then
  echo "Failed (${#failed[@]}):"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
