#!/usr/bin/env bash
# Sets up passwordless SSH logins, with your key instead of a password, to every
# machine listed in a text file, ~/.ssh/machines.txt unless another is given.
# Nothing creates that file: make it yourself, with any text editor
#   nano ~/.ssh/machines.txt          (or xed, or code)
# and write one machine per line, as you would type it:
#   # Raspberry Pis
#   ssh dimitrios@192.168.1.10
#   ssh dimitrios@myhost.example.com -p 5000
#   ssh -L 8080:192.168.1.1:80 dimitrios@myhost.example.com -p 1515
#   pi@raspberrypi.local
#   ssh pip0                          (a Host of ~/.ssh/config)
# Empty lines and lines starting with # are skipped. The port is -p (lowercase):
# with -P ssh uses port 22. ssh reads each line itself (ssh -G), so your
# ~/.ssh/config applies, and forwards such as -L are left out. To add a machine
# later, add its line and run the script again: the machines that already work
# are left as they are. The list has no secrets: copy it to your other computers,
# but keep it out of public repositories, and run the script on each computer
# (each one has its own key; never copy a private key).
# It uses the key you already have (~/.ssh/id_ed25519, id_ecdsa or id_rsa, in
# that order, or the one given with --key), and only when there is none it asks
# to create one; a key is never replaced. For each machine it:
#   - checks whether you can already log in without a password; if so the
#     machine is left as it is
#   - otherwise copies your public key with ssh-copy-id, which asks for the
#     password of the machine once, adds the key only if it is missing and sets
#     the permissions of ~/.ssh there
#   - checks that the login now works without a password
#   ssh_setup_keys.sh [file]                default ~/.ssh/machines.txt
#   ssh_setup_keys.sh --key ~/.ssh/id_rsa   copies this key instead
#   ssh_setup_keys.sh --check               only checks which machines need no password
# The exit code is 1 if a machine still asks for a password or cannot be reached.

file=""; key=""; check=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check)   check=1 ;;
    --key)     key=${2:-}; shift ;;
    -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    -*)        echo "Unknown option: $1 (see --help)"; exit 1 ;;
    *)         file=$1 ;;
  esac
  shift
done
file=${file:-$HOME/.ssh/machines.txt}
if [ ! -f "$file" ]; then
  echo "No list of machines: $file"
  echo "Make it with any text editor, for example: nano $file"
  echo "and write one machine per line, as you would type it:"
  echo "  ssh dimitrios@192.168.1.10"
  echo "  ssh dimitrios@myhost.example.com -p 5000"
  echo "(see --help for more)"
  exit 1
fi

red=$'\e[31m'; yellow=$'\e[33m'; green=$'\e[32m'; bold=$'\e[1m'; reset=$'\e[0m'

# a line of 80 # characters, between the machines
separator() { printf '#%.0s' {1..80}; printf '\n'; }

yes_no() {
  local answer
  read -r -p "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

for program in ssh ssh-keygen ssh-copy-id; do
  command -v "$program" > /dev/null || { echo "$program is needed (sudo apt install openssh-client)"; exit 1; }
done

# the key to copy: the one given, or the first one you have
if [ -z "$key" ]; then
  for name in id_ed25519 id_ecdsa id_rsa; do
    [ -f "$HOME/.ssh/$name.pub" ] && [ -f "$HOME/.ssh/$name" ] && { key="$HOME/.ssh/$name"; break; }
  done
fi
key=${key%.pub}
if [ -z "$key" ]; then
  echo "You have no SSH key yet (~/.ssh/id_ed25519, id_ecdsa or id_rsa)."
  if [ $check -eq 1 ] || ! yes_no "Create one now (ssh-keygen -t ed25519)?"; then exit 1; fi
  echo "A passphrase encrypts the key on this computer; with an empty one (Enter) nothing is ever asked."
  ssh-keygen -t ed25519 -C "$USER@$(hostname)" -f "$HOME/.ssh/id_ed25519" || exit 1
  key="$HOME/.ssh/id_ed25519"
elif [ ! -f "$key.pub" ]; then
  echo "No public key $key.pub"; exit 1
fi
echo "Key: $key.pub ($(ssh-keygen -l -f "$key.pub" | awk '{print $2, $NF}'))"
# ssh tries only keys with these names by itself
case "${key##*/}" in
  id_rsa|id_ecdsa|id_ecdsa_sk|id_ed25519|id_ed25519_sk|id_xmss) ;;
  *) echo "${yellow}ssh logs in with this key only when told to: -i $key on the machines' lines, or IdentityFile in ~/.ssh/config${reset}" ;;
