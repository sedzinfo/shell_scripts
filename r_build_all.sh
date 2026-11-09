#!/usr/bin/env bash
# Everything that makes an R package ready to push, for every R package in ~/GitHub
# (or the folder given), step by step: the help pages, the installation, R CMD check,
# the pkgdown website, the manifest.json of the Shiny apps, the PDF manual and the
# source tarball. Each step is the script of this folder that does it, so it does the
# same and reports the same; install and tarball are done here. It lists the packages
# and the steps and asks once, first. Nothing is committed or pushed.
#   r_build_all.sh [folder] [package ...]   every step, for every package or only the ones named
#   r_build_all.sh --skip check,pdf         without these steps
#   r_build_all.sh --only pkgdown,tarball   only these steps
#   r_build_all.sh --yes                    without asking first
# The steps, in this order:
#   document   help pages (man/) and NAMESPACE from roxygen     r_document_all.sh
#   install    the package installed in the R library            R CMD INSTALL
#   check      R CMD check: the tests and the examples           r_cmd_check.sh
#   pkgdown    the website, for packages with a _pkgdown.yml     r_pkgdown_all.sh
#   manifests  manifest.json, for apps that already have one     r_shiny_update_manifests.sh
#   pdf        the PDF manual, <package>.pdf                     r_pdf_all.sh
#   tarball    <package>_<version>.tar.gz at the top of the repository, replacing an
#              older one                                         R CMD build --resave-data
# The folder is given as a path (~/GitHub, ., ../work): a plain word is a package.
# A step that fails does not stop the others. The exit code is 1 if any step failed.

steps_all=(document install check pkgdown manifests pdf tarball)
root="$HOME/GitHub"; yes=0; only=(); root_given=0; skip=""; only_steps=""; next=""
for arg in "$@"; do
  if [ -n "$next" ]; then printf -v "$next" '%s' "$arg"; next=""; continue; fi
  case "$arg" in
    --skip)    next=skip ;;
    --only)    next=only_steps ;;
    --yes)     yes=1 ;;
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
[ -n "$next" ] && { echo "--$next needs a list of steps, such as check,pdf"; exit 1; }
[ "$next" = only_steps ] && { echo "--only needs a list of steps"; exit 1; }

