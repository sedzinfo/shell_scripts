#!/usr/bin/env bash
# Did the latest build and check of every R package on GitHub Actions go fine? For each R
# package in ~/GitHub (or the folder given), the latest run of the workflows of its
# repository that build or check it, told apart by what they run:
#   build   R CMD build: the source tarball (build-tarball.yml)
#   check   R CMD check, with the tests (R-CMD-check.yaml, r.yml)
# Only the runs of the default branch (main) count, not those of other branches or of pull
# requests. One line per package, with the result of each and when it started:
#   success                          it went fine
#   failure, cancelled, timed_out    shown with the job and step that failed, and the link
#   in_progress, queued              still running: run this again in a few minutes
#   no runs on main                  never ran there (its on: may name another branch)
#   no workflow                      the repository has none that builds, or checks
#   r_actions_all.sh [folder] [package ...]   every package, or only the ones named
# A package is a folder with a DESCRIPTION: a repository, or a folder in one (rwf/rwf). The
# folder is given as a path (~/GitHub, ., ../work): a plain word is a package.
# The token is GITHUB_TOKEN, else the GitHub CLI's when it is logged in (gh auth login).
# Without one only public repositories are seen, and GitHub allows 60 requests an hour,
# about 3 per package. Nothing is changed. The exit code is 1 when a latest run failed or
# was cancelled, a workflow has no runs on main, or GitHub could not be asked. Needs curl
# and jq.