esac

# a key with a passphrase logs in without asking only once ssh-agent holds it
if ! ssh-keygen -y -P "" -f "$key" > /dev/null 2>&1; then
  if ssh-add -l 2> /dev/null | grep -qF "$(ssh-keygen -l -f "$key.pub" | awk '{print $2}')"; then
    :
  elif [ -n "${SSH_AUTH_SOCK:-}" ] && [ $check -eq 0 ]; then
    echo "The key has a passphrase: ssh-add asks for it once, so that no login asks for it again"
    ssh-add "$key"
  else
    echo "${yellow}The key has a passphrase and ssh-agent does not hold it: logins will ask for the passphrase${reset}"
  fi
fi
[ $check -eq 1 ] && echo "Check only: no key is copied"

# the parts of a line that matter for logging in (port, user, jump host, identity,
# -o settings), into login_args, and the machine, into destination; forwards
# (-L -R -D), flags such as -N or -t, and a command after the machine are left out
parse_line() {
  local words=() word i=0
  read -r -a words <<< "$1"
  [ "${words[0]}" = ssh ] && words=("${words[@]:1}")
  login_args=(); skipped_args=(); destination=""; port_warning=""
  while [ $i -lt ${#words[@]} ]; do
    word=${words[$i]}
    case "$word" in
      -[DLRWwOQS])           skipped_args+=("$word ${words[$((i + 1))]}"); i=$((i + 2)) ;;
      -[DLRWwOQS]?*)         skipped_args+=("$word"); i=$((i + 1)) ;;
      # -P is a tag for ~/.ssh/config, not the port (that is -p; -P is the port of scp)
      -P)                    [[ "${words[$((i + 1))]}" =~ ^[0-9]+$ ]] && port_warning="-P ${words[$((i + 1))]}"
                             login_args+=("$word" "${words[$((i + 1))]}"); i=$((i + 2)) ;;
      -[BbcEeFIiJlmop])      login_args+=("$word" "${words[$((i + 1))]}"); i=$((i + 2)) ;;
      -[BbcEeFIiJlmop]?*)    login_args+=("$word"); i=$((i + 1)) ;;
      -4|-6)                 login_args+=("$word"); i=$((i + 1)) ;;
      -*)                    i=$((i + 1)) ;;
      *)
        [ -n "$destination" ] && break
        destination=$word; i=$((i + 1)) ;;
    esac
  done
}

# the same options for ssh-copy-id, which takes -p, -F and -o only
copy_args() {
  local i=0 option value
  copy=()
  while [ $i -lt ${#login_args[@]} ]; do
    # -4 and -6 take no value, so that the next option is not taken for theirs
    case "${login_args[$i]}" in
      -4) copy+=(-o AddressFamily=inet); i=$((i + 1)); continue ;;
      -6) copy+=(-o AddressFamily=inet6); i=$((i + 1)); continue ;;
    esac
    option=${login_args[$i]:0:2}; value=${login_args[$i]:2}
    [ -z "$value" ] && { value=${login_args[$((i + 1))]}; i=$((i + 1)); }
    case "$option" in
      -p) copy+=(-p "$value") ;;
      -F) copy+=(-F "$value") ;;
      -o) copy+=(-o "$value") ;;
      -J) copy+=(-o "ProxyJump=$value") ;;
      -l) copy+=(-o "User=$value") ;;
      -i) copy+=(-o "IdentityFile=$value") ;;
    esac
    i=$((i + 1))
  done
}

