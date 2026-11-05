#!/usr/bin/env bash
# GitHub Actions of every repository of one or more GitHub users or organisations:
# the latest run of each workflow, problems first (failed, cancelled, timed out),
# then the ones still running, then the ones that passed, and at the end the list
# of repositories with a problem. Archived repositories are left out.
#   git_actions_all.sh                      the repositories of sedzinfo
#   git_actions_all.sh sedzinfo evalioncode  these users and organisations
#   git_actions_all.sh --problems           only the problems and the runs still running
# Private repositories (and an organisation's) are included only with a token:
#   GITHUB_TOKEN=ghp_... git_actions_all.sh
# Without GITHUB_TOKEN, the token of the GitHub CLI (gh auth token) is used when
# it is logged in. Without any token GitHub allows 60 requests an hour, one per
# repository. Exits 1 when a latest run has a problem, so it can run from cron.
# Needs curl and jq.

problems_only=false
owners=()
for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    --problems) problems_only=true ;;
    -*) echo "Unknown option: $arg (see --help)"; exit 2 ;;
    *) owners+=("$arg") ;;
  esac
done
[ ${#owners[@]} -eq 0 ] && owners=(sedzinfo)

# offers to install the programs this script needs, when they are missing.
# Each argument is program:package:what it is for. It only asks (never installs
# by itself), only once, and only where apt exists; with no, the script goes on
# and shows what it can.
check_packages() {
  local entry program package purpose answer packages=() lines=()
  for entry in "$@"; do
    IFS=: read -r program package purpose <<< "$entry"
    if ! command -v "$program" > /dev/null; then
      packages+=("$package")
      lines+=("$(printf '%-14s %-26s package %s' "$program" "($purpose)" "$package")")
    fi
  done
  [ ${#packages[@]} -eq 0 ] && return 0
  echo "Missing:"
  printf '  %s\n' "${lines[@]}"
  if command -v apt-get > /dev/null && [ -t 0 ]; then
    read -r -p "Install them now with sudo apt install ${packages[*]}? [y/N]: " answer
    if [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
      sudo apt install -y "${packages[@]}"
    fi
  else
    echo "Install them with the package manager of this system: ${packages[*]}"
  fi
}

# curl and jq are needed, so without them it stops
check_packages 'curl:curl:asks GitHub for the runs' 'jq:jq:reads the answers'
command -v curl > /dev/null && command -v jq > /dev/null || exit 1

# the token: GITHUB_TOKEN, else the GitHub CLI's when it is logged in
token="${GITHUB_TOKEN:-}"
if [ -z "$token" ] && command -v gh > /dev/null; then
  token=$(gh auth token 2> /dev/null)
fi
auth=(-H "Accept: application/vnd.github+json")
me=""
if [ -n "$token" ]; then
  auth+=(-H "Authorization: Bearer $token")
  me=$(curl -fsS "${auth[@]}" https://api.github.com/user | jq -r .login) ||
    { echo "GitHub did not accept the token"; exit 1; }
else
  echo "No token (GITHUB_TOKEN or gh auth login): public repositories only, 60 requests an hour"
fi

# every page of a list from the API, as one JSON array
get_all() {
  local url="$1" page=1 response all="[]" sep="?"
  [[ "$url" == *\?* ]] && sep="&"
  while :; do
    response=$(curl -fsS "${auth[@]}" "$url${sep}per_page=100&page=$page") || return 1
    [ "$(jq 'length' <<< "$response")" -eq 0 ] && break
    all=$(jq -s 'add' <<< "$all$response")
    [ "$(jq 'length' <<< "$response")" -lt 100 ] && break
    page=$((page + 1))
  done
  echo "$all"
}

# the repositories of each owner: with a token, the private ones too (the owner's
# own token, or a member's for an organisation)
repos=()
for owner in "${owners[@]}"; do
  kind=$(curl -fsS "${auth[@]}" "https://api.github.com/users/$owner" | jq -r .type) ||
    { echo "GitHub user or organisation not found: $owner"; exit 1; }
  if [ "$kind" = "Organization" ]; then
    url="https://api.github.com/orgs/$owner/repos?type=all"
  elif [ -n "$me" ] && [ "${me,,}" = "${owner,,}" ]; then
    url="https://api.github.com/user/repos?affiliation=owner"
  else
    url="https://api.github.com/users/$owner/repos?type=owner"
  fi
  list=$(get_all "$url") || { echo "Could not list the repositories of $owner"; exit 1; }
  mapfile -t batch < <(jq -r '.[] | select(.archived | not) | .full_name' <<< "$list" | sort -f)
  repos+=("${batch[@]}")
done
echo "Checking ${#repos[@]} repositories of ${owners[*]}"
echo

# the latest run of each workflow of each repository (the last 100 runs are
# enough to find every active workflow), told apart by the workflow file, since
# Dependabot and Copilot give every run a name of its own; one tab-separated
# line per workflow:
# rank (1 problem, 2 running, 3 passed), result, repository, workflow, branch,
# date, link
lines=()
no_actions=()
unreadable=()
for repo in "${repos[@]}"; do
  response=$(curl -fsS "${auth[@]}" "https://api.github.com/repos/$repo/actions/runs?per_page=100") ||
    { unreadable+=("$repo"); continue; }
  mapfile -t runs < <(jq -r --arg repo "$repo" '
    .workflow_runs | group_by(.path)[] | max_by(.created_at)
    | (.conclusion // .status) as $result
    | (if $result == "success" or $result == "skipped" or $result == "neutral" then 3
       elif .conclusion == null then 2 else 1 end) as $rank
    | [$rank, $result, $repo, .name[:30], .head_branch[:16], .created_at[:10], .html_url] | @tsv' <<< "$response")
  if [ ${#runs[@]} -eq 0 ]; then
    no_actions+=("$repo")
  else
    lines+=("${runs[@]}")
  fi
done

# problems first, then running, then passed; inside each, by repository
mapfile -t lines < <(printf '%s\n' "${lines[@]}" | grep -v '^$' | sort -t$'\t' -k1,1n -k3,3f -k4,4f)
failed_repos=()
for line in "${lines[@]}"; do
  IFS=$'\t' read -r rank result repo workflow branch date link <<< "$line"
  [ "$rank" = 1 ] && failed_repos+=("$repo")
  $problems_only && [ "$rank" = 3 ] && continue
  printf '%-12s %-40s %-30s %-16s %s  %s\n' "$result" "$repo" "$workflow" "$branch" "$date" "$link"
done
[ ${#lines[@]} -eq 0 ] && echo "No workflow runs found"

mapfile -t failed_repos < <(printf '%s\n' "${failed_repos[@]}" | grep -v '^$' | sort -fu)
echo
echo "==============================="
echo "Repositories with Actions: $(( ${#repos[@]} - ${#no_actions[@]} - ${#unreadable[@]} )), without: ${#no_actions[@]}"
if [ ${#unreadable[@]} -gt 0 ]; then
  echo "Could not read the runs of (${#unreadable[@]}):"
  printf '  %s\n' "${unreadable[@]}"
fi
if [ ${#failed_repos[@]} -gt 0 ]; then
  echo "With a problem (${#failed_repos[@]}):"
  printf '  %s\n' "${failed_repos[@]}"
  exit 1
fi
echo "No problems"