root="$HOME/GitHub"; only=(); root_given=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    -*)        echo "Unknown option: $arg (see --help)"; exit 1 ;;
    *)
      # a path is the folder (a package's name may also be a folder here)
      if [ $root_given -eq 0 ] && [[ "$arg" == */* || "$arg" == '~' || "$arg" == . || "$arg" == .. ]]; then
        root="${arg/#\~/$HOME}"; root_given=1
      else
        only+=("$arg")
      fi ;;
  esac
done

# ask for the folder until one that exists is given (Tab completes paths, ~ works)
while [ ! -d "$root" ]; do
  echo "Folder not found: $root"
  read -e -r -p "Folder with the repositories (empty to quit): " root || exit 1
  [ -z "$root" ] && exit 1
  root="${root/#\~/$HOME}"
done
root=$(cd "$root" && pwd)

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

# git, curl and jq are needed, so without them it stops
check_packages 'git:git:finds the repositories' 'curl:curl:asks GitHub for the runs' 'jq:jq:reads the answers'
for program in git curl jq; do command -v "$program" > /dev/null || exit 1; done

# colours on a terminal, not in the mail of cron
if [ -t 1 ]; then
  red=$'\e[31m'; yellow=$'\e[33m'; green=$'\e[32m'; grey=$'\e[90m'; reset=$'\e[0m'
else
  red=''; yellow=''; green=''; grey=''; reset=''
fi

# the packages: their folders, names and the labels of the table (the folder, and the
# package's name when it is not the folder's)
dirs=(); names=(); labels=(); width=7
while IFS= read -r description; do
  dir=$(dirname "$description")
  name=$(awk -F': *' '$1 == "Package" { sub(/[ \t\r]+$/, "", $2); print $2; exit }' "$description")
  [ -n "$name" ] || continue
  if [ ${#only[@]} -gt 0 ]; then
    wanted=0
    for want in "${only[@]}"; do
      [ "$want" = "$name" ] || [ "$want" = "$(basename "$dir")" ] && wanted=1
    done
    [ $wanted -eq 1 ] || continue
  fi
  label="${dir#"$root"/}"
  [ "$dir" = "$root" ] && label=$(basename "$dir")
  [ "$(basename "$dir")" = "$name" ] || label="$label ($name)"
  dirs+=("$dir"); names+=("$name"); labels+=("$label")
  [ ${#label} -gt $width ] && width=${#label}
done < <(find "$root" -maxdepth 3 \
           \( -name .git -o -name '*.Rcheck' -o -name renv -o -name venv -o -name .venv -o -name node_modules \) -prune \
           -o -name DESCRIPTION -type f -print | sort)
if [ ${#dirs[@]} -eq 0 ]; then
  echo "No R packages${only[*]:+ named ${only[*]}} in $root"; exit 1
fi

# the token: GITHUB_TOKEN, else the GitHub CLI's when it is logged in. curl gets it on its
# standard input, so that it is not in the list of processes, which others can see
token="${GITHUB_TOKEN:-}"
if [ -z "$token" ] && command -v gh > /dev/null; then
  token=$(gh auth token 2> /dev/null)
fi
config=('header = "Accept: application/vnd.github+json"' 'header = "X-GitHub-Api-Version: 2022-11-28"')
[ -n "$token" ] && config+=("header = \"Authorization: Bearer $token\"")

# asks GitHub for https://api.github.com/$1 and puts the answer in $answer. Returns 0; 4 when
# GitHub has no such thing; or 1, with the reason in $api_error. After a token GitHub
# refuses, or its limit of requests, the questions that follow are not asked
api_error=""; api_stop=0
api() {
  local code
  answer=""
  [ $api_stop -eq 1 ] && return 1
  answer=$(printf '%s\n' "${config[@]}" |
           curl -sL --retry 2 --max-time 30 --config - -w '\n%{http_code}' "https://api.github.com/$1") ||
    { api_error="GitHub could not be reached"; answer=""; return 1; }
  code=${answer##*$'\n'}; answer=${answer%$'\n'*}
  case "$code" in
    200) return 0 ;;
    404) answer=""; return 4 ;;
    401) api_error="GitHub did not accept the token (GITHUB_TOKEN, or the GitHub CLI's: gh auth login)"; api_stop=1 ;;
    403|429)
      if [[ "$answer" == *"rate limit"* ]]; then
        api_error="GitHub's limit of requests an hour was reached"
        [ -z "$token" ] && api_error+=" (60 without a token: gh auth login, or GITHUB_TOKEN)"
        api_stop=1
      else
        api_error="GitHub answered $code: $(jq -r '.message // empty' <<< "$answer" 2> /dev/null)"
      fi ;;
    *) api_error="GitHub answered $code" ;;
  esac
  answer=""
  return 1
}

# a value as a part of an address (a branch such as feature/x)
uri() { jq -rn --arg value "$1" '$value | @uri'; }

# what a workflow does, from what it runs (not its comments): check, build, or nothing
kind_of() {
  local code
  code=$(sed '/^[[:space:]]*#/d' "$1")
  if grep -qiE 'check-r-package|rcmdcheck|R CMD check|devtools::check' <<< "$code"; then
    echo check
  elif grep -qiE 'R CMD build|devtools::build|pkgbuild::build' <<< "$code"; then
    echo build
  fi
}

# the branches a workflow names (under on:), such as [master]
branches_of() {
  sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]]#.*//' "$1" | awk '
    /^[[:space:]]*branches:/ { sub(/^[[:space:]]*branches:[[:space:]]*/, ""); if ($0 != "") print; else list = 1; next }
    list && /^[[:space:]]*-/  { sub(/^[[:space:]]*-[[:space:]]*/, ""); print; next }
                              { list = 0 }' | sort -u | paste -sd ' ' -
}

# the latest run on the default branch of one workflow: sets rank (1 a problem, 2 still
# running, 3 fine) and text (the result and when it started), and adds to details what to
# show under the line
latest_run() {
  local kind=$1 file=$2 slug=$3 branch=$4 name status result created id link when on line
  name=$(basename "$file")
  api "repos/$slug/actions/workflows/$(uri "$name")/runs?branch=$(uri "$branch")&per_page=1"; status=$?
  if [ $status -eq 4 ]; then
    rank=1; text="not on GitHub"
    details+=("$kind: GitHub does not have $name yet: push it")
    return
  elif [ $status -ne 0 ]; then
    rank=1; text="unknown"
    return
  fi
  IFS=$'\t' read -r result created id link < <(jq -r '
    .workflow_runs[0] // empty | [.conclusion // .status, .created_at, .id, .html_url] | @tsv' <<< "$answer")
  if [ -z "$result" ]; then
    rank=1; text="no runs on $branch"
    on=$(branches_of "$file")
    if [ -n "$on" ] && ! grep -qwF -- "$branch" <<< "$on"; then
      details+=("$kind: $name runs only on the branches $on, not on $branch")
    else
      details+=("$kind: $name has never run on $branch: start it with Run workflow on https://github.com/$slug/actions/workflows/$name")
    fi
    return
  fi
  when=$(date -d "$created" '+%d/%m %H:%M' 2> /dev/null) || when=${created:0:10}
  printf -v text '%-11s %s' "$result" "$when"
  case "$result" in
    success|skipped|neutral) rank=3 ;;
    in_progress|queued|waiting|requested|pending) rank=2 ;;
    *)
      rank=1
      details+=("$kind $result: $link")
      # the jobs that failed, each with the step it failed at
      if [ "$result" = failure ] || [ "$result" = timed_out ]; then
        if api "repos/$slug/actions/runs/$id/jobs?per_page=100"; then
          while IFS= read -r line; do details+=("  $line"); done < <(jq -r '
            .jobs[] | select(.conclusion == "failure" or .conclusion == "timed_out")
            | "\(.name): \([.steps[]? | select(.conclusion == "failure" or .conclusion == "timed_out") | .name][0] // .conclusion)"' <<< "$answer")
        fi
      fi ;;
  esac
}

# a list as "a, b, c"
join_list() { local out="" item; for item in "$@"; do out+="${out:+, }$item"; done; printf '%s' "$out"; }

echo "${#dirs[@]} R package(s) in $root: the latest run on GitHub of their build and check"
[ -z "$token" ] && echo "No token (GITHUB_TOKEN, or gh auth login): public repositories only, 60 requests an hour"
echo
printf '%-*s  %-24s  %s\n' "$width" "package" "build" "check"

