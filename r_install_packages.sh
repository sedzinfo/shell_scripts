#!/usr/bin/env bash
# Installs everything the R code of a repository needs: first the system
# packages (apt) that the R packages need to compile, then the R packages.
# For an R package (a DESCRIPTION file) these are its Depends, Imports,
# LinkingTo and Suggests; for other repositories (analyses, Quarto sites) the
# packages that the .R/.Rmd/.qmd files load. It shows what is missing and asks
# before installing anything; what is already installed is left as it is.
#   r_install_packages.sh ~/GitHub/rwf
#   r_install_packages.sh                    the repository of the current folder

repo="${1:-.}"
repo="${repo/#\~/$HOME}"

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

yes_no() {
  local answer
  read -r -p "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ask for the repository until one that exists is given (Tab completes paths, ~ works)
while [ ! -d "$repo" ]; do
  echo "Folder not found: $repo"
  read -e -r -p "Repository (empty to quit): " repo || exit 1
  [ -z "$repo" ] && exit 1
  repo="${repo/#\~/$HOME}"
done
repo=$(cd "$repo" && pwd)

# R itself, with the compilers that R packages need on Linux; without R it stops
check_packages 'Rscript:r-base-dev:runs R and compiles packages' 'gcc:build-essential:C and C++ compiler' 'gfortran:gfortran:Fortran compiler'
command -v Rscript > /dev/null || exit 1

# R's own library in the home folder, so no sudo is needed for R packages
Rscript -e 'dir.create(Sys.getenv("R_LIBS_USER"), recursive = TRUE, showWarnings = FALSE)'
export R_LIBS_USER
R_LIBS_USER=$(Rscript -e 'cat(Sys.getenv("R_LIBS_USER"))')

# pak works out the system packages and installs the R ones
if ! Rscript -e 'quit(status = !requireNamespace("pak", quietly = TRUE))' 2> /dev/null; then
  echo "The R package pak is needed to work out what to install."
  yes_no "Install pak now?" || exit 1
  Rscript -e 'install.packages("pak", lib = Sys.getenv("R_LIBS_USER"), repos = sprintf("https://r-lib.github.io/p/pak/stable/%s/%s/%s", .Platform$pkgType, R.Version()$os, R.Version()$arch))' || exit 1
fi

# the R package of the repository: a DESCRIPTION at its top or one folder down (rwf/rwf)
description=$(find "$repo" -maxdepth 2 -name DESCRIPTION -not -path "*/.git/*" -not -path "*.Rcheck/*" -not -path "*/renv/*" | head -1)

# pak knows Ubuntu and Debian but not the systems built on them (Linux Mint,
# Pop!_OS, ...), so those are given as the Ubuntu version they are built on
platform=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  case "${UBUNTU_CODENAME:-}" in
    noble) platform=ubuntu-24.04 ;;
    jammy) platform=ubuntu-22.04 ;;
    focal) platform=ubuntu-20.04 ;;
    *)     [ "$ID" = "ubuntu" ] || [ "$ID" = "debian" ] && platform="$ID-$VERSION_ID" ;;
  esac
  # Raspberry Pi OS calls itself raspbian on older versions
  [ -z "$platform" ] && [ "$ID" = "raspbian" ] && platform="debian-$VERSION_ID"
fi

