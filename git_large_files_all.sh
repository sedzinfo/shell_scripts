#!/usr/bin/env bash
# Finds the large files in every git repository in ~/GitHub (or the folder
# given), before GitHub refuses them: it warns about a file over 50 MB, and
# refuses a push with a file over 100 MB, even one deleted again in a later
# commit. Nothing is changed. For each repository it lists:
#   - files over 100 MB in commits not yet on GitHub, which make the push fail
#   - files over the size (50 MB) without Git LFS, committed or not yet
#   - files that .gitattributes puts in LFS but that were committed without it
#   - LFS files whose content was never downloaded (git lfs pull fetches them)
#   git_large_files_all.sh [folder] [repository ...]   every repository, or only the ones named
#   git_large_files_all.sh --size 20M                  also smaller files (default 50M)
#   git_large_files_all.sh --history                   also the largest files ever committed,
#                                                      which .git keeps after they are deleted
# The exit code is 1 if GitHub would refuse a push (or a commit of a file as it is now).

root="$HOME/GitHub"; size=50M; history=0; only=(); root_given=0
while [ $# -gt 0 ]; do
  case "$1" in
    --size)    size=${2:-}; shift ;;
    --history) history=1 ;;
    -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    -*)        echo "Unknown option: $1 (see --help)"; exit 1 ;;
    *)
      if [ $root_given -eq 0 ] && [ -d "${1/#\~/$HOME}" ]; then
        root="${1/#\~/$HOME}"; root_given=1
      else
        only+=("$1")
      fi ;;
  esac
  shift
done
if ! min=$(numfmt --from=iec "${size^^}" 2> /dev/null) || [ "$min" -lt 1 ]; then
  echo "--size takes a size such as 20M or 50M, not: $size"; exit 1
fi

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

# GitHub refuses a push with a file over 100 MB (100 MiB)
limit=$((100 * 1048576))

# a size in MB, as GitHub gives its limits (130.2 MB), or in KB below 1 MB
mb() { awk -v b="$1" 'BEGIN { if (b < 1048576) printf "%d KB", (b + 1023) / 1024; else printf "%.1f MB", b / 1048576 }'; }

# one finding: its size first, so the findings can be sorted by it, then the line shown
finding() { printf '%s\t  %10s  %-44s %s' "$1" "$(mb "$1")" "$2" "$3"; }

# whether a repository puts files in LFS: a .gitattributes of it has filter=lfs
uses_lfs() {
  local file
  while IFS= read -r -d '' file; do
    grep -qs 'filter=lfs' "$1/$file" && return 0
  done < <(git -C "$1" ls-files -z -- '*.gitattributes' 2> /dev/null)
  return 1
}