declare -A branch_of=()
problems=(); running=(); without_build=(); without_check=(); check_failed=0; seen=0
for i in "${!dirs[@]}"; do
  dir=${dirs[$i]}; short=${dirs[$i]#"$root"/}; details=()
  [ "$dir" = "$root" ] && short=$(basename "$dir")
  printf '%-*s  ' "$width" "${labels[$i]}"

  # the repository on GitHub, from its remote origin
  top=$(git -C "$dir" rev-parse --show-toplevel 2> /dev/null)
  url=$(git -C "$dir" remote get-url origin 2> /dev/null); url=${url%/}
  slug=""
  [[ "$url" =~ github\.com[:/]+([^/]+)/([^/]+)$ ]] && slug="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
  if [ -z "$top" ]; then
    echo "${grey}not on GitHub (not a git repository)${reset}"; continue
  elif [ -z "$url" ]; then
    echo "${grey}not on GitHub (no remote origin)${reset}"; continue
  elif [ -z "$slug" ]; then
    # without the user name and password an address may hold (https://user:token@host/...)
    echo "${grey}not on GitHub (origin: $(sed -E 's#//[^/@]*@#//#' <<< "$url"))${reset}"; continue
  fi

  # its default branch, asked once per repository
  if [ -z "${branch_of[$slug]:-}" ]; then
    api "repos/$slug"; status=$?
    if [ $status -eq 0 ]; then
      branch_of[$slug]=$(jq -r 'if .archived then ":archived" else .default_branch end' <<< "$answer")
    elif [ $status -eq 4 ]; then
      branch_of[$slug]=":not found"
    else
      branch_of[$slug]=":unknown"
    fi
  fi
  branch=${branch_of[$slug]}
  case "$branch" in
    :archived)
      echo "${grey}archived on GitHub ($slug)${reset}"; continue ;;
    ':not found')
      reason="not found on GitHub ($slug)"
      [ -z "$token" ] && reason+=": a private repository needs a token"
      echo "${red}$reason${reset}"; problems+=("$short"); continue ;;
    :unknown)
      echo "${red}could not ask GitHub${reset}"; problems+=("$short"); continue ;;
  esac

  # its workflows that build and that check, and the latest run of each: with two of a
  # kind, the cell shows the worse
  build_files=(); check_files=()
  for file in "$top"/.github/workflows/*.yml "$top"/.github/workflows/*.yaml; do
    [ -f "$file" ] || continue
    case "$(kind_of "$file")" in
      build) build_files+=("$file") ;;
      check) check_files+=("$file") ;;
    esac
  done
  bad=(); busy=()
  for kind in build check; do
    if [ $kind = build ]; then files=("${build_files[@]}"); else files=("${check_files[@]}"); fi
    cell_rank=4; cell_text="no workflow"
    if [ ${#files[@]} -gt 0 ]; then
      cell_rank=5
      for file in "${files[@]}"; do
        latest_run "$kind" "$file" "$slug" "$branch"
        if [ $rank -lt $cell_rank ]; then cell_rank=$rank; cell_text=$text; fi
        [ $kind = check ] && [[ "$text" == failure* ]] && check_failed=1
      done
    fi
    case $cell_rank in
      1) color=$red; bad+=("$kind") ;;
      2) color=$yellow; busy+=("$kind") ;;
      3) color=$green ;;
      *) color=$grey
         if [ $kind = build ]; then without_build+=("$short"); else without_check+=("$short"); fi ;;
    esac
    [ $cell_rank -le 3 ] && seen=$((seen + 1))
    if [ $kind = build ]; then
      printf '%s%-24s%s  ' "$color" "$cell_text" "$reset"
    else
      printf '%s%s%s\n' "$color" "$cell_text" "$reset"
    fi
  done
  for line in "${details[@]}"; do printf '    %s\n' "$line"; done
  [ ${#bad[@]} -gt 0 ] && problems+=("$short ($(join_list "${bad[@]}"))")
  [ ${#busy[@]} -gt 0 ] && running+=("$short ($(join_list "${busy[@]}"))")
done

echo
[ -n "$api_error" ] && echo "${red}$api_error${reset}"
[ ${#without_build[@]} -gt 0 ] && echo "${grey}No build workflow: $(join_list "${without_build[@]}")${reset}"
[ ${#without_check[@]} -gt 0 ] && echo "${grey}No check workflow: $(join_list "${without_check[@]}")${reset}"
[ ${#running[@]} -gt 0 ] && echo "${yellow}Still running, run this again in a few minutes:${reset} $(join_list "${running[@]}")"
if [ ${#problems[@]} -gt 0 ]; then
  echo "${red}With a problem (${#problems[@]}):${reset} $(join_list "${problems[@]}")"
  [ $check_failed -eq 1 ] && echo "r_cmd_check.sh <package> runs the same check here, with R's messages"
  exit 1
fi
if [ $seen -eq 0 ]; then
  echo "Nothing to look at: none of these packages has a build or check workflow on GitHub"; exit 1
elif [ ${#running[@]} -gt 0 ]; then
  echo "${green}No problems so far${reset}"
else
  echo "${green}The latest build and check of every package went fine${reset}"
fi
