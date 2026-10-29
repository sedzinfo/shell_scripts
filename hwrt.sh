#!/bin/bash
# a line of 80 # characters, between the sections
separator() { printf '#%.0s' {1..80}; printf '\n'; }

# the temperature or fan lines of sensors in three aligned columns:
# name, reading, limits (the limits' own continuation lines go under the limits)
sensors_table() {
	awk -v unit="$1" '
		$0 !~ unit { next }
		/^[ \t]/ { extra = $0; gsub(/^[ \t(]+|[)]$/, "", extra); printf "%-15s %10s   %s\n", "", "", extra; next }
		{
			label = $0; sub(/:.*/, "", label)
			rest = $0; sub(/^[^:]*:[ \t]*/, "", rest)
			value = rest; sub(/[ \t]*\(.*/, "", value); sub(/[ \t]+$/, "", value)
			extra = ""; if (match(rest, /\(.*\)/)) extra = substr(rest, RSTART + 1, RLENGTH - 2)
			gsub(/  +/, " ", extra)
			printf "%-15s %10s   %s\n", label, value, extra
		}'
}

# the Intel graphics (i915 driver): its folder in /sys, if there is one
intel_gpu=""
for card in /sys/class/drm/card[0-9]; do
	if [ "$(basename "$(readlink "$card/device/driver")")" = "i915" ]; then
		intel_gpu=$card
		break
	fi
done
intel_name=$(lspci 2> /dev/null | grep -iE "vga|display" | grep -i intel | sed 's/.*Intel Corporation //; s/ (rev.*//' | head -1)

# how busy the Intel graphics were since the last refresh: rc6 counts the
# milliseconds the chip spent idle, so busy = 100 - idle share of the time.
# It sets $busy (not printed, so the values of the last refresh are kept)
intel_busy() {
	local idle_now time_now
	busy=""
	idle_now=$(cat "$intel_gpu/gt/gt0/rc6_residency_ms" 2> /dev/null) || return
	time_now=$(date +%s%3N)
	if [ -n "$idle_before" ] && [ "$time_now" -gt "$time_before" ]; then
		busy=$(( 100 - (idle_now - idle_before) * 100 / (time_now - time_before) ))
		[ "$busy" -lt 0 ] && busy=0
	fi
	idle_before=$idle_now; time_before=$time_now
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

check_packages 'sensors:lm-sensors:temperatures and fans' \
	'speaker-test:alsa-utils:low-RAM alarm' \
	'lspci:pciutils:the name of the GPU'

# the screen is cleared only once; after that each refresh is written over the
# previous one, so it does not flash
tput civis                                  # hide the cursor
trap 'tput cnorm; echo; exit' INT TERM      # and bring it back on Ctrl+C
clear

while :
do
	#celsius1=$(cat /sys/class/thermal/thermal_zone0/temp | sed 's/.\{3\}$/.&/')
	#\\t TEMPERATURE : $celsius1 \\n
	free=$(free -m|awk '/^Mem:/{print $4}')
	total=$(free -m|awk '{print $2}' | awk 'END{print}')
	available=$(free -m | awk '/^Mem:/{print $7}')
	cpu_speed=$(lscpu | grep MHz)
	# only on machines with an NVIDIA card (nvidia-smi installed and working)
	gpu_status=""
	if command -v nvidia-smi > /dev/null; then
		gpu_status=$(nvidia-smi 2> /dev/null | grep % | awk '{print $3}')
	fi
	sensors_output=$(sensors 2> /dev/null)
	cpu_temperature=$(sensors_table '°C' <<< "$sensors_output")
	cpu_fan=$(sensors_table 'RPM' <<< "$sensors_output")
	[ -n "$intel_gpu" ] && intel_busy

	# the whole screen is collected first and printed at once
	screen=$({
	separator
	echo "AVAILABLE RAM : $available MB"
	separator
	echo "$cpu_speed"
	separator
	if [ -n "$intel_gpu" ]; then
		printf "%-15s %10s   %s\n" "Intel GPU" "$(cat "$intel_gpu/gt_act_freq_mhz") MHz" \
			"busy ${busy:-..}%, max $(cat "$intel_gpu/gt_max_freq_mhz") MHz, ${intel_name}"
	fi
	if [ -n "$gpu_status" ]; then
		echo GPU: $gpu_status
	fi
	if [ -n "$intel_gpu" ] || [ -n "$gpu_status" ]; then
		separator
	fi
	echo "$cpu_temperature"
	separator
	echo "$cpu_fan"
	separator
	})

	# back to the top, each line cleared to its end, then anything left below
	tput cup 0 0
	while IFS= read -r line; do printf '%s\e[K\n' "$line"; done <<< "$screen"
	tput ed

	if [[ "$available" -lt 3000 ]]
	then
		speaker-test -t sine -f 20000 -l 1 2> /dev/null
	fi
	sleep 5
done
