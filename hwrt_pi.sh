#!/bin/bash
# hwrt.sh for a Raspberry Pi: RAM, CPU and GPU speed, temperatures, the power
# supply (under-voltage, throttling) and the fan, refreshed every 5 seconds.
# Uses vcgencmd when it is there (Raspberry Pi OS); without it, what /sys gives.

# a line of 80 # characters, between the sections
separator() { printf '#%.0s' {1..80}; printf '\n'; }

# one line in three aligned columns: name, reading, details
row() { printf "%-15s %10s   %s\n" "$1" "$2" "$3"; }

# vcgencmd only if it is installed and allowed (the user must be in the video group)
vc=""
if command -v vcgencmd > /dev/null && vcgencmd version > /dev/null 2>&1; then
	vc=vcgencmd
fi

model=$([ -r /proc/device-tree/model ] && tr -d '\0' < /proc/device-tree/model)
cores=$(nproc)
cpu_max=$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2> /dev/null || echo 0) / 1000 ))

# beep when less than 10% of the RAM is available (a Pi has 1 to 16 GB)
total=$(free -m | awk '/^Mem:/{print $2}')
ram_min=$(( total / 10 ))

# a clock of vcgencmd in MHz: clock arm, clock core
clock() { $vc measure_clock "$1" 2> /dev/null | awk -F= '{printf "%d", $2 / 1000000}'; }

# what vcgencmd get_throttled means, in words; the first 4 bits are "now",
# the same 4 bits 16 places higher are "has happened since the Pi started"
power_status() {
	local value now=() before=()
	value=$($vc get_throttled 2> /dev/null | cut -d= -f2)
	[ -z "$value" ] && return
	value=$((value))
	(( value & 0x1 ))     && now+=("UNDER-VOLTAGE")
	(( value & 0x2 ))     && now+=("speed capped")
	(( value & 0x4 ))     && now+=("throttled")
	(( value & 0x8 ))     && now+=("temperature limit")
	(( value & 0x10000 )) && before+=("under-voltage")
	(( value & 0x20000 )) && before+=("speed capped")
	(( value & 0x40000 )) && before+=("throttled")
	(( value & 0x80000 )) && before+=("temperature limit")
	if [ ${#now[@]} -eq 0 ]; then
		row "Power" "OK" ""
	else
		row "Power" "PROBLEM" "now: $(IFS=,; echo "${now[*]}" | sed 's/,/, /g')"
	fi
	[ ${#before[@]} -gt 0 ] && row "" "" "since start: $(IFS=,; echo "${before[*]}" | sed 's/,/, /g')"
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

check_packages 'speaker-test:alsa-utils:low-RAM alarm'

# the screen is cleared only once; after that each refresh is written over the
# previous one, so it does not flash
tput civis                                  # hide the cursor
trap 'tput cnorm; echo; exit' INT TERM      # and bring it back on Ctrl+C
clear

while :
do
	available=$(free -m | awk '/^Mem:/{print $7}')

	# the whole screen is collected first and printed at once
	screen=$({
	separator
	echo "AVAILABLE RAM : $available MB of $total MB"
	separator

	# speeds
	if [ -n "$vc" ]; then
		cpu_now=$(clock arm)
	else
		cpu_now=$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2> /dev/null || echo 0) / 1000 ))
	fi
	row "CPU" "$cpu_now MHz" "max $cpu_max MHz, $cores cores${model:+, $model}"
	if [ -n "$vc" ]; then
		gpu_mem=$($vc get_mem gpu 2> /dev/null | cut -d= -f2)
		row "GPU" "$(clock core) MHz" "VideoCore${gpu_mem:+, memory $gpu_mem}"
	fi
	separator

	# temperatures: the chip (CPU and GPU are one chip), and on a Pi 5 the power chip
	for zone in /sys/class/thermal/thermal_zone*; do
		[ -r "$zone/temp" ] || continue
		row "$(cat "$zone/type")" "$(awk '{printf "+%.1f°C", $1 / 1000}' "$zone/temp")" "slows down at 80°C, hard limit 85°C"
	done
	if [ -n "$vc" ]; then
		pmic=$($vc measure_temp pmic 2> /dev/null | grep -o "[0-9.]*")
		[ -n "$pmic" ] && row "Power chip" "+${pmic}°C" ""
		row "Core voltage" "$($vc measure_volts core 2> /dev/null | cut -d= -f2)" ""
		power_status
	fi
	separator

	# fans: the official Pi 5 fan, or any other one the kernel knows about
	fans=0
	for fan in /sys/class/hwmon/hwmon*/fan*_input; do
		[ -r "$fan" ] || continue
		row "$(cat "$(dirname "$fan")/name") $(basename "$fan" _input)" "$(cat "$fan") RPM" ""
		fans=$((fans + 1))
	done
	[ $fans -eq 0 ] && echo "no fan"
	separator
	})

	# back to the top, each line cleared to its end, then anything left below
	tput cup 0 0
	while IFS= read -r line; do printf '%s\e[K\n' "$line"; done <<< "$screen"
	tput ed

	# a Pi often has no speakers, so the terminal bell (also works over ssh),
	# and a tone in case there are
	if [[ "$available" -lt "$ram_min" ]]
	then
		printf '\a'
		timeout 1 speaker-test -t sine -f 1000 > /dev/null 2>&1
	fi
	sleep 5
done
