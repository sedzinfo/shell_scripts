#!/usr/bin/env bash
# Runs a command on every machine of your list (~/.ssh/machines.txt, the list of
# ssh_setup_keys.sh, with the same format), and shows what each machine printed
# and whether the command worked there:
#   ssh_run_all.sh 'sudo apt update && sudo apt full-upgrade -y'
#   ssh_run_all.sh 'df -h /'
#   ssh_run_all.sh uptime
# It shows the command and the machines, and asks before running it. One machine
# after the other (the default) the command can ask you things, such as the
# password of sudo or a question of apt; with --parallel all machines run at the
# same time and nothing can be asked (a sudo that needs a password fails), and
# what each machine printed is shown when all are done. The logins must not ask
# for a password: ssh_setup_keys.sh sets that up, and a machine that asks is
# skipped.
#   ssh_run_all.sh [options] command      (the options before the command)
#   --list ~/servers.txt   another list of machines
#   --parallel             all machines at the same time
#   --yes                  runs without asking first
# What each machine printed stays in ~/.cache/ssh_run_all until the next run.
# The exit code is 1 if the command failed on a machine or a machine could not
# be reached.

file="$HOME/.ssh/machines.txt"; parallel=0; yes=0; command_words=()
# the options come first; from the first other word on, everything is the command
# (ssh_run_all.sh df -h / runs df -h /)
while [ $# -gt 0 ]; do
  if [ ${#command_words[@]} -gt 0 ]; then
    command_words+=("$1"); shift; continue
  fi
  case "$1" in
    --list)     file=${2:-}; shift ;;
    --parallel) parallel=1 ;;
    --yes)      yes=1 ;;
    -h|--help)  sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    --)         shift; command_words+=("$@"); break ;;
    -*)         echo "Unknown option: $1 (see --help)"; exit 1 ;;
    *)          command_words+=("$1") ;;
  esac
  shift
done
command="${command_words[*]}"
if [ -z "$command" ]; then
  echo "Which command? For example: ssh_run_all.sh 'df -h /'  (see --help)"; exit 1
fi
if [ ! -f "$file" ]; then
  echo "No list of machines: $file (ssh_setup_keys.sh --help says how to write it)"; exit 1
fi

red=$'\e[31m'; yellow=$'\e[33m'; green=$'\e[32m'; bold=$'\e[1m'; reset=$'\e[0m'

# a line of 80 # characters, between the machines
separator() { printf '#%.0s' {1..80}; printf '\n'; }

yes_no() {
  local answer
  read -r -p "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# the parts of a line that matter for logging in (port, user, jump host, identity,
# -o settings), into login_args, and the machine, into destination; forwards
# (-L -R -D), flags such as -N or -t, and a command after the machine are left out
# (the same as in ssh_setup_keys.sh)
parse_line() {
  local words=() word i=0
  read -r -a words <<< "$1"
  [ "${words[0]}" = ssh ] && words=("${words[@]:1}")
  login_args=(); destination=""
  while [ $i -lt ${#words[@]} ]; do
    word=${words[$i]}
    case "$word" in
      -[DLRWwOQS])           i=$((i + 2)) ;;
      -[DLRWwOQS]?*)         i=$((i + 1)) ;;
      -[BbcEeFIiJlmopP])     login_args+=("$word" "${words[$((i + 1))]}"); i=$((i + 2)) ;;
      -[BbcEeFIiJlmopP]?*)   login_args+=("$word"); i=$((i + 1)) ;;
      -4|-6)                 login_args+=("$word"); i=$((i + 1)) ;;
      -*)                    i=$((i + 1)) ;;
      *)
        [ -n "$destination" ] && break
        destination=$word; i=$((i + 1)) ;;
    esac
  done
}

# the machines of the list, each once, as user@host:port
lines=(); labels=(); line_number=0
declare -A seen=()
while IFS= read -r line || [ -n "$line" ]; do
  line_number=$((line_number + 1))
  line=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$line")
  [ -z "$line" ] || [ "${line:0:1}" = "#" ] && continue
  parse_line "$line"
  if [ -z "$destination" ] || ! resolved=$(ssh -G "${login_args[@]}" "$destination" 2> /dev/null); then
    echo "${yellow}line $line_number is not a machine ssh understands, skipped: $line${reset}"; continue
  fi
  label=$(awk '$1 == "user" {u = $2} $1 == "hostname" {h = $2} $1 == "port" {p = $2} END {print u "@" h ":" p}' <<< "$resolved")
  [ -n "${seen[$label]:-}" ] && continue
  seen[$label]=1
  lines+=("$line"); labels+=("$label")
