# shellcheck shell=bash
# The functions that several scripts of this folder share. The scripts load this
# file (it is not run by itself, and it is not on the PATH, like setup/), so a
# change here changes every script that uses the function.

# a line of 80 # characters, between the parts of what a script shows
# (the repositories, packages, machines or steps)
separator() { printf '#%.0s' {1..80}; printf '\n'; }

# offers to install the programs a script needs, when they are missing.
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
