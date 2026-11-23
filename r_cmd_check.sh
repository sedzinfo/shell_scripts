#!/usr/bin/env bash
# Runs R CMD check on every R package in ~/GitHub (or the folder given), one
# after the other, and reports which packages have errors, warnings or notes,
# and which checks gave them. The repositories are not changed: each package is
# built and checked in ~/.cache/r_cmd_check_all, where the logs stay until the next run.
#   r_cmd_check.sh [folder] [package ...]   every package, or only the ones named
#   r_cmd_check.sh --as-cran                as CRAN checks a submission
#   r_cmd_check.sh --manual                 also the PDF manual (needs LaTeX)
# The folder is given as a path (~/GitHub, ., ../work): a plain word is a package.
# A package is a folder with a DESCRIPTION: a repository, or a folder in one
# (rwf/rwf). Suggested packages that are not installed do not stop a check, and
# the tests skipped on CRAN run, unless --as-cran (r_install_packages.sh
# installs what a package needs). The exit code is 1 if any package has errors.

# the functions that several scripts share
# shellcheck source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/lib/helpers.sh" || exit 1

root="$HOME/GitHub"; as_cran=0; manual=0; only=(); root_given=0
for arg in "$@"; do
  case "$arg" in
    --as-cran) as_cran=1 ;;
    --manual)  manual=1 ;;
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

ask_folder
root=$(cd "$root" && pwd)

# R is needed, so without it it stops
check_packages 'R:r-base-dev:runs R CMD check'
command -v R > /dev/null || exit 1
[ $manual -eq 1 ] && check_packages 'pdflatex:texlive-latex-extra:the PDF manual'

# the packages, one folder per package name: a package found twice (a mirror
# repository, e.g. crypto and golemcrypto) is checked in the folder named after it
declare -A folder_of=()
duplicates=()
while IFS= read -r description; do
  dir=$(dirname "$description")
  # a name R would not take is skipped, as it names the folder that each check deletes
  # and makes anew
  name=$(package_name "$description")
  [[ "$name" =~ ^[A-Za-z][A-Za-z0-9.]*$ ]] || continue
  if [ -z "${folder_of[$name]:-}" ]; then
    folder_of[$name]=$dir
  elif [ "$(basename "$dir")" = "$name" ]; then
    duplicates+=("$(relative "${folder_of[$name]}") (the same package as $(relative "$dir"))")
    folder_of[$name]=$dir
  else
    duplicates+=("$(relative "$dir") (the same package as $(relative "${folder_of[$name]}"))")
  fi
done < <(package_files "$root")

# the packages named on the command line, by package name or folder name
names=()
for name in $(printf '%s\n' "${!folder_of[@]}" | sort); do
  wanted "$name" "$(basename "${folder_of[$name]}")" || continue
  names+=("$name")