# the steps to run: all, or --only, without --skip; unknown names stop it
in_list() { [[ ",$2," == *",$1,"* ]]; }
for name in ${skip//,/ } ${only_steps//,/ }; do
  in_list "$name" "$(IFS=,; echo "${steps_all[*]}")" || { echo "Unknown step: $name (steps: ${steps_all[*]})"; exit 1; }
done
steps=()
for step in "${steps_all[@]}"; do
  [ -n "$only_steps" ] && ! in_list "$step" "$only_steps" && continue
  in_list "$step" "$skip" && continue
  steps+=("$step")
done
[ ${#steps[@]} -eq 0 ] && { echo "No steps left to run"; exit 1; }

# ask for the folder until one that exists is given (Tab completes paths, ~ works)
while [ ! -d "$root" ]; do
  echo "Folder not found: $root"
  read -e -r -p "Folder with the repositories (empty to quit): " root || exit 1
  [ -z "$root" ] && exit 1
  root="${root/#\~/$HOME}"
done
root=$(cd "$root" && pwd)
here=$(cd "$(dirname "$0")" && pwd)

red=$'\e[31m'; yellow=$'\e[33m'; green=$'\e[32m'; bold=$'\e[1m'; reset=$'\e[0m'
banner() { printf '\n%s%s%s\n' "$bold" "$(printf '=%.0s' {1..80})" "$reset"; printf '%s%s%s\n' "$bold" "$1" "$reset"; }
yes_no() {
  local answer
  read -r -p "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}
command -v R > /dev/null || { echo "R is needed (sudo apt install r-base-core)"; exit 1; }

# the packages: every folder with a DESCRIPTION, as the step scripts find them
dirs=()
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
  dirs+=("$dir")
done < <(find "$root" -maxdepth 3 \
           \( -name .git -o -name '*.Rcheck' -o -name renv -o -name venv -o -name .venv -o -name node_modules \) -prune \
           -o -name DESCRIPTION -type f -print | sort)
if [ ${#dirs[@]} -eq 0 ]; then
  echo "No R packages${only[*]:+ named ${only[*]}} in $root"; exit 1
fi
field() { awk -F': *' -v f="$2" '$1 == f { sub(/[ \t\r]+$/, "", $2); print $2; exit }' "$1/DESCRIPTION"; }
top_of() { git -C "$1" rev-parse --show-toplevel 2> /dev/null || echo "$1"; }

# the Shiny apps whose manifest is updated: those named that already have a manifest.json
# (without names, r_shiny_update_manifests.sh finds them all)
apps=()
if [ ${#only[@]} -gt 0 ]; then
  for dir in "${dirs[@]}"; do
    [ -f "$dir/manifest.json" ] && [ "$(dirname "$dir")" = "$root" ] && apps+=("$(basename "$dir")")
  done
fi

out="${XDG_CACHE_HOME:-$HOME/.cache}/r_build_all"
mkdir -p "$out"
echo "${#dirs[@]} package(s) in $root: $(for dir in "${dirs[@]}"; do printf '%s ' "${dir#"$root"/}"; done)"
echo "Steps: ${steps[*]}"
# the one question, before anything is written; the steps are then run with --yes
if [ $yes -eq 0 ]; then
  echo "This rewrites man/, NAMESPACE, the websites, the manifests, the PDFs and the tarballs of these"
  echo "packages (as far as the steps go), and installs them. Nothing is committed or pushed."
  if [ ! -t 0 ]; then echo "Not a terminal, so nothing can be asked: add --yes to run"; exit 1; fi
  yes_no "Run the steps?" || { echo "Nothing was changed"; exit 0; }
fi

# the folder and the names, as the step scripts take them
pass=()
[ $root_given -eq 1 ] && pass+=("$root")
pass+=("${only[@]}")

declare -A result=()
for step in "${steps[@]}"; do
  banner "Step: $step"
  case "$step" in
    document)  "$here/r_document_all.sh" "${pass[@]}" --yes ;;
    check)     "$here/r_cmd_check.sh" "${pass[@]}" ;;
    pkgdown)   "$here/r_pkgdown_all.sh" "${pass[@]}" --yes ;;
    pdf)       "$here/r_pdf_all.sh" "${pass[@]}" --yes ;;
    manifests)
      if [ ${#only[@]} -gt 0 ] && [ ${#apps[@]} -eq 0 ]; then
        echo "None of these packages is a Shiny app with a manifest.json"; result[$step]="none"; continue
      fi
      ROOT="$root" "$here/r_shiny_update_manifests.sh" "${apps[@]}" --yes ;;
    install|tarball)
      status=0
      for dir in "${dirs[@]}"; do
        name=$(field "$dir" Package); label="${dir#"$root"/}"
        log="$out/${step}_${label//\//_}.log"
        if [ "$step" = install ]; then
          printf '  %-32s ' "$label"
          if R CMD INSTALL "$dir" > "$log" 2>&1; then
            echo "${green}installed $(field "$dir" Version)${reset}"
          else
            echo "${red}failed${reset}, the end of $log:"; tail -n 8 "$log" | sed 's/^/    /'; status=1
          fi
        else
          # at the top of the repository, as generate_package.R and the build-tarball
          # workflows put it, replacing the tarballs of older versions
          top=$(top_of "$dir")
          printf '  %-32s ' "$label"
          rm -f "$top/${name}"_*.tar.gz
          if (cd "$top" && R CMD build --resave-data "$dir") > "$log" 2>&1; then
            tarball=$(ls "$top/${name}"_*.tar.gz 2> /dev/null | head -n 1)
            echo "${green}${tarball#"$root"/}${reset} ($(du -h "$tarball" | cut -f1))"
          else
            echo "${red}failed${reset}, the end of $log:"; tail -n 8 "$log" | sed 's/^/    /'; status=1
          fi
        fi
      done
      ( exit $status ) ;;
  esac
  [ $? -eq 0 ] && result[$step]="ok" || result[$step]="failed"
done

banner "Summary"
failed=0
for step in "${steps[@]}"; do
  case "${result[$step]}" in
    ok)     printf '  %-10s %s\n' "$step" "${green}ok${reset}" ;;
    none)   printf '  %-10s %s\n' "$step" "nothing to do" ;;
    *)      printf '  %-10s %s\n' "$step" "${red}failed${reset} (see its report above)"; failed=1 ;;
  esac
done
# the repositories with changes to commit (the tarball and the PDF may be ignored by git)
echo
declare -A seen=()
for dir in "${dirs[@]}"; do
  top=$(top_of "$dir"); [ -n "${seen[$top]}" ] && continue; seen[$top]=1
  changed=$(git -C "$top" status --porcelain 2> /dev/null | wc -l)
  [ "$changed" -gt 0 ] && echo "  ${yellow}${top#"$root"/}${reset}: $changed changed file(s) to commit"
done
echo "Logs of install and tarball in $out"
exit $failed
