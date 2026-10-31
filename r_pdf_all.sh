#!/usr/bin/env bash
# Makes the PDF reference manual (R CMD Rd2pdf, the manual CRAN shows) of every
# R package in ~/GitHub (or the folder given), one after the other, as
# <package>.pdf at the top of its repository, where the build-tarball workflows
# put it; or all in one folder with --to. It reports which manuals failed (with
# LaTeX's error) and the pages of the others. Nothing is committed or pushed.
#   r_pdf_all.sh [folder] [package ...]   every package, or only the ones named
#   r_pdf_all.sh --to ~/manuals           all the PDFs in that folder instead
# A package is a folder with a DESCRIPTION: a repository, or a folder in one
# (rwf/rwf). Mirror repositories with the same package (crypto and golemcrypto)
# each get their own PDF. Needs R and LaTeX. The exit code is 1 if any failed.

root="$HOME/GitHub"; to=""; only=(); root_given=0; next_is_to=0
for arg in "$@"; do
  if [ $next_is_to -eq 1 ]; then to="${arg/#\~/$HOME}"; next_is_to=0; continue; fi
  case "$arg" in
    --to)      next_is_to=1 ;;
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
[ $next_is_to -eq 1 ] && { echo "--to needs a folder"; exit 1; }

# ask for the folder until one that exists is given (Tab completes paths, ~ works)
while [ ! -d "$root" ]; do
  echo "Folder not found: $root"
  read -e -r -p "Folder with the repositories (empty to quit): " root || exit 1
  [ -z "$root" ] && exit 1
  root="${root/#\~/$HOME}"
done
root=$(cd "$root" && pwd)
if [ -n "$to" ]; then
  mkdir -p "$to" || exit 1
  to=$(cd "$to" && pwd)
fi

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

# R and LaTeX are needed, so without them it stops
check_packages 'R:r-base-core:runs R CMD Rd2pdf' 'pdflatex:texlive-latex-extra:LaTeX, makes the PDF' \
  'makeindex:texlive-binaries:the index of the PDF'
command -v R > /dev/null && command -v pdflatex > /dev/null || exit 1
# the font R's manuals use for code (in TeX Live's texlive-fonts-extra; TinyTeX has it)
if command -v kpsewhich > /dev/null && ! kpsewhich inconsolata.sty > /dev/null; then
  echo "The LaTeX font inconsolata, which R's manuals use for code, is missing (package texlive-fonts-extra)."
  if command -v apt-get > /dev/null && [ -t 0 ] && yes_no "Install it now with sudo apt install texlive-fonts-extra (over 1 GB)?"; then
    sudo apt install -y texlive-fonts-extra
  fi
fi

# the packages: every folder with a DESCRIPTION, by folder, as each repository
# keeps its own PDF
dirs=()
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
  dirs+=("$dir")
done < <(find "$root" -maxdepth 3 \
           \( -name .git -o -name '*.Rcheck' -o -name renv -o -name venv -o -name .venv -o -name node_modules \) -prune \
           -o -name DESCRIPTION -type f -print | sort)
if [ ${#dirs[@]} -eq 0 ]; then
  echo "No R packages${only[*]:+ named ${only[*]}} in $root"; exit 1
fi

# R CMD Rd2pdf works in a temporary folder in the current one, so it runs here
out="${XDG_CACHE_HOME:-$HOME/.cache}/r_pdf_all"
mkdir -p "$out"

echo "Making ${#dirs[@]} manual(s) of $root; logs in $out"

failed=(); written=(); summary=()
declare -A made_from=()
for dir in "${dirs[@]}"; do
  label=${dir#"$root"/}
  name=$(awk -F': *' '$1 == "Package" { print $2; exit }' "$dir/DESCRIPTION")
  log="$out/${label//\//_}.log"
  # in the --to folder one PDF per package is enough: a mirror repository of a
  # package already made there is skipped
  if [ -n "$to" ] && [ -n "${made_from[$name]:-}" ]; then
    summary+=("$(printf '%-32s %s' "$label" "skipped, the same package as ${made_from[$name]}")")
    continue
  fi
  made_from[$name]=$label
  # at the top of the repository, as the workflows do, or in the --to folder
  if [ -n "$to" ]; then
    pdf="$to/$name.pdf"
  else
    pdf="$(git -C "$dir" rev-parse --show-toplevel 2> /dev/null || echo "$dir")/$name.pdf"
  fi
  echo
  separator
  echo "${bold}$name${reset}  ($label -> ${pdf#"$root"/})"

  if (cd "$out" && R CMD Rd2pdf "$dir" --force --no-preview --output="$pdf" > "$log" 2>&1) && [ -s "$pdf" ]; then
    written+=("$pdf")
    pages=""
    command -v pdfinfo > /dev/null && pages=$(pdfinfo "$pdf" 2> /dev/null | awk '/^Pages:/ { print $2 }')
    result="${pages:+$pages pages, }$(du -h "$pdf" | cut -f1)"
    echo "  ${green}$result${reset}"
    # problems in the help files that R warns about but still puts in the manual
    grep -E '^Warning' "$log" | sort -u | head -n 10 | sed "s/^/    ${yellow}/; s/\$/${reset}/"
  else
    result="failed"
    failed+=("$name ($label)")
    echo "  ${red}failed${reset}; LaTeX's error, from $log:"
    # LaTeX's first error (lines starting with !; LaTeX runs several times and
    # repeats it), with the line it is on; without one, the end of the log
    if grep -q '^!' "$log"; then
      grep -m 1 -A 3 '^!' "$log" | sed 's/^/    /'
    else
      tail -n 15 "$log" | sed 's/^/    /'
    fi
  fi
  summary+=("$(printf '%-32s %s' "$label" "$result")")
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
if [ ${#written[@]} -gt 0 ]; then
  if [ -n "$to" ]; then
    echo "${green}${#written[@]} PDF(s) in $to${reset}"
  else
    echo "${#written[@]} PDF(s) written in their repositories; commit them, or let the build-tarball workflows rebuild them on push."
  fi
fi
[ ${#failed[@]} -eq 0 ]
