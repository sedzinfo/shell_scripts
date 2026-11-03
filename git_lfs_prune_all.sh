#!/usr/bin/env bash
# Frees disk space in every git repository in ~/GitHub (or the folder given)
# that uses Git LFS. Git LFS keeps in .git/lfs a copy of every version of an
# LFS file it ever downloaded, and git lfs prune deletes the old ones, which
# only old commits need: GitHub keeps every version, and git lfs downloads one
# again when a checkout needs it. First it shows how much each repository would
# free, and deletes nothing until you answer yes. As git lfs prune does, it
# keeps the files of:
#   - the current checkout, the stashes and the other worktrees
#   - the branches with a commit in the last 10 days
#   - the commits not pushed to origin yet
# Before deleting, git asks origin whether it has the versions that commits
# still use (--verify-remote); if one is missing there, nothing of that
# repository is deleted.
#   git_lfs_prune_all.sh [folder] [repository ...]   every repository, or only the ones named
#   git_lfs_prune_all.sh --dry-run                   only shows what would be freed
#   git_lfs_prune_all.sh --yes                       prunes without asking
# Versions that only the reflog still knows (from before a git commit --amend
# or a rebase) are deleted too. A repository with its own LFS storage
# (lfs.storage), which others may share, is skipped. The exit code is 1 if a
# repository could not be pruned.

root="$HOME/GitHub"; dry_run=0; yes=0; only=(); root_given=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --yes)     yes=1 ;;
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

# ask for the folder until one that exists is given (Tab completes paths, ~ works)
while [ ! -d "$root" ]; do
  echo "Folder not found: $root"
  read -e -r -p "Folder with the repositories (empty to quit): " root || exit 1
  [ -z "$root" ] && exit 1
  root="${root/#\~/$HOME}"
done
root=$(cd "$root" && pwd)

red=$'\e[31m'; yellow=$'\e[33m'; green=$'\e[32m'; bold=$'\e[1m'; reset=$'\e[0m'

# a line of 80 # characters, between the repositories
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

# a size as git lfs gives it, in units of 1000 (126 MB, 5.5 GB)
size() {
  awk -v b="$1" 'BEGIN {
    split("B KB MB GB TB", unit, " "); i = 1
    while (b >= 1000 && i < 5) { b /= 1000; i++ }
    if (i == 1) printf "%d B", b; else if (b < 10) printf "%.1f %s", b, unit[i]; else printf "%.0f %s", b, unit[i]
  }'
}

