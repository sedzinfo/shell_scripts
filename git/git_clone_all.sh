#!/usr/bin/env bash
# Clones every repository of a GitHub user into ~/GitHub (or the folder given).
# Repositories that are already there are skipped, so it is safe to run again.
#   git_clone_all.sh [folder] [user]
# Private repositories are included only with a token of that user:
#   GITHUB_TOKEN=ghp_... git_clone_all.sh
# Without GITHUB_TOKEN, the token of the GitHub CLI (gh auth token) is used when
# it is logged in; with no token at all it says that only public ones are listed.
# Needs curl and jq.

# the functions that several scripts share
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/../lib/helpers.sh" || exit 1

case "${1:-}" in
  -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
esac
root="${1:-$HOME/GitHub}"
user="${2:-sedzinfo}"

ask_folder "Folder to clone into"

# curl and jq are needed, so without them it stops
check_packages 'curl:curl:asks GitHub for the list' 'jq:jq:reads that list'
command -v curl > /dev/null && command -v jq > /dev/null || exit 1

# the list of repositories, 100 per page: with a token of that user, public and
# private; otherwise public only (a token of someone else still raises the limit
# of requests)
url="https://api.github.com/users/$user/repos?type=owner"; config=()
token="${GITHUB_TOKEN:-}"
if [ -z "$token" ] && command -v gh > /dev/null; then
  token=$(gh auth token 2> /dev/null)
fi
# curl gets the token on its standard input, as a header, so that it is not in the list
# of processes, which others can see
github_api() { printf '%s\n' "${config[@]}" | curl -fsS --config - "$@"; }
scope="public only: no token (GITHUB_TOKEN=ghp_... or gh auth login for private ones)"
if [ -n "$token" ]; then
  config=("header = \"Authorization: Bearer $token\"")
  owner=$(github_api https://api.github.com/user | jq -r .login) ||
    { echo "GitHub did not accept the token"; exit 1; }
  if [ "${owner,,}" = "${user,,}" ]; then
    url="https://api.github.com/user/repos?affiliation=owner"
    scope="public and private"
  else
    scope="public only: the token is $owner's, not $user's"
  fi
fi

repos=()
page=1
while :; do
  response=$(github_api "$url&per_page=100&page=$page") || { echo "Could not reach GitHub"; exit 1; }
  mapfile -t batch < <(jq -r '.[] | "\(.name) \(.ssh_url)"' <<< "$response")
  [ ${#batch[@]} -eq 0 ] && break
  repos+=("${batch[@]}")
  page=$((page + 1))
done
echo "Found ${#repos[@]} repositories of $user ($scope)"
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
