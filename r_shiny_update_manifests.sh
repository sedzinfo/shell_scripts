#!/usr/bin/env bash
# Regenerates manifest.json, the file Posit Connect (Cloud) deploys a Shiny app
# from, in every app of ~/GitHub that already has one, so that it lists the
# package versions installed now. It lists the apps and asks first. Files that
# git ignores (such as .Renviron) are left out of the manifest, and an app that
# uses a package not installed here fails, as the manifest would leave the
# package out. Each manifest that changed is committed on its own and pushed,
# only when that pushes nothing else: the branch must track a branch on GitHub
# and have no commits that are not pushed yet (they would go with it). A branch
# behind (such as after the commits of GitHub Actions) first catches up, fast-
# forward only. Other changes, staged or not, are left as they are.
#   r_shiny_update_manifests.sh              all apps with a manifest.json
#   r_shiny_update_manifests.sh golemirt     only these apps (also a first manifest)
#   r_shiny_update_manifests.sh --yes        without asking first
#   r_shiny_update_manifests.sh --no-push    write them only, no commit or push
# Another folder than ~/GitHub: ROOT=~/Projects r_shiny_update_manifests.sh
# Needs R and its rsconnect package, and git.

root="${ROOT:-$HOME/GitHub}"; yes=0; push=1; names=()
for arg in "$@"; do
  case "$arg" in
    --yes)     yes=1 ;;
    --no-push) push=0 ;;
    -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    -*)        echo "Unknown option: $arg (see --help)"; exit 1 ;;
    *)         names+=("$arg") ;;
  esac
done

# anything but y/yes is no
yes_no() {
  local answer
  read -r -p "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

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
if [ ${#names[@]} -gt 0 ]; then
  apps=("${names[@]}")
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

# what is rewritten, and the question before anything is
if [ ${#apps[@]} -gt 0 ] && [ $yes -eq 0 ]; then
  echo "manifest.json is written anew in: ${apps[*]}"
  [ $push -eq 1 ] && echo "and each one that changes is committed and pushed (manifest.json only)"
  if [ ! -t 0 ]; then
    echo "Not a terminal, so nothing can be asked: add --yes to write them"; exit 1
  fi
  yes_no "Write them?" || { echo "Nothing was changed"; exit 0; }
fi

# the files of the app as rsconnect lists them, without the ones git ignores (such
# as .Renviron, which would be deployed with its secrets); and a stop when a
# package they use is not installed, which writeManifest would quietly leave out
manifest_code='
files <- rsconnect::listDeploymentFiles(".")
git <- suppressWarnings(system2("git", c("ls-files", "-co", "--exclude-standard"), stdout = TRUE, stderr = FALSE))
if (is.null(attr(git, "status"))) files <- intersect(files, git)
used <- unique(renv::dependencies(files, quiet = TRUE, progress = FALSE)$Package)
missing <- setdiff(used, rownames(installed.packages()))
if (length(missing)) stop("not installed here, so the manifest would leave them out: ", toString(missing), call. = FALSE)
rsconnect::writeManifest(appDir = ".", appFiles = files, appPrimaryDoc = "app.R")'

# commits manifest.json alone and pushes it, when that pushes nothing else; says
# why not otherwise. The manifest stays written either way
push_manifest() {
  local dir="$1" branch remote merge ahead behind
  if ! branch=$(git -C "$dir" symbolic-ref --short -q HEAD); then
    echo "    not pushed: not on a branch"; return 1
  fi
  remote=$(git -C "$dir" config "branch.$branch.remote"); merge=$(git -C "$dir" config "branch.$branch.merge")
  if [ -z "$remote" ] || [ -z "$merge" ]; then
    echo "    not pushed: $branch does not track a branch on GitHub"; return 1
  fi
  if ! git -C "$dir" fetch -q "$remote"; then
    echo "    not pushed: could not reach $remote"; return 1
  fi
  read -r ahead behind < <(git -C "$dir" rev-list --left-right --count 'HEAD...@{u}')
  if [ "$ahead" -gt 0 ]; then
    echo "    not pushed: $branch has $ahead commit(s) not pushed yet, which would go with it"; return 1
  fi
  # the commits of GitHub Actions (or of another computer) first
  if [ "$behind" -gt 0 ] && ! git -C "$dir" merge -q --ff-only '@{u}' > /dev/null 2>&1; then
    echo "    not pushed: $branch is $behind commit(s) behind GitHub and could not catch up (changes here in the way)"; return 1
  fi
  if git -C "$dir" ls-files --error-unmatch manifest.json > /dev/null 2>&1 && git -C "$dir" diff --quiet HEAD -- manifest.json; then
    echo "    already on GitHub"; return 0
  fi
  # with the path, the commit takes manifest.json only, whatever else is staged
  if ! { git -C "$dir" add -- manifest.json && git -C "$dir" commit -q -m "Update manifest.json" -- manifest.json; } > /dev/null; then
    echo "    not pushed: the commit failed"; return 1
  fi
  if ! git -C "$dir" push -q "$remote" "HEAD:$merge"; then
    echo "    committed, but the push failed: git -C $dir push"; return 1
  fi
  echo "    committed and pushed"
}

updated=(); unchanged=(); failed=(); not_pushed=()
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
  if (cd "$dir" && Rscript -e "$manifest_code") > "$log" 2>&1; then
    if git -C "$dir" ls-files --error-unmatch manifest.json > /dev/null 2>&1 && git -C "$dir" diff --quiet -- manifest.json; then
      echo "    unchanged"
      unchanged+=("$name")
    else
      echo "    updated"
      updated+=("$name")
      if [ $push -eq 1 ] && ! push_manifest "$dir"; then
        not_pushed+=("$name")
      fi
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
  echo "Apps without a manifest.json, not touched (to make one: r_shiny_update_manifests.sh NAME):"
  printf '  %s\n' "${not_deployed[@]}"
fi
if [ $push -eq 0 ] && [ ${#updated[@]} -gt 0 ]; then
  echo "Commit and push each updated manifest.json for Posit Connect to use it."
elif [ ${#not_pushed[@]} -gt 0 ]; then
  echo "Updated but not pushed (the reason is above), to commit and push yourself:"
  printf '  %s\n' "${not_pushed[@]}"
fi
if [ ${#failed[@]} -gt 0 ]; then
  echo "Failed (${#failed[@]}):"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
[ ${#not_pushed[@]} -eq 0 ]
