#!/usr/bin/env bash
# Regenerates manifest.json, the file Posit Connect (Cloud) deploys a Shiny app
# from, in every app of ~/GitHub that already has one, so that it lists the
# package versions installed now. Nothing is committed or pushed.
#   shiny_update_manifests.sh              all apps with a manifest.json
#   shiny_update_manifests.sh golemirt     only these apps (also a first manifest)
# Another folder than ~/GitHub: ROOT=~/Projects shiny_update_manifests.sh
# Needs R and its rsconnect package.

root="${ROOT:-$HOME/GitHub}"

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

# R is needed, so without it it stops
check_packages 'Rscript:r-base-core:runs R'
command -v Rscript > /dev/null || exit 1
if ! Rscript -e 'quit(status = !requireNamespace("rsconnect", quietly = TRUE))' 2> /dev/null; then
  echo "The R package rsconnect is missing; in R: install.packages(\"rsconnect\")"
  exit 1
fi

# ask for the folder until one that exists is given (Tab completes paths, ~ works)
while [ ! -d "$root" ]; do
  echo "Folder not found: $root"
  read -e -r -p "Folder with the repositories (empty to quit): " root || exit 1
  [ -z "$root" ] && exit 1
  root="${root/#\~/$HOME}"
done

# the apps: the ones named, or every folder with both app.R and manifest.json
apps=(); not_deployed=()
if [ $# -gt 0 ]; then
  apps=("$@")
else
  for dir in "$root"/*/; do
    [ -f "$dir/app.R" ] || continue
    if [ -f "$dir/manifest.json" ]; then
      apps+=("$(basename "$dir")")
    else
      not_deployed+=("$(basename "$dir")")
    fi
  done
fi

updated=(); unchanged=(); failed=()
log=$(mktemp)
trap 'rm -f "$log"' EXIT

for name in "${apps[@]}"; do
  dir="$root/$name"
  echo "=== $name"
  if [ ! -f "$dir/app.R" ]; then
    echo "    no app.R, skipped"
    failed+=("$name: no app.R")
    continue
  fi
  # the same call as by hand; it fails when a package the app uses is not installed
  if (cd "$dir" && Rscript -e 'rsconnect::writeManifest(appDir = ".", appPrimaryDoc = "app.R")') > "$log" 2>&1; then
    if git -C "$dir" ls-files --error-unmatch manifest.json > /dev/null 2>&1 && git -C "$dir" diff --quiet -- manifest.json; then
      echo "    unchanged"
      unchanged+=("$name")
    else
      echo "    updated"
      updated+=("$name")
    fi
  else
    # the end of R's message says what went wrong (usually a missing package)
    tail -n 8 "$log" | sed 's/^/    /'
    failed+=("$name")
  fi
done

echo "==============================="
echo "Updated: ${#updated[@]}"
[ ${#updated[@]} -gt 0 ] && printf '  %s\n' "${updated[@]}"
echo "Unchanged: ${#unchanged[@]}"
if [ ${#not_deployed[@]} -gt 0 ]; then
  echo "Apps without a manifest.json, not touched (to make one: shiny_update_manifests.sh NAME):"
  printf '  %s\n' "${not_deployed[@]}"
fi
if [ ${#updated[@]} -gt 0 ]; then
  echo "Commit and push each updated manifest.json for Posit Connect to use it."
fi
if [ ${#failed[@]} -gt 0 ]; then
  echo "Failed (${#failed[@]}):"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
