#!/usr/bin/env bash
# Checks the manifest.json of every Shiny app in ~/GitHub (or the folder given), the file
# Posit Connect (Cloud) deploys from: whether it lists every file the app needs, and only
# files that are on GitHub. Nothing is changed.
#   r_manifest_check_all.sh [folder] [app ...]   every app with a manifest.json, or only these
# For each app it reports:
#   missing      files git tracks in R/ and inst/, and app.R, DESCRIPTION and NAMESPACE,
#                that the manifest does not list (and .rscignore does not leave out): the
#                deployed app would not have them
#   not on GitHub  files the manifest lists that git does not track: a deploy from GitHub
#                does not find them
#   deleted      files the manifest lists that no longer exist
# r_shiny_update_manifests.sh <app> writes the manifest anew. The folder is given as a path
# (~/GitHub, ., ../work): a plain word is an app. The exit code is 1 if any app has a problem.

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
# jq reads the manifest; it is offered when missing, as the other scripts do
if ! command -v jq > /dev/null; then
  echo "Missing: jq (reads manifest.json), package jq"
  if command -v apt-get > /dev/null && [ -t 0 ]; then
    read -r -p "Install it now with sudo apt install jq? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] && sudo apt install -y jq
  fi
  command -v jq > /dev/null || exit 1
fi

problems=0; checked=0
for dir in "$root"/*/; do
  dir=${dir%/}; app=$(basename "$dir")
  [ -f "$dir/manifest.json" ] || continue
  if [ ${#only[@]} -gt 0 ]; then
    wanted=0; for want in "${only[@]}"; do [ "$want" = "$app" ] && wanted=1; done
    [ $wanted -eq 1 ] || continue
  fi
  checked=$((checked + 1))
  listed=$(jq -r '.files | keys[]' "$dir/manifest.json" | sort)
  # what the app needs: tracked files of R/ and inst/, and the files at the top a golem app runs from
  needed=$(git -C "$dir" ls-files -- R inst app.R DESCRIPTION NAMESPACE 2> /dev/null | sort)
  # .rscignore leaves files or folders out of a deploy on purpose (one name per line)
  if [ -f "$dir/.rscignore" ]; then
    while IFS= read -r ignore; do
      ignore=${ignore%$'\r'}; [ -z "$ignore" ] && continue
      needed=$(printf '%s\n' "$needed" | grep -v -e "^${ignore}\$" -e "^${ignore}/" || true)
    done < "$dir/.rscignore"
  fi
  tracked=$(git -C "$dir" ls-files 2> /dev/null | sort)
  missing=$(comm -23 <(printf '%s\n' "$needed" | sed '/^$/d') <(printf '%s\n' "$listed"))
  untracked=$(comm -23 <(printf '%s\n' "$listed") <(printf '%s\n' "$tracked"))
  deleted=""
  while IFS= read -r file; do
    [ -n "$file" ] && [ ! -e "$dir/$file" ] && deleted+="$file"$'\n'
  done <<< "$listed"
  # a deleted file is also untracked: say it once
  untracked=$(comm -23 <(printf '%s\n' "$untracked") <(printf '%s' "$deleted" | sort))

  if [ -z "$missing" ] && [ -z "$untracked" ] && [ -z "$deleted" ]; then
    printf '%-24s %s\n' "$app" "${green}ok${reset} ($(printf '%s\n' "$listed" | wc -l) files)"
    continue
  fi
  problems=$((problems + 1))
  printf '%-24s %s\n' "$app" "${red}problem${reset}"
  [ -n "$missing" ] && printf '%s\n' "$missing" | sed "s/^/    ${red}missing${reset}        /"
  [ -n "$untracked" ] && printf '%s\n' "$untracked" | sed '/^$/d' | sed "s/^/    ${yellow}not on GitHub${reset}  /"
  [ -n "$deleted" ] && printf '%s' "$deleted" | sed "s/^/    ${yellow}deleted${reset}        /"
done

echo
if [ $checked -eq 0 ]; then
  echo "No apps with a manifest.json${only[*]:+ named ${only[*]}} in $root"; exit 1
elif [ $problems -eq 0 ]; then
  echo "${green}All $checked manifest(s) list what their app needs${reset}"
else
  echo "$problems of $checked manifest(s) need attention: r_shiny_update_manifests.sh <app> writes one anew"
  exit 1
fi
