# shellcheck shell=bash
# The functions that several scripts of this folder share. The scripts load this
# file (it is not run by itself, and it is not on the PATH, like setup/), so a
# change here changes every script that uses the function.

# colours on a terminal, not in a file or the mail of cron
# shellcheck disable=SC2034 # used by the scripts that load this file
if [ -t 1 ]; then
  red=$'\e[31m'; yellow=$'\e[33m'; green=$'\e[32m'; grey=$'\e[90m'; bold=$'\e[1m'; reset=$'\e[0m'
else
  red=''; yellow=''; green=''; grey=''; bold=''; reset=''
fi

# a line of 80 # characters, between the parts of what a script shows
# (the repositories, packages, machines or steps)
separator() { printf '#%.0s' {1..80}; printf '\n'; }

# a number of seconds as minutes and seconds, such as 3m07s
duration() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }

# asks a question; anything but y or yes is no
yes_no() {
  local answer
  read -r -p "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# asks for the folder until one that exists is given, into the variable root (Tab
# completes paths, ~ works, an empty answer quits); the question can be given, such as
# "Folder to clone into"
ask_folder() {
  while [ ! -d "$root" ]; do
    echo "Folder not found: $root"
    read -e -r -p "${1:-Folder with the repositories} (empty to quit): " root || exit 1
    [ -z "$root" ] && exit 1
    root="${root/#\~/$HOME}"
  done
}

# whether a repository or package is one of those asked for: always when none were named
# (the array only is empty), otherwise when one of the names given here (such as a
# package's name and its folder's) is one of them
# shellcheck disable=SC2154 # only is set by the script that loads this file
wanted() {
  local want name
  [ ${#only[@]} -eq 0 ] && return 0
  for want in "${only[@]}"; do
    for name in "$@"; do
      [ "$want" = "$name" ] && return 0
    done
  done
  return 1
}

# the part of a path inside the folder root, as rwf/rwf; the folder's own name when the
# path is that folder itself (when the folder given is a package)
relative() {
  if [ "$1" = "$root" ]; then basename "$1"; else printf '%s\n' "${1#"$root"/}"; fi
}

# the DESCRIPTION files of the R packages in a folder, one per line and sorted: three
# levels deep at most, and not inside .git, renv, venv, .venv, node_modules or *.Rcheck
package_files() {
  find "$1" -maxdepth 3 \
    \( -name .git -o -name '*.Rcheck' -o -name renv -o -name venv -o -name .venv -o -name node_modules \) -prune \
    -o -name DESCRIPTION -type f -print | sort
}

# the name of an R package: the Package field of its DESCRIPTION file, without the \r
# of a file saved on Windows
package_name() {
  awk -F': *' '$1 == "Package" { sub(/[ \t\r]+$/, "", $2); print $2; exit }' "$1"
}

# offers to install the programs a script needs, when they are missing.
# Each argument is program:package:what it is for. It only asks (never installs
# by itself), only once, and only where apt exists; with no, the script goes on
# and shows what it can.
check_packages() {
  local entry program package purpose answer packages=() missing_lines=()
  for entry in "$@"; do
    IFS=: read -r program package purpose <<< "$entry"
    if ! command -v "$program" > /dev/null; then
      packages+=("$package")
      missing_lines+=("$(printf '%-14s %-26s package %s' "$program" "($purpose)" "$package")")
    fi
  done
  [ ${#packages[@]} -eq 0 ] && return 0
  echo "Missing:"
  printf '  %s\n' "${missing_lines[@]}"
  if command -v apt-get > /dev/null && [ -t 0 ]; then
    read -r -p "Install them now with sudo apt install ${packages[*]}? [y/N]: " answer
    if [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
      sudo apt install -y "${packages[@]}"
    fi
  else
    echo "Install them with the package manager of this system: ${packages[*]}"
  fi
}

# runs a function once for each of the arguments, 8 at a time, each in the background,
# and waits for all of them. What runs at the same time writes to files: printed, the
# output of several would be mixed
in_parallel() {
  local fn=$1 arg
  shift
  for arg in "$@"; do
    while [ "$(jobs -rp | wc -l)" -ge 8 ]; do sleep 0.1; done
    "$fn" "$arg" &
  done
  wait
}

# fetches the repositories whose folders are given, 8 at a time and without asking
# anything; then, one at a time, those that needed a password, a passphrase or a new
# host key, where ssh and git can ask as usual. fetch_result then tells how each went.
# On a terminal, a line says what is going on meanwhile
fetch_folders=(); fetch_failed=(); fetch_says=()
fetch_all() {
  local i tmp indices=()
  fetch_folders=("$@"); fetch_failed=(); fetch_says=()
  [ $# -eq 0 ] && return 0
  tmp=$(mktemp -d) || return 1
  _fetch_into=$tmp
  for ((i = 0; i < $#; i++)); do indices+=("$i"); done
  [ -t 2 ] && printf 'Fetching %s repositories ...' "$#" >&2
  in_parallel _fetch_quietly "${indices[@]}"
  [ -t 2 ] && printf '\r\033[K' >&2
  for ((i = 0; i < $#; i++)); do
    if [ -e "$tmp/$i.failed" ] &&
       grep -qE 'Permission denied|Host key verification failed|terminal prompts disabled|could not read (Username|Password)' "$tmp/$i"; then
      # again, on its own, where ssh or git can ask
      git -C "${fetch_folders[i]}" fetch -q 2> "$tmp/$i" && rm -f "$tmp/$i.failed"
    fi
    fetch_says[i]=$(cat "$tmp/$i")
    [ -e "$tmp/$i.failed" ] && fetch_failed[i]=1
  done
  rm -rf "$tmp"
}

# in the background for fetch_all: the fetch of one repository, asking nothing
_fetch_quietly() {
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes" \
    git -C "${fetch_folders[$1]}" fetch -q 2> "$_fetch_into/$1" || : > "$_fetch_into/$1.failed"
}

# how fetch_all went for a folder: sets fetched (1, or 0 when the fetch failed or the
# folder was not given) and fetch_said (what git printed: errors, warnings)
# shellcheck disable=SC2034 # fetched and fetch_said are for the scripts
fetch_result() {
  local i
  fetched=0; fetch_said="not fetched"
  for i in "${!fetch_folders[@]}"; do
    [ "${fetch_folders[$i]}" = "$1" ] || continue
    fetch_said=${fetch_says[$i]}
    [ -n "${fetch_failed[$i]:-}" ] || fetched=1
    return 0
  done
}