echo "=== Working out what $(basename "$repo") needs (this takes a minute)"
list=$(mktemp); trap 'rm -f "$list"' EXIT
# writes three kinds of lines to $list:
#   R <package>                an R package that is not installed
#   APT <package>              a system package the R packages need
#   POST <command>             a command to run after the system packages (e.g. R CMD javareconf)
REPO="$repo" DESCRIPTION_FILE="$description" OUT="$list" PLATFORM="$platform" Rscript -e '
  repo <- Sys.getenv("REPO"); description <- Sys.getenv("DESCRIPTION_FILE"); platform <- Sys.getenv("PLATFORM")
  if (nzchar(description)) {
    fields <- c("Depends", "Imports", "LinkingTo", "Suggests")
    d <- read.dcf(description, fields = fields)
    wanted <- unlist(lapply(d[!is.na(d)], function(x) trimws(sub("\\(.*", "", strsplit(x, ",")[[1]]))))
    cat("From", sub(paste0(dirname(repo), "/"), "", description), "\n")
  } else {
    if (!requireNamespace("renv", quietly = TRUE)) pak::pkg_install("renv", ask = FALSE)
    wanted <- unique(renv::dependencies(repo, progress = FALSE, quiet = TRUE)$Package)
    cat("From the library() and :: calls of the .R/.Rmd/.qmd files\n")
  }
  base <- rownames(installed.packages(priority = "base"))
  own <- if (nzchar(description)) read.dcf(description, fields = "Package")[1] else character()
  wanted <- setdiff(unique(wanted[nzchar(wanted)]), c("R", base, own))
  missing <- wanted[!vapply(wanted, function(p) nzchar(system.file(package = p)), logical(1))]
  cat(length(wanted), "R packages needed,", length(missing), "not installed\n")
  out <- if (length(missing)) paste("R", missing) else character()
  # the system packages, for all wanted packages and what they depend on
  s <- tryCatch(
    if (nzchar(platform)) pak::pkg_sysreqs(wanted, dependencies = NA, sysreqs_platform = platform)
    else pak::pkg_sysreqs(wanted, dependencies = NA),
    error = function(e) { cat("Could not work out the system packages for this system:", conditionMessage(e), "\n"); NULL })
  if (!is.null(s)) {
    apt <- unlist(strsplit(sub(".*install\\s+", "", grep("install", s$install_scripts, value = TRUE)), "\\s+"))
    out <- c(out, paste("APT", apt[nzchar(apt)]), if (length(s$post_install)) paste("POST", s$post_install))
  }
  writeLines(out, Sys.getenv("OUT"))
' || exit 1

# 1. system packages: only the ones not installed yet
missing_apt=()
while read -r kind name; do
  [ "$kind" = "APT" ] || continue
  dpkg-query -W -f='${Status}' "$name" 2> /dev/null | grep -q "install ok installed" && continue
  # pandoc and Java are often there without these packages (pandoc from
  # RStudio or a download, Java as openjdk-21-jdk), which is just as good
  [ "$name" = "pandoc" ] && command -v pandoc > /dev/null && continue
  [ "$name" = "default-jdk" ] && command -v javac > /dev/null && continue
  missing_apt+=("$name")
done < "$list"
if [ ${#missing_apt[@]} -eq 0 ]; then
  echo "System packages: all installed"
elif command -v apt-get > /dev/null; then
  echo "System packages not installed (${#missing_apt[@]}):"
  printf '  %s\n' "${missing_apt[@]}"
  if yes_no "Install them with sudo apt install?"; then
    sudo apt update && sudo apt install -y "${missing_apt[@]}"
    # e.g. R CMD javareconf, so that R finds the Java just installed (rJava)
    grep '^POST ' "$list" | cut -d' ' -f2- | while read -r command; do sudo $command; done
  fi
else
  echo "Install these system packages with the package manager of this system:"
  printf '  %s\n' "${missing_apt[@]}"
fi

# 2. R packages
mapfile -t missing_r < <(awk '$1 == "R" && $2 != "" {print $2}' "$list")
if [ ${#missing_r[@]} -eq 0 ]; then
  echo "R packages: all installed"
else
  echo "R packages not installed (${#missing_r[@]}):"
  printf '  %s\n' "${missing_r[@]}" | column -c 80
  if yes_no "Install them (into $R_LIBS_USER)?"; then
    # system packages are handled above, so pak does not try to run sudo itself
    Rscript -e 'options(pkg.sysreqs = FALSE); pak::pkg_install(commandArgs(TRUE), ask = FALSE, lib = Sys.getenv("R_LIBS_USER"))' "${missing_r[@]}"
  fi
fi

# 3. the repository's own package
if [ -n "$description" ]; then
  own=$(awk -F': *' '$1 == "Package" {print $2}' "$description")
  if yes_no "Install $own itself from $(dirname "$description")?"; then
    Rscript -e 'options(pkg.sysreqs = FALSE); pak::local_install(commandArgs(TRUE)[1], dependencies = FALSE, ask = FALSE, lib = Sys.getenv("R_LIBS_USER"))' "$(dirname "$description")"
  fi
fi
