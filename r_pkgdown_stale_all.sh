#!/usr/bin/env bash
# Finds the pkgdown websites that are out of date: for every R package in ~/GitHub (or the
# folder given) with a _pkgdown.yml, it compares when the site was built (last_built in
# docs/pkgdown.yml, or the last commit of docs/ when later, as a lazy build does not rewrite
# last_built) with the last change to what the site shows:
# R/, man/, README.md, DESCRIPTION, NEWS.md, _pkgdown.yml, pkgdown/ and vignettes/.
# Nothing is changed.
#   r_pkgdown_stale_all.sh [folder] [package ...]   every package, or only the ones named
# The changes are dated by their commits, not by the dates of the files, which a git pull
# or a clone rewrites; uncommitted changes by the date of the file. Each site is:
#   up to date      built after the last change
#   stale           changed since it was built: the files changed are listed
#   never built     no docs/pkgdown.yml
#   not pushed      built, but the site has uncommitted changes: GitHub shows the old one
# r_pkgdown_all.sh <package> (or r_build_all.sh <package> --only pkgdown) builds it again.
# The folder is given as a path (~/GitHub, ., ../work): a plain word is a package. The exit
# code is 1 if any site is stale, never built or not pushed.

root="$HOME/GitHub"; only=(); root_given=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    -*)        echo "Unknown option: $arg (see --help)"; exit 1 ;;
    *)
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

red=$'\e[31m'; yellow=$'\e[33m'; green=$'\e[32m'; reset=$'\e[0m'
sources=(R man README.md DESCRIPTION NEWS.md _pkgdown.yml pkgdown vignettes)
when() { date -d "@$1" '+%d/%m/%Y %H:%M'; }

attention=0; checked=0
while IFS= read -r yml; do
  dir=$(dirname "$yml"); label="${dir#"$root"/}"
  name=$(awk -F': *' '$1 == "Package" { sub(/[ \t\r]+$/, "", $2); print $2; exit }' "$dir/DESCRIPTION" 2> /dev/null)
  [ -n "$name" ] || continue
  if [ ${#only[@]} -gt 0 ]; then
    wanted=0; for want in "${only[@]}"; do [ "$want" = "$name" ] || [ "$want" = "$(basename "$dir")" ] && wanted=1; done
    [ $wanted -eq 1 ] || continue
  fi
  checked=$((checked + 1))
  # the folder the site is built into: destination in _pkgdown.yml, or docs
  dest=$(awk -F': *' '/^destination:/ { gsub(/["'\''\r]/, "", $2); sub(/[ \t]+#.*$/, "", $2); print $2; exit }' "$yml")
  dest=${dest:-docs}
  built_line=$(sed -n 's/^last_built: *//p' "$dir/$dest/pkgdown.yml" 2> /dev/null | head -n 1 | tr -d '\r')
  if [ -z "$built_line" ]; then
    printf '%-28s %s\n' "$label" "${red}never built${reset} (no $dest/pkgdown.yml)"
    attention=$((attention + 1)); continue
  fi
  built=$(date -d "$built_line" +%s)

  # what changed since the site: when the built site is committed, the commits after the one
  # that brought it (what was committed with it, or before, is in it); when it is built but
  # not committed, the commits after it was built. Uncommitted files by their date
  # a lazy build (build_site(lazy = TRUE)) does not rewrite last_built: the site is as new
  # as the last commit of anything in it, or, built but not committed, its newest file
  site_commit=""
  if [ -z "$(git -C "$dir" status --porcelain -- "$dest" 2> /dev/null)" ]; then
    site_commit=$(git -C "$dir" log -1 --format=%H -- "$dest" 2> /dev/null)
    t=$(git -C "$dir" log -1 --format=%ct -- "$dest" 2> /dev/null)
    [ -n "$t" ] && [ "$t" -gt "$built" ] && built=$t
  else
    while IFS= read -r -d '' entry; do
      [ -e "$dir/${entry:3}" ] || continue
      t=$(stat -c %Y "$dir/${entry:3}"); [ "$t" -gt "$built" ] && built=$t
    done < <(git -C "$dir" status --porcelain -z --untracked-files=all -- "$dest" 2> /dev/null)
  fi
  if [ -n "$site_commit" ]; then
    changed=$(git -C "$dir" diff --name-only "$site_commit" HEAD -- "${sources[@]}" 2> /dev/null | sort -u)
  else
    changed=$(git -C "$dir" log --since="@$built" --format= --name-only -- "${sources[@]}" 2> /dev/null | sed '/^$/d' | sort -u)
  fi
  latest=$(git -C "$dir" log -1 --format=%ct -- "${sources[@]}" 2> /dev/null)
  latest=${latest:-0}
  while IFS= read -r -d '' entry; do
    file=${entry:3}
    [ -e "$dir/$file" ] || continue
    t=$(stat -c %Y "$dir/$file")
    if [ "$t" -gt "$built" ]; then changed+=$'\n'"$file (uncommitted)"; fi
    [ "$t" -gt "$latest" ] && latest=$t
  done < <(git -C "$dir" status --porcelain -z --untracked-files=all -- "${sources[@]}" 2> /dev/null)
  changed=$(printf '%s\n' "$changed" | sed '/^$/d' | sort -u)
  # a site built locally but not committed is not what GitHub shows
  unpushed=$(git -C "$dir" status --porcelain -- "$dest" 2> /dev/null | wc -l)

  if [ -n "$changed" ]; then
    n=$(printf '%s\n' "$changed" | wc -l)
    printf '%-28s %s\n' "$label" "${red}stale${reset}: built $(when "$built"), $n file(s) changed since, the last $(when "$latest")"
    printf '%s\n' "$changed" | head -n 8 | sed 's/^/    /'
    [ "$n" -gt 8 ] && echo "    ... and $((n - 8)) more"
    attention=$((attention + 1))
  elif [ "$unpushed" -gt 0 ]; then
    printf '%-28s %s\n' "$label" "${yellow}not pushed${reset}: built $(when "$built"), $unpushed file(s) of $dest/ not committed"
    attention=$((attention + 1))
  else
    printf '%-28s %s\n' "$label" "${green}up to date${reset} (built $(when "$built"))"
  fi
done < <(find "$root" -maxdepth 3 \( -name .git -o -name '*.Rcheck' -o -name renv -o -name node_modules -o -name docs \) -prune \
           -o -name _pkgdown.yml -type f -print | sort)

echo
if [ $checked -eq 0 ]; then
  echo "No packages with a _pkgdown.yml${only[*]:+ named ${only[*]}} in $root"; exit 1
elif [ $attention -eq 0 ]; then
  echo "${green}All $checked site(s) are up to date${reset}"
else
  echo "$attention of $checked site(s) need attention: r_pkgdown_all.sh <package> builds a site again, then commit and push it"
  exit 1
fi
