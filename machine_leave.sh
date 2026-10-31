#!/usr/bin/env bash
# Before handing back a computer: checks that every repository of yours in
# ~/GitHub is completely on GitHub, then removes, one step at a time and only
# after asking, what would let someone else use your accounts from here:
#   1. your repositories, only the ones that are completely on GitHub
#   2. the SSH keys of this computer that are on your GitHub account
#   3. the GitHub passwords and tokens that git and the GitHub CLI keep
#   4. lines with tokens or keys in ~/.Renviron, ~/.bashrc, ... and the history files
#   5. the shinyapps.io / Posit Connect logins that rsconnect keeps
# Other people's repositories (such as your employer's) and SSH keys that are not
# on your GitHub account are never touched. At the end it lists what only you can
# do on the websites, such as deleting the key from your GitHub account.
#   leave_machine.sh [folder] [user]     default ~/GitHub and sedzinfo
#   leave_machine.sh --check             only the report, nothing is removed

root="$HOME/GitHub"; user="sedzinfo"; check=0; positional=()
for arg in "$@"; do
  [ "$arg" = "--check" ] && check=1 || positional+=("$arg")
done
[ ${#positional[@]} -ge 1 ] && root="${positional[0]/#\~/$HOME}"
[ ${#positional[@]} -ge 2 ] && user="${positional[1]}"

# ask for the folder until one that exists is given (Tab completes paths, ~ works)
while [ ! -d "$root" ]; do
  echo "Folder not found: $root"
  read -e -r -p "Folder with the repositories (empty to quit): " root || exit 1
  [ -z "$root" ] && exit 1
  root="${root/#\~/$HOME}"
done

red=$'\e[31m'; yellow=$'\e[33m'; green=$'\e[32m'; bold=$'\e[1m'; reset=$'\e[0m'

# anything but y/yes is no; with --check nothing is asked, so nothing is removed
yes_no() {
  local answer
  [ $check -eq 1 ] && return 1
  read -r -p "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# a path as shown to you, with ~ for the home folder
short() {
  [[ "$1" == "$HOME"/* ]] && echo "~${1#"$HOME"}" || echo "$1"
}

# files and folders that R, Python and the builds make again (caches, .Rhistory, ...)
remade='(^|/)(\.Rproj\.user|\.Rhistory|\.RData|\.Ruserdata|\.DS_Store|__pycache__|node_modules|venv|\.venv|renv/library|\.quarto|_freeze|_site|[^/]*_cache|[^/]*_files|[^/]*\.Rcheck)/?$'

# what of a repository is not on GitHub, one reason per line (no lines: all of it is)
not_on_github() {
  local n
  # changed files, and new ones except the ones that are made again (empty folders hold nothing)
  n=$(( $(git -C "$1" status --porcelain --untracked-files=no | wc -l) +
        $(git -C "$1" ls-files --others --exclude-standard --directory --no-empty-directory | grep -cvE "$remade") ))
  [ "$n" -gt 0 ] && echo "$n uncommitted"
  # commits of any local branch, not only the current one, that GitHub does not have
  n=$(git -C "$1" rev-list --count --branches --not --remotes=origin)
  [ "$n" -gt 0 ] && echo "$n to push"
  n=$(git -C "$1" stash list | wc -l)
  [ "$n" -gt 0 ] && echo "$n stashed"
}

[ $check -eq 1 ] && echo "--check: only the report, nothing is removed"

#####################################################################
echo "${bold}1. Your repositories in $(short "$root")${reset}"
mine=(); others=()
for dir in "$root"/*/; do
  dir=${dir%/}
  [ -d "$dir/.git" ] || continue
  url=$(git -C "$dir" config --get remote.origin.url)
  # yours: the origin is github.com/USER (GitHub names ignore case)
  if [[ "${url,,}" =~ github\.com[:/]${user,,}/ ]]; then
    mine+=("$dir")
  else
    others+=("$dir")
  fi
done

# all fetched at once (much faster than one by one) and without asking for a
# passphrase; a repository that cannot be fetched cannot be compared with GitHub
unreachable=$(mktemp -d)
trap 'rm -rf "$unreachable"' EXIT
for dir in "${mine[@]}"; do
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes" \
    git -C "$dir" fetch -q --prune origin 2> /dev/null || touch "$unreachable/$(basename "$dir")" &
done
wait

safe=(); kept=0
for dir in "${mine[@]}"; do
  name=$(basename "$dir")
  if [ -e "$unreachable/$name" ]; then
    reasons="could not reach GitHub to compare"
  else
    reasons=$(not_on_github "$dir" | paste -sd ',' - | sed 's/,/, /g')
  fi
  if [ -n "$reasons" ]; then
    kept=$((kept + 1))
    printf '  %-30s %s\n' "$name" "${red}${reasons}${reset}"
    continue
  fi
  safe+=("$dir")
  printf '  %-30s %s\n' "$name" "${green}completely on GitHub${reset}"
  # files that git ignores are not on GitHub either and go with the repository
  mapfile -t ignored < <(git -C "$dir" status --porcelain --ignored | sed -n 's/^!! //p' | grep -vE "$remade")
  if [ ${#ignored[@]} -gt 0 ]; then
    more=""; [ ${#ignored[@]} -gt 3 ] && more=" and $(( ${#ignored[@]} - 3 )) more"
    printf '  %-30s %s\n' "" "${yellow}not in git, deleted with it: ${ignored[*]:0:3}${more}${reset}"
  fi
done
for dir in "${others[@]}"; do
  url=$(git -C "$dir" config --get remote.origin.url)
  if [ -z "$url" ]; then
    printf '  %-30s %s\n' "$(basename "$dir")" "${red}only on this computer (no remote), left alone${reset}"
  else
    # git@github.com:owner/name.git or https://github.com/owner/name.git -> github.com/owner
    owner=$(sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#:#/#; s#/[^/]*$##' <<< "$url")
    printf '  %-30s %s\n' "$(basename "$dir")" "not yours ($owner), left alone"
  fi
done

if [ $kept -gt 0 ]; then
  echo "  ${red}$kept not completely on GitHub: commit, push or drop the stash, then run this again. They are not deleted.${reset}"
fi
unreached=$(ls -A "$unreachable" | wc -l)
if [ "$unreached" -gt 0 ] && [ "$unreached" -eq ${#mine[@]} ]; then
  echo "  GitHub could not be reached at all: if your SSH key has a passphrase, load it first"
  echo "  with ssh-add (or check the internet connection), then run this again."
elif [ "$unreached" -gt 0 ]; then
  echo "  A repository GitHub does not answer for may have been renamed or deleted there."
fi
if [ ${#safe[@]} -gt 0 ] && yes_no "Delete the ${#safe[@]} repositories that are completely on GitHub from this computer?"; then
  for dir in "${safe[@]}"; do
    # anything new since the check above keeps the repository
    if [ -n "$(not_on_github "$dir")" ]; then
      echo "  $(basename "$dir"): changed since the check, kept"
    elif rm -rf -- "$dir"; then
      echo "  $(basename "$dir"): deleted"
    fi
  done
fi

#####################################################################
echo
echo "${bold}2. SSH keys${reset}"
fingerprints=()
# GitHub lists the public keys of every account at github.com/USER.keys, so a
# key of this computer is yours when it is in that list
if ! github_keys=$(curl -fsS --max-time 20 "https://github.com/$user.keys"); then
  echo "  ${yellow}could not get the keys of $user from GitHub, skipped${reset}"
else
  personal=(); other=()
  for pub in "$HOME"/.ssh/*.pub; do
    [ -f "$pub" ] || continue
    read -r _ material _ < "$pub"
    if [ -n "$material" ] && awk '{print $2}' <<< "$github_keys" | grep -qxF -- "$material"; then
      personal+=("${pub%.pub}")
    else
      other+=("$(basename "${pub%.pub}")")
    fi
  done
  echo "  SSH keys on your GitHub account: $(grep -c . <<< "$github_keys"); the ones on this computer:"
  [ ${#personal[@]} -eq 0 ] && echo "  none"
  for key in "${personal[@]}"; do
    fingerprint=$(ssh-keygen -lf "$key.pub" | awk '{print $2}')
    fingerprints+=("$fingerprint")
    echo "  $(short "$key")  $fingerprint"
  done
  [ ${#other[@]} -gt 0 ] && echo "  left alone, not on your GitHub account: ${other[*]}"
  for key in "${personal[@]}"; do
    if yes_no "Delete $(short "$key")? Servers and other sites that use this key stop working from here too"; then
      ssh-add -d "$key" > /dev/null 2>&1     # out of the running ssh-agent as well
      rm -f -- "$key" "$key.pub" && echo "  deleted"
    fi
  done
fi

#####################################################################
echo
echo "${bold}3. GitHub logins kept by git and the GitHub CLI${reset}"
helpers=$(git config --get-regexp '^credential\..*helper$' | cut -d' ' -f2- | paste -sd ',' - | sed 's/,/, /g')
if [ -z "$helpers" ]; then
  echo "  git keeps no passwords here (no credential helper)"
else
  echo "  git keeps passwords and tokens with: $helpers"
  if yes_no "Make git forget the ones for github.com?"; then
    # asks every helper to erase what it has for github.com
    printf 'protocol=https\nhost=github.com\n\n' | git credential reject && echo "  done"
  fi
fi
if ! command -v gh > /dev/null; then
  echo "  the GitHub CLI (gh) is not installed"
elif gh auth status --hostname github.com > /dev/null 2>&1; then
  echo "  the GitHub CLI (gh) is logged in to github.com"
  yes_no "Log it out?" && gh auth logout --hostname github.com
else
  echo "  the GitHub CLI (gh) is not logged in"
fi

#####################################################################
echo
echo "${bold}4. Tokens and keys in settings and history files${reset}"
# GitHub tokens, variables named like a token, key or password (GITHUB_PAT,
# COINMARKETCAP_APIKEY, ...) and the passwords of .netrc; PATH and the like are not
names='([A-Za-z0-9]+_)*(TOKEN|PAT|APIKEY|KEY|SECRET|PASSWORD)(_[A-Za-z0-9]+)*[[:space:]]*='
secret="gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|(^|[^A-Za-z0-9_])$names|(^|[[:space:]])password[[:space:]]+[^[:space:]]"
# a line without its secret, to show
mask() {
  sed -E 's/(=[[:space:]]*["'\'']?).*/\1…/; s/(gh[pousr]_|github_pat_)[A-Za-z0-9_]+/\1…/g; s/(password[[:space:]]+)[^[:space:]]+/\1…/g' | cut -c1-70
}
found=0
for file in ~/.Renviron ~/.Rprofile ~/.bashrc ~/.bash_profile ~/.profile ~/.zshrc ~/.netrc ~/.git-credentials \
  ~/.bash_history ~/.zsh_history ~/.Rhistory ~/.python_history; do
  [ -f "$file" ] || continue
  lines=$(grep -nE -- "$secret" "$file") || continue
  found=1
  count=$(grep -c . <<< "$lines")
  echo "  $(short "$file"):"
  head -10 <<< "$lines" | while IFS=: read -r n text; do
    printf '    line %s: %s\n' "$n" "$(mask <<< "$text")"
  done
  [ "$count" -gt 10 ] && echo "    and $((count - 10)) more"
  if yes_no "  Delete these $count lines from $(short "$file")?"; then
    sed -i --follow-symlinks "$(cut -d: -f1 <<< "$lines" | sed 's/$/d/' | paste -sd ';' -)" "$file" && echo "    deleted"
    # a terminal that is still open writes its own history again when it closes
    [[ "$file" == *history ]] && echo "    in the terminals still open, run: history -c"
  fi
done
[ $found -eq 0 ] && echo "  none found"

#####################################################################
echo
echo "${bold}5. Logins for deploying Shiny apps (rsconnect)${reset}"
accounts=()
for dcf in "${XDG_CONFIG_HOME:-$HOME/.config}"/R/rsconnect/accounts/*/*.dcf; do
  [ -f "$dcf" ] && accounts+=("$dcf")
done
[ ${#accounts[@]} -eq 0 ] && echo "  none"
for dcf in "${accounts[@]}"; do
  account=$(basename "$dcf" .dcf); server=$(basename "$(dirname "$dcf")")
  echo "  $account on $server"
  if yes_no "  Remove it? With it, this computer can deploy and delete the apps of $account"; then
    rm -f -- "$dcf" && echo "    removed"
  fi
done

#####################################################################
echo
echo "${bold}What only you can do, on the websites${reset}"
echo "  - Delete this computer's key from your GitHub account: https://github.com/settings/keys"
for fingerprint in "${fingerprints[@]}"; do echo "      $fingerprint"; done
echo "  - Sign out the other sessions: https://github.com/settings/sessions"
echo "  - Revoke the tokens and apps you no longer use: https://github.com/settings/tokens"
echo "    and https://github.com/settings/applications"
if [ ${#accounts[@]} -gt 0 ]; then
  echo "  - Removing an rsconnect login here does not cancel its token: delete it on the site"
  echo "    too (shinyapps.io: Account > Tokens)"
fi
echo "  - Sign out of GitHub and your other accounts in the browsers, and delete saved passwords"
echo "  - Your own files outside $(short "$root"), such as in Desktop, Documents and Downloads"
[ $kept -gt 0 ] && exit 1
exit 0