done
if [ ${#names[@]} -eq 0 ]; then
  echo "No R packages${only[*]:+ named ${only[*]}} in $root"; exit 1
fi

out="${XDG_CACHE_HOME:-$HOME/.cache}/r_cmd_check_all"
check_args=()
[ $manual -eq 0 ] && check_args+=(--no-manual)
[ $as_cran -eq 1 ] && check_args+=(--as-cran)
# locally a missing suggested package is a note, not an error, and the tests
# marked skip_on_cran() run, as with devtools::check(); --as-cran keeps CRAN's rules
if [ $as_cran -eq 0 ]; then
  export _R_CHECK_FORCE_SUGGESTS_=false NOT_CRAN=true
fi

# the checks of 00check.log that were not OK, as "LEVEL: what was checked"; an
# error with its last lines (where R's error message is), a warning with its
# first ones (what it is about). A check's level is at the end of its line
# ("... NOTE", also "... [3s] NOTE"), or alone on a line after the tests' lines
problems() {
  awk '
    function flush(   i, from) {
      if (level == "ERROR") {
        from = n > 8 ? n - 7 : 1
        for (i = from; i <= n; i++) print "        " lines[i]
      } else if (level == "WARNING") {
        for (i = 1; i <= n && i <= 4; i++) print "        " lines[i]
      }
      level = ""; n = 0
    }
    function flag(new_level) { flush(); level = new_level; print "    " level ": " heading }
    /^\* / {
      flush()
      heading = $0
      sub(/^\* (checking )?/, "", heading)
      if (heading ~ / \.\.\. (\[[^]]*\] )?(ERROR|WARNING|NOTE)$/) {
        found = heading; sub(/.* /, "", found)
        sub(/ \.\.\. .*/, "", heading)
        flag(found)
      } else {
        sub(/ \.\.\.$/, "", heading)
      }
      next
    }
    /^ ?(ERROR|WARNING|NOTE)$/ { flag($1); next }
    level != "" && NF { lines[++n] = $0 }
    END { flush() }
  ' "$1"
}

echo "Checking ${#names[@]} package(s) of $root; logs in $out"
for dup in "${duplicates[@]}"; do echo "Skipped ${dup}"; done

with_errors=(); with_warnings=(); with_notes=(); summary=()
for name in "${names[@]}"; do
  dir=${folder_of[$name]}
  work="$out/$name"
  rm -rf "$work"
  mkdir -p "$work"
  echo
  separator
  version=$(awk -F': *' '$1 == "Version" { sub(/[ \t\r]+$/, "", $2); print $2; exit }' "$dir/DESCRIPTION")
  echo "${bold}$name $version${reset}  ($(relative "$dir"))"
  start=$SECONDS

  # the tarball CRAN would get: .Rbuildignore applied, vignettes built
  if ! (cd "$work" && R CMD build "$dir" > build.log 2>&1); then
    result="build failed"
    with_errors+=("$name")
    echo "  ${red}$result${reset}; the end of $work/build.log:"
    tail -n 15 "$work/build.log" | sed 's/^/    /'
  else
    tarball=$(ls "$work"/*.tar.gz)
    (cd "$work" && R CMD check "${check_args[@]}" "$tarball" > check.log 2>&1)
    log="$work/$name.Rcheck/00check.log"
    result=$(sed -n 's/^Status: //p' "$log" 2> /dev/null | tail -1)
    [ -z "$result" ] && result="check did not finish"
    case "$result" in
      OK)                       echo "  ${green}OK${reset}" ;;
      *ERROR*|"check did not finish") with_errors+=("$name"); echo "  ${red}$result${reset}" ;;
      *WARNING*)                with_warnings+=("$name"); echo "  ${yellow}$result${reset}" ;;
      *)                        with_notes+=("$name"); echo "  $result" ;;
    esac
    if [ "$result" = "check did not finish" ]; then
      tail -n 15 "$work/check.log" | sed 's/^/    /'
    elif [ "$result" != OK ]; then
      problems "$log"
      echo "    log: $log"
    fi
  fi
  summary+=("$(printf '%-16s %-12s %-10s %s' "$name" "$version" "$(duration $((SECONDS - start)))" "$result")")
done

echo
separator
echo "${bold}Summary${reset}"
printf '  %s\n' "${summary[@]}"
echo
if [ ${#with_errors[@]} -gt 0 ]; then
  echo "${red}Errors in ${#with_errors[@]}:${reset} ${with_errors[*]}"
fi
if [ ${#with_warnings[@]} -gt 0 ]; then
  echo "${yellow}Warnings in ${#with_warnings[@]}:${reset} ${with_warnings[*]}"
fi
if [ ${#with_notes[@]} -gt 0 ]; then
  echo "Only notes in ${#with_notes[@]}: ${with_notes[*]}"
fi
passed=$(( ${#names[@]} - ${#with_errors[@]} - ${#with_warnings[@]} - ${#with_notes[@]} ))
[ $passed -gt 0 ] && echo "${green}OK: $passed${reset}"
[ ${#with_errors[@]} -eq 0 ]