# whether ssh logs in without asking anything; the error, if not, into login_error.
# ControlPath=none: a connection shared with an earlier login (ControlMaster in
# ~/.ssh/config) would log in without testing the key
logs_in() {
  login_error=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ControlPath=none "${login_args[@]}" "$destination" true 2>&1 < /dev/null)
}

done_machines=(); asks=(); unreachable=(); already=0; set_up=0; line_number=0
declare -A seen=()
# the list is read on descriptor 3, so that ssh-copy-id keeps the terminal for the password
while IFS= read -r line <&3 || [ -n "$line" ]; do
  line_number=$((line_number + 1))
  line=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$line")
  [ -z "$line" ] || [ "${line:0:1}" = "#" ] && continue
  parse_line "$line"
  echo
  separator
  if [ -z "$destination" ] || ! resolved=$(ssh -G "${login_args[@]}" "$destination" 2> /dev/null); then
    echo "${red}line $line_number: not a machine ssh understands: $line${reset}"
    unreachable+=("line $line_number"); continue
  fi
  machine=$(awk '$1 == "user" {u = $2} $1 == "hostname" {h = $2} $1 == "port" {p = $2} END {print u "@" h ":" p}' <<< "$resolved")
  echo "${bold}$machine${reset}  ($line)"
  [ ${#skipped_args[@]} -gt 0 ] && echo "  left out, not needed for the key: ${skipped_args[*]}"
  [ -n "$port_warning" ] && echo "  ${yellow}$port_warning is not a port for ssh, so this is port ${machine##*:}: ssh takes the port with -p (lowercase)${reset}"
  if [ -n "${seen[$machine]:-}" ]; then
    echo "  the same machine as line ${seen[$machine]}"
    continue
  fi
  seen[$machine]=$line_number

  if logs_in; then
    echo "  ${green}already logs in without a password${reset}"
    already=$((already + 1)); done_machines+=("$machine"); continue
  fi
  case "$login_error" in
    *"Permission denied"*|*"Host key verification failed"*|*"No more authentication methods"*) ;;
    *)
      echo "  ${red}cannot reach it: $(tail -n 1 <<< "$login_error")${reset}"
      unreachable+=("$machine"); continue ;;
  esac
  if [ $check -eq 1 ]; then
    if [[ "$login_error" == *"Host key verification failed"* ]]; then
      echo "  ${yellow}not known yet: the first login asks you to confirm its fingerprint${reset}"
    else
      echo "  ${yellow}asks for a password${reset}"
    fi
    asks+=("$machine"); continue
  fi

  echo "  copying your key: ssh-copy-id asks for the password of $machine once"
  copy_args
  if ! ssh-copy-id -i "$key.pub" "${copy[@]}" "$destination"; then
    echo "  ${red}the key could not be copied${reset}"
    asks+=("$machine"); continue
  fi
  if logs_in; then
    echo "  ${green}logs in without a password now${reset}"
    set_up=$((set_up + 1)); done_machines+=("$machine")
  else
    echo "  ${red}still asks for a password: $(tail -n 1 <<< "$login_error")${reset}"
    echo "    the machine may not accept keys (PubkeyAuthentication no in /etc/ssh/sshd_config)"
    asks+=("$machine")
  fi
done 3< "$file"

echo
separator
[ $already -gt 0 ] && echo "${green}Already without a password: $already${reset}"
[ $set_up -gt 0 ] && echo "${green}Without a password now: $set_up${reset}"
[ ${#asks[@]} -gt 0 ] && echo "${yellow}Still ask for a password: ${asks[*]}${reset}"
[ ${#unreachable[@]} -gt 0 ] && echo "${red}Could not reach: ${unreachable[*]}${reset}"
[ ${#asks[@]} -eq 0 ] && [ ${#unreachable[@]} -eq 0 ]