done < "$file"
if [ ${#lines[@]} -eq 0 ]; then
  echo "No machines in $file"; exit 1
fi

echo "Command:  ${bold}$command${reset}"
echo "Machines: ${labels[*]}"
[ $parallel -eq 1 ] && echo "All at the same time (--parallel): the command cannot ask anything"
if [ $yes -eq 0 ]; then
  if [ ! -t 0 ]; then
    echo "Not a terminal, so nothing can be asked: add --yes to run it"; exit 1
  fi
  yes_no "Run it on these ${#lines[@]} machines?" || { echo "Nothing was run"; exit 0; }
fi

logs="${XDG_CACHE_HOME:-$HOME/.cache}/ssh_run_all"
rm -rf "$logs"; mkdir -p "$logs"

# runs the command on machine number $1, with what it prints in its log; the
# exit code is the command's, or 255 when ssh could not log in
run_on() {
  local index=$1 tty=(-T)
  parse_line "${lines[$index]}"
  [ $parallel -eq 0 ] && [ -t 0 ] && tty=(-t)
  ssh "${tty[@]}" -o BatchMode=yes -o ConnectTimeout=10 "${login_args[@]}" "$destination" "$command"
}

# file name of a machine's log
log_of() { echo "$logs/${1//\//_}.log"; }

# what happened on a machine, from its exit code and log
ok=(); failed=(); asks=(); unreachable=()
outcome() {
  local label=$1 status=$2 seconds=$3 log
  log=$(log_of "$label")
  if [ "$status" -eq 0 ]; then
    echo "  ${green}done in ${seconds}s${reset}"; ok+=("$label")
  elif [ "$status" -eq 255 ] && grep -qE "Permission denied|No more authentication methods" "$log"; then
    echo "  ${yellow}asks for a password: skipped (ssh_setup_keys.sh sets up the key)${reset}"; asks+=("$label")
  elif [ "$status" -eq 255 ] && grep -q "Host key verification failed" "$log"; then
    echo "  ${yellow}not known yet: log in once with ssh to confirm its fingerprint${reset}"; unreachable+=("$label")
  elif [ "$status" -eq 255 ] && grep -qE "^ssh: |Connection (timed out|refused|closed)" "$log"; then
    echo "  ${red}cannot reach it: $(grep -E "^ssh: |Connection" "$log" | tail -n 1 | tr -d '\r')${reset}"; unreachable+=("$label")
  else
    echo "  ${red}failed with exit code $status, after ${seconds}s${reset}"; failed+=("$label ($status)")
  fi
}

if [ $parallel -eq 0 ]; then
  for i in "${!lines[@]}"; do
    echo
    separator
    echo "${bold}${labels[$i]}${reset}"
    start=$SECONDS
    # in a terminal the command can ask you things; otherwise it reads nothing
    if [ -t 0 ]; then
      run_on "$i" 2>&1 | tee "$(log_of "${labels[$i]}")"
    else
      run_on "$i" 2>&1 < /dev/null | tee "$(log_of "${labels[$i]}")"
    fi
    status=${PIPESTATUS[0]}
    outcome "${labels[$i]}" "$status" $((SECONDS - start))
  done
else
  declare -A pid_of=() started=()
  for i in "${!lines[@]}"; do
    run_on "$i" > "$(log_of "${labels[$i]}")" 2>&1 < /dev/null &
    pid_of[$!]=$i; started[$i]=$SECONDS
  done
  echo "Running on ${#lines[@]} machines..."
  declare -A status_of=() seconds_of=()
  for _ in "${!lines[@]}"; do
    wait -n -p done_pid; status=$?
    i=${pid_of[$done_pid]}
    status_of[$i]=$status; seconds_of[$i]=$((SECONDS - ${started[$i]}))
    echo "  ${labels[$i]} finished ($((${#status_of[@]})) of ${#lines[@]})"
  done
  for i in "${!lines[@]}"; do
    echo
    separator
    echo "${bold}${labels[$i]}${reset}"
    cat "$(log_of "${labels[$i]}")"
    outcome "${labels[$i]}" "${status_of[$i]}" "${seconds_of[$i]}"
  done
fi

echo
separator
[ ${#ok[@]} -gt 0 ] && echo "${green}Done on: ${ok[*]}${reset}"
[ ${#failed[@]} -gt 0 ] && echo "${red}Failed on: ${failed[*]}${reset}"
[ ${#asks[@]} -gt 0 ] && echo "${yellow}Ask for a password, skipped: ${asks[*]}${reset}"
[ ${#unreachable[@]} -gt 0 ] && echo "${red}Could not reach: ${unreachable[*]}${reset}"
echo "What each machine printed: $logs"
[ ${#failed[@]} -eq 0 ] && [ ${#unreachable[@]} -eq 0 ]
