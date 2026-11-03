#!/usr/bin/env bash
# Pushes the commits of every git repository in ~/GitHub (or the folder given)
# that are not on GitHub yet, but first runs R CMD check (r_cmd_check.sh) on
# each R package those commits change, and pushes a repository only when its
# packages pass: no errors or warnings (with --strict, no notes either). The
# check runs on a clean copy of the last commit (a git worktree), exactly what
# is pushed, so uncommitted or untracked files neither help nor spoil it.
# Nothing is committed. It lists the repositories with commits to push and asks
# before it checks and pushes them.
#   git_push_checked.sh [folder] [repository ...]   every repository, or only the ones named
#   git_push_checked.sh --dry-run                    checks, but pushes nothing
#   git_push_checked.sh --strict                     notes also stop a push
#   git_push_checked.sh --yes                        pushes without asking first
# The folder is given as a path (~/GitHub, ., ../work): a plain word is a repository.
# Commits that change nothing that goes into a package (only its site in docs/,
# or other files in .Rbuildignore) are pushed without a check. A repository
# behind GitHub, or without an upstream branch, is skipped. Only the commit that
# was listed is checked and pushed: commits made while the checks run wait for
# the next run. The exit code is 1 if any repository with commits to push was
# not pushed.

root="$HOME/GitHub"; dry_run=0; strict=0; yes=0; only=(); root_given=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --strict)  strict=1 ;;
    --yes)     yes=1 ;;
    -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    -*)        echo "Unknown option: $arg (see --help)"; exit 1 ;;
    *)
      # a path is the folder (a repository's name may also be a folder here)
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

red=$'\e[31m'; yellow=$'\e[33m'; green=$'\e[32m'; bold=$'\e[1m'; reset=$'\e[0m'

# a line of 80 # characters, between the repositories
separator() { printf '#%.0s' {1..80}; printf '\n'; }

# minutes and seconds
duration() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }

# anything but y/yes is no
yes_no() {
  local answer
  read -r -p "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# the checks are those of r_cmd_check.sh, which sits next to this script
checker="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/r_cmd_check.sh"
if [ ! -x "$checker" ]; then
  echo "r_cmd_check.sh is needed next to this script: $checker"; exit 1
fi

# the clean copies and the checks' logs; the checks get their own folder, so that
# they never clash with an r_cmd_check.sh running at the same time
out="${XDG_CACHE_HOME:-$HOME/.cache}/git_push_checked"
mkdir -p "$out"

# the clean copy of a repository, removed after each repository and at the end,
# also after Ctrl+C. git removes it, and only as a worktree of that repository
worktree=""; worktree_of=""
remove_worktree() {
  if [ -n "$worktree" ]; then
    git -C "$worktree_of" worktree remove --force "$worktree" 2> /dev/null
    git -C "$worktree_of" worktree prune 2> /dev/null
  fi
  worktree=""; worktree_of=""
}
trap remove_worktree EXIT
trap 'exit 130' INT TERM

# a Perl regular expression for the lines of a .Rbuildignore (given as text):
# R CMD build leaves out every path that matches one of them, ignoring case
ignore_regex() { grep -v '^[[:space:]]*$' <<< "$1" | sed 's/.*/(?:&)/' | paste -sd '|'; }

# whether a file (relative to its package folder) goes into the built package:
# neither it nor a folder it is in matches .Rbuildignore. .Rbuildignore itself
# counts, as it changes what is built
goes_into_build() {
  local regex=$1 file=$2 path="" part
  local -a parts
  [ "$file" = .Rbuildignore ] || [ -z "$regex" ] && return 0
  IFS=/ read -r -a parts <<< "$file"
  for part in "${parts[@]}"; do
    path=${path:+$path/}$part
    grep -qiP -- "$regex" <<< "$path" && return 1
  done
  return 0
}

# the result of the check of a package just run: the Status line of its log.
# r_cmd_check.sh makes the package's folder anew for each check, so an older
# folder means that this run did not check it
status_of() {
  local work="$out/cache/r_cmd_check_all/$1"
  if [ ! "$work" -nt "$out/.start" ]; then
    echo "not checked"
  elif [ ! -f "$work/$1.Rcheck/00check.log" ]; then
    echo "build failed"
  else
    sed -n 's/^Status: //p' "$work/$1.Rcheck/00check.log" | tail -n 1 | grep . || echo "check did not finish"
  fi
}

# whether a check result lets the push through
passes() {
  case "$1" in
    OK)                return 0 ;;
    *ERROR*|*WARNING*) return 1 ;;
    *NOTE*)            [ $strict -eq 0 ] ;;
    *)                 return 1 ;;
  esac
}

echo "Pushing what is not on GitHub yet in $root, after checking the R packages it changes"
[ $strict -eq 1 ] && echo "Strict: notes also stop a push"
[ $dry_run -eq 1 ] && echo "Dry run: nothing is pushed"

