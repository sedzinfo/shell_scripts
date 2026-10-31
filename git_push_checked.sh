#!/usr/bin/env bash
# Pushes the commits of every git repository in ~/GitHub (or the folder given)
# that are not on GitHub yet, but first runs R CMD check (r_cmd_check.sh) on
# each R package those commits change, and pushes a repository only when its
# packages pass: no errors or warnings (with --strict, no notes either). The
# check runs on a clean copy of the last commit (a git worktree), exactly what
# would be pushed, so uncommitted or untracked files neither help nor spoil it.
# Nothing is committed.
#   git_push_checked.sh [folder] [repository ...]   every repository, or only the ones named
#   git_push_checked.sh --dry-run                    checks, but pushes nothing
#   git_push_checked.sh --strict                     notes also stop a push
# Commits that change nothing that goes into a package (only its site in docs/,
# or other files in .Rbuildignore) are pushed without a check. A repository
# behind GitHub, or without an upstream branch, is skipped. The exit code is 1
# if any repository with commits to push was not pushed.

root="$HOME/GitHub"; dry_run=0; strict=0; only=(); root_given=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --strict)  strict=1 ;;
    -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    -*)        echo "Unknown option: $arg (see --help)"; exit 1 ;;
    *)
      if [ $root_given -eq 0 ] && [ -d "${arg/#\~/$HOME}" ]; then
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

not_pushed=(); summary=(); nothing=0
for dir in "$root"/*/; do
  dir=${dir%/}
  [ -e "$dir/.git" ] || continue
  repo=$(basename "$dir")
  if [ ${#only[@]} -gt 0 ]; then
    wanted=0
    for want in "${only[@]}"; do [ "$want" = "$repo" ] && wanted=1; done
    [ $wanted -eq 1 ] || continue
  fi

  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2> /dev/null)
  if ! git -C "$dir" rev-parse --verify -q "@{u}" > /dev/null; then
    # without an upstream branch there is nowhere to push to
    [ "$branch" = HEAD ] && reason="detached HEAD" || reason="no upstream branch (git push -u origin $branch the first time)"
    summary+=("$(printf '%-32s %-10s %s' "$repo" "" "skipped: $reason")")
    continue
  fi
  if ! git -C "$dir" fetch -q 2> /dev/null; then
    not_pushed+=("$repo"); summary+=("$(printf '%-32s %-10s %s' "$repo" "" "skipped: fetch failed (no connection?)")")
    continue
  fi
  ahead=$(git -C "$dir" rev-list --count "@{u}..HEAD")
  behind=$(git -C "$dir" rev-list --count "HEAD..@{u}")
  if [ "$ahead" -eq 0 ]; then
    nothing=$((nothing + 1)); continue
  fi

  echo
  separator
  [ "$ahead" -eq 1 ] && commits="1 commit" || commits="$ahead commits"
  echo "${bold}$repo${reset}  ($branch, $commits to push)"
  git -C "$dir" log --format='  %h %s' "@{u}..HEAD" | head -n 5
  [ "$ahead" -gt 5 ] && echo "  ..."
  start=$SECONDS
  if [ "$behind" -gt 0 ]; then
    result="not pushed: $behind commits on GitHub to pull first (git_pull_all.sh)"
    echo "  ${yellow}$result${reset}"
    not_pushed+=("$repo"); summary+=("$(printf '%-32s %-10s %s' "$repo" "" "$result")")
    continue
  fi
  uncommitted=$(git -C "$dir" status --porcelain | wc -l)
  [ "$uncommitted" -gt 0 ] && echo "  $uncommitted uncommitted files stay here: they are neither checked nor pushed"

  # the R packages in the last commit whose built package the new commits change
  changed=$(git -C "$dir" diff --name-only --no-renames "@{u}" HEAD)
  names=()
  while IFS= read -r description; do
    prefix=${description%DESCRIPTION}
    name=$(git -C "$dir" show "HEAD:$description" | awk -F': *' '$1 == "Package" { print $2; exit }')
    [ -n "$name" ] || continue
    regex=$(ignore_regex "$(git -C "$dir" show "HEAD:${prefix}.Rbuildignore" 2> /dev/null)")
    while IFS= read -r file; do
      case "$file" in "$prefix"?*) ;; *) continue ;; esac
      if goes_into_build "$regex" "${file#"$prefix"}"; then
        names+=("$name"); break
      fi
    done <<< "$changed"
  done < <(git -C "$dir" ls-tree -r --name-only HEAD | grep -E '^([^/]+/)?DESCRIPTION$')

  checked=""
  if [ ${#names[@]} -gt 0 ]; then
    echo "  checking ${names[*]} on a clean copy of the last commit"
    worktree=$(mktemp -d "$out/$repo.XXXXXX"); worktree_of=$dir
    if ! git -C "$dir" worktree add --detach -q "$worktree" HEAD 2> "$out/$repo.worktree.log"; then
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
  elif git -C "$dir" push -q > "$out/$repo.push.log" 2>&1; then
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