# the bytes of a size as git lfs gives it (126 MB is 126000000)
bytes() { local number=${1% *} unit=${1#* }; numfmt --from=si "$number${unit%B}" 2> /dev/null || echo 0; }

# the bytes of the files in a folder
folder_bytes() { du -sb "$1" 2> /dev/null | cut -f 1; }

check_packages 'git-lfs:git-lfs:Git LFS files'
if ! command -v git-lfs > /dev/null; then
  echo "git lfs is needed to prune"; exit 1
fi

echo "Old Git LFS versions in the repositories of $root"
echo "(the local copies in .git/lfs, which git lfs prune deletes; GitHub keeps every version)"
echo

prune_dirs=(); prune_repos=(); prune_media=(); total=0; checked=0; nothing=0
declare -A seen=()
for dir in "$root"/*/; do
  dir=${dir%/}
  [ -e "$dir/.git" ] || continue
  repo=$(basename "$dir")
  if [ ${#only[@]} -gt 0 ]; then
    wanted=0
    for want in "${only[@]}"; do [ "$want" = "$repo" ] && wanted=1; done
    [ $wanted -eq 1 ] || continue
  fi
  checked=$((checked + 1))

  # where git lfs keeps the copies: .git/lfs/objects, or the folder of
  # lfs.storage; a worktree shares that of its repository
  environment=$(git -C "$dir" lfs env 2> /dev/null)
  media=$(sed -n 's/^LocalMediaDir=//p' <<< "$environment")
  storage=$(sed -n 's/^LocalGitStorageDir=//p' <<< "$environment")
  if [ -z "$media" ] || [ -z "$(find "$media" -type f -print -quit 2> /dev/null)" ]; then
    nothing=$((nothing + 1)); continue
  fi
  [ -n "${seen[$media]:-}" ] && continue
  seen[$media]=1
  if [ "$media" != "$storage/lfs/objects" ]; then
    printf '  %-24s %s\n' "$repo" "${yellow}skipped: its LFS copies are in $media (lfs.storage), which other repositories may share${reset}"
    continue
  fi

  # without the remote prune checks (origin), every copy counts as not pushed
  remote=$(git -C "$dir" config --get lfs.pruneremotetocheck || echo origin)
  if ! git -C "$dir" remote get-url "$remote" > /dev/null 2>&1; then
    printf '  %-24s %s\n' "$repo" "kept: no remote named $remote, so git lfs prune keeps every copy"
    continue
  fi

  read -r count freed < <(git -C "$dir" lfs prune --dry-run 2>&1 |
    sed -n 's/^prune: \([0-9]*\) files\{0,1\} would be pruned (\(.*\)), done\.$/\1 \2/p' | tail -n 1)
  if [ "${count:-0}" -eq 0 ]; then
    nothing=$((nothing + 1)); continue
  fi
  freed=$(bytes "$freed")
  [ "$count" -eq 1 ] && versions="old version" || versions="old versions"
  printf '  %-24s %9s of %9s  (%d %s)\n' "$repo" "$(size "$freed")" "$(size "$(folder_bytes "$media")")" "$count" "$versions"
  prune_dirs+=("$dir"); prune_repos+=("$repo"); prune_media+=("$media")
  total=$((total + freed))
done

if [ $checked -eq 0 ]; then
  echo "No git repositories${only[*]:+ named ${only[*]}} in $root"; exit 1
fi
[ $nothing -gt 0 ] && [ ${#prune_dirs[@]} -gt 0 ] && echo "  nothing to free in $nothing other repositories"
if [ ${#prune_dirs[@]} -eq 0 ]; then
  echo "${green}Nothing to free${reset}"; exit 0
fi
echo
echo "${bold}Total: $(size "$total")${reset}"
if [ $dry_run -eq 1 ]; then
  echo "Dry run: nothing is deleted"; exit 0
fi
if [ $yes -eq 0 ] && ! yes_no "Delete them? Git asks origin first that it has them"; then
  echo "Nothing deleted"; exit 0
fi

freed_total=0; pruned=(); failed=()
for i in "${!prune_dirs[@]}"; do
  dir=${prune_dirs[$i]}; repo=${prune_repos[$i]}; media=${prune_media[$i]}
  echo
  separator
  echo "${bold}$repo${reset}  asking origin, then deleting..."
  before=$(folder_bytes "$media")
  output=$(git -C "$dir" lfs prune --verify-remote 2>&1)
  status=$?
  output=$(tr '\r' '\n' <<< "$output")
  # the last state of each line of progress
  grep -E '^prune: .*done\.$' <<< "$output" | sed 's/^/  /'
  if [ $status -ne 0 ]; then
    if grep -q 'missing on remote' <<< "$output"; then
      echo "  ${red}$(grep -c '^ \* ' <<< "$output") versions are not on origin: nothing deleted${reset}"
      echo "    git lfs push --all origin uploads them"
    else
      grep -v -e '^ \* ' -e '^prune: ' -e '^$' <<< "$output" | tail -n 3 | sed 's/^/  /'
      echo "  ${red}git lfs prune failed: nothing deleted${reset}"
    fi
    failed+=("$repo")
    continue
  fi
  after=$(folder_bytes "$media")
  echo "  ${green}Freed $(size $((before - after))): the LFS copies are now $(size "$after")${reset}"
  freed_total=$((freed_total + before - after))
  pruned+=("$repo")
done

echo
separator
[ ${#pruned[@]} -gt 0 ] && echo "${green}Freed $(size "$freed_total") in ${pruned[*]}${reset}"
[ ${#failed[@]} -gt 0 ] && echo "${red}Not pruned: ${failed[*]}${reset}"
[ ${#failed[@]} -eq 0 ]