# first, after a fetch, the repositories with commits to push, each with its last
# commit, which is what is checked and pushed, and the branch on GitHub it goes to
not_pushed=(); summary=(); nothing=0; found=()
dirs=(); repos=(); branches=(); shas=(); upstreams=(); remotes=(); merges=(); aheads=()
shopt -s dotglob
for dir in "$root"/*/; do
  dir=${dir%/}
  [ -e "$dir/.git" ] || continue
  repo=$(basename "$dir")
  if [ ${#only[@]} -gt 0 ]; then
    wanted=0
    for want in "${only[@]}"; do [ "$want" = "$repo" ] && wanted=1; done
    [ $wanted -eq 1 ] || continue
  fi
  found+=("$repo")

  # the branch (also in a repository without commits yet) and where it is pushed to
  branch=$(git -C "$dir" symbolic-ref -q --short HEAD); remote=""; merge=""
  if [ -n "$branch" ]; then
    remote=$(git -C "$dir" config "branch.$branch.remote"); merge=$(git -C "$dir" config "branch.$branch.merge")
  fi
  if [ -z "$remote" ] || [ "$remote" = . ] || [ -z "$merge" ]; then
    # without an upstream branch there is nowhere to push to
    [ -z "$branch" ] && reason="detached HEAD" || reason="no upstream branch (git push -u origin $branch the first time)"
    summary+=("$(printf '%-32s %-10s %s' "$repo" "" "skipped: $reason")")
    continue
  fi
  if ! git -C "$dir" fetch -q 2> /dev/null; then
    not_pushed+=("$repo"); summary+=("$(printf '%-32s %-10s %s' "$repo" "" "skipped: fetch failed (no connection?)")")
    continue
  fi
  # after the fetch, as the branch may have been deleted on GitHub (with fetch.prune)
  upstream=$(git -C "$dir" rev-parse -q --verify --symbolic-full-name "@{u}")
  sha=$(git -C "$dir" rev-parse -q --verify HEAD)
  if [ -z "$upstream" ] || [ -z "$sha" ]; then
    [ -z "$sha" ] && reason="no commits yet" || reason="its branch is not on GitHub (deleted there?)"
    summary+=("$(printf '%-32s %-10s %s' "$repo" "" "skipped: $reason")")
    continue
  fi
  ahead=$(git -C "$dir" rev-list --count "$upstream..$sha")
  behind=$(git -C "$dir" rev-list --count "$sha..$upstream")
  if [ "$ahead" -eq 0 ]; then
    nothing=$((nothing + 1)); continue
  fi
  if [ "$behind" -gt 0 ]; then
    not_pushed+=("$repo")
    summary+=("$(printf '%-32s %-10s %s' "$repo" "" "not pushed: $behind commits on GitHub to pull first (git_pull_all.sh)")")
    continue
  fi
  dirs+=("$dir"); repos+=("$repo"); branches+=("$branch"); shas+=("$sha")
  upstreams+=("$upstream"); remotes+=("$remote"); merges+=("$merge"); aheads+=("$ahead")
done

# a misspelled name would otherwise check and push nothing, quietly
missing=()
for want in "${only[@]}"; do
  printf '%s\n' "${found[@]}" | grep -qxF -- "$want" || missing+=("$want")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "${red}No repository named ${missing[*]} in $root${reset}"; exit 1
fi

# what is pushed, and the question before anything is
if [ ${#dirs[@]} -gt 0 ]; then
  echo
  echo "Commits to push, once the R packages they change pass the check:"
  for i in "${!dirs[@]}"; do
    [ "${aheads[$i]}" -eq 1 ] && commits="1 commit" || commits="${aheads[$i]} commits"
    printf '  %-32s %s\n' "${repos[$i]}" "${branches[$i]}, $commits"
  done
  if [ $dry_run -eq 0 ] && [ $yes -eq 0 ]; then
    if [ ! -t 0 ]; then
      echo "Not a terminal, so nothing can be asked: add --yes to push"; exit 1
    fi
    yes_no "Check them and push the ones that pass?" || { echo "Nothing was pushed"; exit 0; }
  fi
fi

for i in "${!dirs[@]}"; do
  dir=${dirs[$i]}; repo=${repos[$i]}; sha=${shas[$i]}; upstream=${upstreams[$i]}
  echo
  separator
  [ "${aheads[$i]}" -eq 1 ] && commits="1 commit" || commits="${aheads[$i]} commits"
  echo "${bold}$repo${reset}  (${branches[$i]}, $commits to push)"
  git -C "$dir" log --format='  %h %s' "$upstream..$sha" | head -n 5
  [ "${aheads[$i]}" -gt 5 ] && echo "  ..."
  start=$SECONDS
  if [ "$(git -C "$dir" rev-parse -q --verify HEAD)" != "$sha" ]; then
    echo "  ${yellow}HEAD has moved since the list: only ${sha:0:7}, as listed, is checked and pushed${reset}"
  fi
  uncommitted=$(git -C "$dir" status --porcelain | wc -l)
  [ "$uncommitted" -gt 0 ] && echo "  $uncommitted uncommitted files stay here: they are neither checked nor pushed"

  # the R packages in the commit whose built package the new commits change; with
  # core.quotePath off, git writes a name with letters such as ö as it is
  changed=$(git -C "$dir" -c core.quotePath=false diff --name-only --no-renames "$upstream" "$sha")
  names=()
  while IFS= read -r description; do
    prefix=${description%DESCRIPTION}
    name=$(git -C "$dir" show "$sha:$description" | awk -F': *' '$1 == "Package" { sub(/[ \t\r]+$/, "", $2); print $2; exit }')
    [ -n "$name" ] || continue
    regex=$(ignore_regex "$(git -C "$dir" show "$sha:${prefix}.Rbuildignore" 2> /dev/null)")
    while IFS= read -r file; do
      case "$file" in "$prefix"?*) ;; *) continue ;; esac
      if goes_into_build "$regex" "${file#"$prefix"}"; then
        names+=("$name"); break
      fi
    done <<< "$changed"
  done < <(git -C "$dir" -c core.quotePath=false ls-tree -r --name-only "$sha" | grep -E '^([^/]+/)?DESCRIPTION$')

  checked=""
  if [ ${#names[@]} -gt 0 ]; then
    echo "  checking ${names[*]} on a clean copy of the last commit"
    worktree=$(mktemp -d "$out/$repo.XXXXXX"); worktree_of=$dir
    if ! git -C "$dir" worktree add --detach -q "$worktree" "$sha" 2> "$out/$repo.worktree.log"; then
      result="not pushed: could not make a clean copy ($out/$repo.worktree.log)"
      echo "  ${red}$result${reset}"
      remove_worktree
      not_pushed+=("$repo"); summary+=("$(printf '%-32s %-10s %s' "$repo" "$(duration $((SECONDS - start)))" "$result")")
      continue
    fi
    # the copy has a .git file where a repository has a .git folder. R CMD build
    # always leaves the folder out, but not the file, which R CMD check then notes
    # as a hidden file; the copy's .Rbuildignore leaves it out
    ignore="$worktree/.Rbuildignore"
    [ -s "$ignore" ] && [ -n "$(tail -c 1 "$ignore")" ] && echo >> "$ignore"
    echo '^\.git$' >> "$ignore"
    # r_cmd_check.sh's lines for each package, without its summary
    touch "$out/.start"
    XDG_CACHE_HOME="$out/cache" "$checker" "$worktree" "${names[@]}" < /dev/null 2>&1 |
      tee "$out/$repo.check.log" | {
        skip=0
        while IFS= read -r line; do
          case "$line" in
            *Summary*) skip=1 ;;
            Checking*|'#'*|"") ;;
            *) [ $skip -eq 0 ] && printf '  %s\n' "${line//"$worktree"/$repo}" ;;
          esac
        done; }
    remove_worktree
    failing=()
    for name in "${names[@]}"; do
      status=$(status_of "$name")
      checked="$checked, $name $status"
      passes "$status" || failing+=("$name $status")
    done
    checked=" (checked:${checked#,})"
    if [ ${#failing[@]} -gt 0 ]; then
      result="not pushed: $(printf '%s, ' "${failing[@]}" | sed 's/, $//')"
      echo "  ${red}$result${reset}"
      not_pushed+=("$repo"); summary+=("$(printf '%-32s %-10s %s' "$repo" "$(duration $((SECONDS - start)))" "$result")")
      continue
    fi
  else
    checked=" (no R package changed)"
  fi

  if [ $dry_run -eq 1 ]; then
    result="would push$checked"
    echo "  ${green}$result${reset}"
  elif git -C "$dir" push -q "${remotes[$i]}" "$sha:${merges[$i]}" > "$out/$repo.push.log" 2>&1; then
    result="pushed$checked"
    echo "  ${green}$result${reset}"
  else
    result="push failed (see $out/$repo.push.log)"
    echo "  ${red}$result${reset}"
    tail -n 5 "$out/$repo.push.log" | sed 's/^/    /'
    not_pushed+=("$repo")
  fi
  summary+=("$(printf '%-32s %-10s %s' "$repo" "$(duration $((SECONDS - start)))" "$result")")
done

echo
separator
echo "${bold}Summary${reset}"
[ ${#summary[@]} -gt 0 ] && printf '  %s\n' "${summary[@]}"
echo "  Nothing to push in $nothing repositories"
if [ ${#not_pushed[@]} -gt 0 ]; then
  echo "${red}Not pushed: ${not_pushed[*]}${reset}"
fi
[ ${#not_pushed[@]} -eq 0 ]