# git lfs is needed only where a repository uses LFS; without it the LFS files
# that were never downloaded are not looked for
for dir in "$root"/*/; do
  if [ -e "$dir/.git" ] && uses_lfs "${dir%/}"; then
    check_packages 'git-lfs:git-lfs:Git LFS files'; break
  fi
done

echo "Files over $(mb "$min") in the repositories of $root"
echo "(GitHub warns about a file over 50 MB and refuses a push with one over 100 MB)"

refused_repos=(); warned_repos=(); pointer_repos=(); clean=0; checked=0
declare -A seen=() blob_size=()
for dir in "$root"/*/; do
  dir=${dir%/}
  [ -e "$dir/.git" ] || continue
  repo=$(basename "$dir")
  if [ ${#only[@]} -gt 0 ]; then
    wanted=0
    for want in "${only[@]}"; do [ "$want" = "$repo" ] && wanted=1; done
    [ $wanted -eq 1 ] || continue
  fi
  checked=$((checked + 1))
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2> /dev/null)
  findings=(); hints=(); refused=0; warned=0; lfs_note=""; biggest=()
  seen=()

  # files in the commits that are on no remote yet, which a push would send
  while read -r type sha bytes path; do
    [ "$type" = blob ] && [ "$bytes" -ge "$min" ] || continue
    seen[$path]=1
    commit=$(git -C "$dir" log --reverse --format=%h --find-object="$sha" HEAD --not --remotes 2> /dev/null | head -n 1)
    if [ "$bytes" -gt "$limit" ]; then
      findings+=("$(finding "$bytes" "$path" "${red}in commit $commit, not pushed yet: GitHub refuses the push${reset}")")
      hints[1]="git lfs migrate import --include=FILE puts a file in LFS, rewriting only the commits not pushed yet"
      refused=1
    else
      findings+=("$(finding "$bytes" "$path" "${yellow}in commit $commit, not pushed yet, not in LFS: GitHub warns${reset}")")
      hints[1]="git lfs migrate import --include=FILE puts a file in LFS, rewriting only the commits not pushed yet"
      warned=1
    fi
  done < <(git -C "$dir" rev-list --objects HEAD --not --remotes 2> /dev/null |
             git -C "$dir" cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' 2> /dev/null)

  # files in the folder, committed or that git add would add (not the ignored
  # ones), that are not in LFS
  while IFS=$'\t' read -r bytes path; do
    [ -n "${seen[$path]:-}" ] && continue
    attribute=$(git -C "$dir" check-attr filter -- "$path")
    [ "${attribute##*: }" = lfs ] && continue
    seen[$path]=1
    if git -C "$dir" ls-files --error-unmatch -- "$path" > /dev/null 2>&1; then
      state="in git, not in LFS"
      hints[2]="git lfs migrate import --no-rewrite FILE moves a committed file to LFS in a new commit (older commits keep it)"
    else
      state="not committed yet, not in LFS"
      hints[3]="git lfs track FILE, before git add, puts a new file in LFS; or .gitignore leaves it out"
    fi
    if [ "$bytes" -gt "$limit" ]; then
      findings+=("$(finding "$bytes" "$path" "${red}$state: GitHub would refuse it${reset}")")
      refused=1
    else
      findings+=("$(finding "$bytes" "$path" "${yellow}$state: GitHub warns${reset}")")
      warned=1
    fi
  done < <(cd "$dir" && git ls-files -z --cached --others --exclude-standard 2> /dev/null |
             xargs -0 -r stat --printf '%s\t%n\n' -- 2> /dev/null | awk -F '\t' -v min="$min" '$1 >= min')

  if uses_lfs "$dir"; then
    # files .gitattributes puts in LFS but committed as they are: in a commit an
    # LFS file is a pointer of about 130 bytes, so a larger one is the file itself
    blob_size=()
    while IFS=$'\t' read -r -d '' meta path; do
      bytes=${meta##* }
      [[ "$bytes" =~ ^[0-9]+$ ]] && [ "$bytes" -gt 1024 ] && [ -z "${seen[$path]:-}" ] && blob_size[$path]=$bytes
    done < <(git -C "$dir" ls-tree -r -l -z HEAD 2> /dev/null)
    if [ ${#blob_size[@]} -gt 0 ]; then
      while IFS= read -r -d '' path && IFS= read -r -d '' attribute && IFS= read -r -d '' value; do
        [ "$value" = lfs ] || continue
        findings+=("$(finding "${blob_size[$path]}" "$path" "${yellow}in LFS by .gitattributes, but committed without it${reset}")")
        hints[4]="git lfs migrate import --no-rewrite FILE moves it to LFS in a new commit (committed before git lfs install?)"
        warned=1
      done < <(printf '%s\0' "${!blob_size[@]}" | git -C "$dir" check-attr -z --stdin filter 2> /dev/null)
    fi

    # LFS files whose content was never downloaded: only their pointer is here
    if command -v git-lfs > /dev/null; then
      mapfile -t pointers < <(git -C "$dir" lfs ls-files 2> /dev/null | awk '$2 == "-" { sub(/^[^ ]+ - /, ""); print }')
      if [ ${#pointers[@]} -gt 0 ]; then
        [ ${#pointers[@]} -eq 1 ] && files="LFS file" || files="LFS files"
        lfs_note="${#pointers[@]} $files not downloaded, e.g. ${pointers[0]} (git lfs pull fetches them)"
        pointer_repos+=("$repo")
      fi
    fi
  fi

  # the largest files of the whole history, which make .git big even when
  # deleted: per file its versions over the size, added up
  if [ $history -eq 1 ]; then
    mapfile -t biggest < <(git -C "$dir" rev-list --objects --all 2> /dev/null |
      git -C "$dir" cat-file --batch-check='%(objecttype) %(objectsize) %(rest)' 2> /dev/null |
      awk -v min="$min" '$1 == "blob" && $2 >= min {
          size = $2; sub(/^blob [0-9]+ /, ""); total[$0] += size; versions[$0]++
        }
        END { for (path in total) printf "%d\t%d\t%s\n", total[path], versions[path], path }' |
      sort -t $'\t' -k1,1nr | head -n 5)
  fi
  # and the local copies of old LFS versions, which git lfs prune deletes (GitHub
  # keeps them); git lfs says how much it would free
  prune_note=""
  if [ $history -eq 1 ] && [ -d "$dir/.git/lfs" ] && command -v git-lfs > /dev/null; then
    read -r count freed < <(git -C "$dir" lfs prune --dry-run 2>&1 |
      sed -n 's/^prune: \([0-9]*\) files\{0,1\} would be pruned (\(.*\)), done\.$/\1 \2/p' | tail -n 1)
    [ "${count:-0}" -gt 0 ] && prune_note="git lfs prune would free $freed: the local copies of $count old LFS versions (GitHub keeps them)"
  fi

  [ $refused -eq 1 ] && refused_repos+=("$repo")
  [ $refused -eq 0 ] && [ $warned -eq 1 ] && warned_repos+=("$repo")
  if [ ${#findings[@]} -eq 0 ] && [ -z "$lfs_note" ]; then
    clean=$((clean + 1))
    [ ${#biggest[@]} -eq 0 ] && [ -z "$prune_note" ] && continue
  fi

  echo
  separator
  echo "${bold}$repo${reset}  ($branch)"
  [ ${#findings[@]} -gt 0 ] && printf '%s\n' "${findings[@]}" | sort -t $'\t' -k1,1nr | cut -f 2-
  [ -n "$lfs_note" ] && echo "  $lfs_note"
  for hint in "${hints[@]}"; do echo "    $hint"; done
  if [ ${#biggest[@]} -gt 0 ] || [ -n "$prune_note" ]; then
    lfs_cache=$(du -sh "$dir/.git/lfs" 2> /dev/null | cut -f 1)
    echo "  .git is $(du -sh "$dir/.git" 2> /dev/null | cut -f 1): $(du -sh "$dir/.git/objects" 2> /dev/null | cut -f 1) of commits${lfs_cache:+, $lfs_cache of LFS copies}"
  fi
  if [ ${#biggest[@]} -gt 0 ]; then
    echo "  largest files ever committed:"
    for line in "${biggest[@]}"; do
      IFS=$'\t' read -r bytes versions path <<< "$line"
      [ "$versions" -gt 1 ] && path="$path  ($versions versions)"
      printf '  %10s  %s\n' "$(mb "$bytes")" "$path"
    done
    echo "    taking them out of .git means rewriting the history (git filter-repo), which changes every commit since"
  fi
  [ -n "$prune_note" ] && echo "    $prune_note"
done

if [ $checked -eq 0 ]; then
  echo "No git repositories${only[*]:+ named ${only[*]}} in $root"; exit 1
fi
echo
separator
[ ${#refused_repos[@]} -gt 0 ] && echo "${red}GitHub would refuse: ${refused_repos[*]}${reset}"
[ ${#warned_repos[@]} -gt 0 ] && echo "${yellow}Files over $(mb "$min") without LFS: ${warned_repos[*]}${reset}"
[ ${#pointer_repos[@]} -gt 0 ] && echo "LFS files not downloaded: ${pointer_repos[*]}"
[ "$clean" -gt 0 ] && echo "${green}No large files in $clean of $checked repositories${reset}"
[ ${#refused_repos[@]} -eq 0 ]
