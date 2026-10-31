#!/usr/bin/env bash
# Builds the pkgdown website of every R package in ~/GitHub (or the folder
# given) that has a _pkgdown.yml, one after the other, into the folder the site
# is published from (docs/, or the destination in _pkgdown.yml). It reports
# which builds failed and which repositories have changed files in their site,
# to commit and push. Nothing is committed or pushed.
#   r_pkgdown_all.sh [folder] [package ...]   every package, or only the ones named
#   r_pkgdown_all.sh --no-examples            without running the examples (quicker)
# A package is a folder with a DESCRIPTION: a repository, or a folder in one
# (rwf/rwf). Mirror repositories with the same package (crypto and golemcrypto)
# each get their own site. The exit code is 1 if any build failed.

root="$HOME/GitHub"; examples=TRUE; only=(); root_given=0
for arg in "$@"; do
  case "$arg" in
    --no-examples) examples=FALSE ;;
    -h|--help)     sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    -*)            echo "Unknown option: $arg (see --help)"; exit 1 ;;
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

# a line of 80 # characters, between the packages
separator() { printf '#%.0s' {1..80}; printf '\n'; }

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

# R and pkgdown are needed, so without them it stops; pandoc renders the articles
check_packages 'Rscript:r-base-dev:runs R' 'pandoc:pandoc:the articles (vignettes)'
command -v Rscript > /dev/null || exit 1
if ! Rscript -e 'quit(status = as.integer(!requireNamespace("pkgdown", quietly = TRUE)))' 2> /dev/null; then
  echo "The R package pkgdown is not installed."
  yes_no "Install it now, into your R library?" || exit 1
  Rscript -e 'lib <- Sys.getenv("R_LIBS_USER"); dir.create(lib, recursive = TRUE, showWarnings = FALSE)
              install.packages("pkgdown", lib = lib, repos = "https://cloud.r-project.org")' || exit 1
fi

# the pkgdown configuration of a package folder, where pkgdown looks for it
config_of() {
  local file
  for file in _pkgdown.yml _pkgdown.yaml pkgdown/_pkgdown.yml pkgdown/_pkgdown.yaml inst/_pkgdown.yml; do
    [ -f "$1/$file" ] && { echo "$1/$file"; return; }
  done
}

# the packages: every folder with a DESCRIPTION, by folder, as each repository
# publishes its own site
dirs=(); no_config=()
while IFS= read -r description; do
  dir=$(dirname "$description")
  name=$(awk -F': *' '$1 == "Package" { print $2; exit }' "$description")
  [ -n "$name" ] || continue
  if [ ${#only[@]} -gt 0 ]; then
    wanted=0
    for want in "${only[@]}"; do
      [ "$want" = "$name" ] || [ "$want" = "$(basename "$dir")" ] && wanted=1
    done
    [ $wanted -eq 1 ] || continue
  fi
  if [ -z "$(config_of "$dir")" ]; then
    no_config+=("${dir#"$root"/}")
  else
    dirs+=("$dir")
  fi
done < <(find "$root" -maxdepth 3 \
           \( -name .git -o -name '*.Rcheck' -o -name renv -o -name venv -o -name .venv -o -name node_modules \) -prune \
           -o -name DESCRIPTION -type f -print | sort)
if [ ${#dirs[@]} -eq 0 ]; then
  echo "No R packages with a _pkgdown.yml${only[*]:+ named ${only[*]}} in $root"
  [ ${#no_config[@]} -gt 0 ] && echo "Without one: ${no_config[*]} (pkgdown::use_pkgdown() sets one up)"
  exit 1
fi

out="${XDG_CACHE_HOME:-$HOME/.cache}/r_pkgdown_all"
mkdir -p "$out"

# minutes and seconds
duration() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }

echo "Building ${#dirs[@]} site(s) in $root; logs in $out"
[ ${#no_config[@]} -gt 0 ] && echo "Skipped, no _pkgdown.yml (pkgdown::use_pkgdown() sets one up): ${no_config[*]}"

failed=(); to_commit=(); example_errors=(); summary=()
for dir in "${dirs[@]}"; do
  label=${dir#"$root"/}
  name=$(awk -F': *' '$1 == "Package" { print $2; exit }' "$dir/DESCRIPTION")
  log="$out/${label//\//_}.log"
  # the site's folder: destination in _pkgdown.yml, relative to the package, or docs
  destination=$(awk -F': *' '$1 == "destination" { gsub(/["'\'']/, "", $2); print $2; exit }' "$(config_of "$dir")")
  site=$(cd "$dir" && realpath -m "${destination:-docs}")
  echo
  separator
  echo "${bold}$name${reset}  ($label -> ${site#"$root"/})"
  start=$SECONDS

  # pkgdown installs the package in a temporary library and builds in a new R process
  touch "$out/.start"
  if Rscript -e "pkgdown::build_site(commandArgs(TRUE)[1], preview = FALSE, examples = $examples)" "$dir" > "$log" 2>&1; then
    result="built"; color=$green
    # an example that fails does not stop pkgdown: the help page shows the error
    # (class r-err), so the pages written now are searched for one
    broken=$(find "$site/reference" -name '*.html' -newer "$out/.start" -exec grep -l 'class="r-err' {} + 2> /dev/null |
      xargs -r -n 1 basename | sed 's/\.html$//' | sort | tr '\n' ' ')
    if [ -n "$broken" ]; then
      result="built, examples fail in $(wc -w <<< "$broken") pages"; color=$yellow
      example_errors+=("$label: $broken")
    fi
    changed=$(git -C "$dir" status --porcelain -- "$site" 2> /dev/null | wc -l)
    if [ "$changed" -gt 0 ]; then
      to_commit+=("$(git -C "$dir" rev-parse --show-toplevel 2> /dev/null | xargs basename)")
      result="$result, $changed changed files"
    fi
    echo "  ${color}$result${reset}"
    [ -n "$broken" ] && echo "    ${yellow}examples with errors: $broken${reset}"
    # pkgdown's warnings (lines starting with ! or ✖), such as missing alt-text or
    # topics missing from the reference index
    grep -E '^(!|✖) ' "$log" | sort -u | head -n 10 | sed "s/^/    ${yellow}/; s/\$/${reset}/"
  else
    result="failed"
    failed+=("$name ($label)")
    echo "  ${red}failed${reset}; the end of $log:"
    tail -n 15 "$log" | sed 's/^/    /'
  fi
  summary+=("$(printf '%-32s %-10s %s' "$label" "$(duration $((SECONDS - start)))" "$result")")
done

echo
separator
echo "${bold}Summary${reset}"
printf '  %s\n' "${summary[@]}"
echo
if [ ${#failed[@]} -gt 0 ]; then
  echo "${red}Failed in ${#failed[@]}:${reset}"
  printf '  %s\n' "${failed[@]}"
fi
if [ ${#example_errors[@]} -gt 0 ]; then
  echo "${yellow}Examples with errors (the help page shows the error):${reset}"
  printf '  %s\n' "${example_errors[@]}"
fi
if [ ${#to_commit[@]} -gt 0 ]; then
  echo "Changed sites, to commit and push for GitHub Pages: $(printf '%s\n' "${to_commit[@]}" | sort -u | tr '\n' ' ')"
fi
[ ${#failed[@]} -eq 0 ]
