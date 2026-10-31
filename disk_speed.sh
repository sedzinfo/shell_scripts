#!/bin/bash
# Speed test of every drive, on a PC or a Raspberry Pi (SD card, USB, NVMe):
# reading and writing in MB/s, sequential and random, as CrystalDiskMark does
# (SEQ1M Q8, RND4K Q32, RND4K Q1). Uses fio, and sudo to reach the drives.
# A drive with a mounted filesystem with room is tested with a temporary file on
# it, written, read and deleted. A drive with nothing mounted is only read,
# straight from the drive; nothing is ever written to a drive itself.
#   disk_speed.sh                  every drive
#   disk_speed.sh sda nvme0n1      only these drives
#   disk_speed.sh --list           only list the drives and how each would be tested
#   disk_speed.sh --size 256M      test file size (default 1G); smaller is quicker on SD cards and USB sticks
#   disk_speed.sh --time 10        seconds per test (default 5)
#   disk_speed.sh --read-only      write nothing, only read the drives themselves

args=("$@")
size=1G
seconds=5
list=0
read_only=0
drives=()
while [ $# -gt 0 ]; do
	case "$1" in
		--list)      list=1 ;;
		--read-only) read_only=1 ;;
		--size)      size=$2; shift ;;
		--time)      seconds=$2; shift ;;
		-h|--help)   sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
		-*)          echo "Unknown option: $1 (see --help)"; exit 1 ;;
		*)           drives+=("${1#/dev/}") ;;
	esac
	shift
done
if ! size_bytes=$(numfmt --from=iec "${size^^}" 2> /dev/null) || [ "$size_bytes" -lt 1048576 ]; then
	echo "--size takes a size such as 256M or 1G, not: $size"; exit 1
fi
if ! [[ "$seconds" =~ ^[0-9]+$ ]] || [ "$seconds" -eq 0 ]; then
	echo "--time takes a number of seconds, not: $seconds"; exit 1
fi

# a line of 80 # characters, between the drives
separator() { printf '#%.0s' {1..80}; printf '\n'; }

# one line in three aligned columns: name, reading, details
row() { printf "%-15s %10s   %s\n" "$1" "$2" "$3"; }

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

# whole drives, not their partitions; no CD/DVD drives, RAM disks (zram), empty
# card readers, or the boot areas of eMMC chips
if [ ${#drives[@]} -eq 0 ]; then
	mapfile -t drives < <(lsblk -dn -b -o NAME,TYPE,SIZE |
		awk '$2 == "disk" && $3 > 0 && $1 !~ /^(zram|ram|loop)|boot[0-9]$|rpmb$/ { print $1 }')
fi
for name in "${drives[@]}"; do
	if [ "$(lsblk -dn -o TYPE "/dev/$name" 2> /dev/null)" != disk ]; then
		echo "Not a drive: $name (the names are the ones lsblk shows, such as sda or nvme0n1)"; exit 1
	fi
done
[ ${#drives[@]} -eq 0 ] && { echo "No drives found"; exit 1; }

# NVMe SSD, SSD, hard disk, USB drive, or SD card / eMMC, with the model
describe() {
	local name=$1 kind model
	case "$name" in
		nvme*)   kind="NVMe SSD" ;;
		mmcblk*) kind="SD card / eMMC" ;;
		*)
			if [ "$(lsblk -dn -o TRAN "/dev/$name" | tr -d ' ')" = usb ]; then
				kind="USB drive"
			elif [ "$(lsblk -dn -o ROTA "/dev/$name" | tr -d ' ')" = 1 ]; then
				kind="hard disk"
			else
				kind="SSD"
			fi ;;
	esac
	model=$(lsblk -dn -o MODEL "/dev/$name" | sed 's/ *$//')
	[ -z "$model" ] && model=$(cat "/sys/block/$name/device/name" 2> /dev/null)
	echo "$kind${model:+, $model}"
}

# a column of findmnt (OPTIONS, FSTYPE) for the filesystem in use at a folder;
# when two are mounted on the same folder, the one on top, which findmnt lists last
mount_info() { findmnt -n -o "$1" --target "$2" | tail -1; }

# where the test file goes: of the filesystems mounted from the drive (on any
# partition, also inside LUKS or LVM) the writable one with the most free space,
# if it has room for the file. Prints nothing when there is none.
test_folder() {
	local name=$1 mount best="" best_free=0 free
	while IFS= read -r mount; do
		case "$mount" in ""|"[SWAP]") continue ;; esac
		mount_info OPTIONS "$mount" | grep -qE '(^|,)ro(,|$)' && continue
		free=$(df -B1 --output=avail "$mount" 2> /dev/null | awk 'NR == 2 { print $1 }')
		if [ "${free:-0}" -gt "$best_free" ]; then best=$mount; best_free=$free; fi
	done < <(lsblk -nl -o MOUNTPOINT "/dev/$name")
	if [ -n "$best" ] && [ "$best_free" -gt $(( size_bytes + 100 * 1048576 )) ]; then
		echo "$best"
	fi
}

# how the drive is tested, in words
plan() {
	local name=$1 folder
	if [ "$read_only" -eq 1 ]; then
		echo "read only, from the drive itself"
	elif folder=$(test_folder "$name") && [ -n "$folder" ]; then
		echo "test file on $folder ($(mount_info FSTYPE "$folder"))"
	elif [ -n "$(lsblk -nl -o MOUNTPOINT "/dev/$name" | grep -v '^\[SWAP\]$' | grep .)" ]; then
		echo "read only, from the drive itself (no writable filesystem with room for $size)"
	else
		echo "read only, from the drive itself (nothing mounted)"
	fi
}

if [ "$list" -eq 1 ]; then
	for name in "${drives[@]}"; do
		row "$name" "$(lsblk -dn -o SIZE "/dev/$name" | tr -d ' ')" "$(describe "$name")"
		row "" "" "$(plan "$name")"
	done
	exit 0
fi

check_packages 'fio:fio:the speed tests'
command -v fio > /dev/null || exit 1

# reading a drive directly, and writing on system partitions such as /, needs root
if [ "$EUID" -ne 0 ]; then
	exec sudo "$BASH" "$0" "${args[@]}"
fi

# libaio keeps several requests in flight (the Q8 and Q32 tests); without it
# every request waits for the one before
engine=libaio
fio --enghelp 2>&1 | grep -qw libaio || engine=psync

# the test file is deleted however the script ends, also with Ctrl+C
test_file=""
trap 'rm -f "$test_file"' EXIT
trap 'echo; exit 130' INT TERM

# one test with fio; prints the speed in MB/s, or "failed".
# Arguments: what to read or write (the test file or /dev/...), read/write/
# randread/randwrite, block size, queue depth, then any more fio options
fio_test() {
	local target=$1 rw=$2 block=$3 depth=$4
	shift 4
	# without direct I/O the cache would answer instead of the drive, so it is emptied
	if [ "$direct" -eq 0 ] && [[ "$rw" == *read ]]; then
		sync; echo 3 > /proc/sys/vm/drop_caches
	fi
	fio --name=disk_speed --filename="$target" --size="$test_bytes" --rw="$rw" --bs="$block" \
		--iodepth="$depth" --ioengine="$engine" --direct="$direct" --runtime="$seconds" --time_based \
		--output-format=json "$@" 2> /dev/null |
		awk '/"bw_bytes"/ { gsub(/[^0-9]/, "", $3); if ($3 + 0 > max) max = $3 + 0 }
			END { if (max > 0) printf "%.1f", max / 1e6; else printf "failed" }'
}

# writes the test file, for at most 30 seconds, so a slow drive gets a smaller
# file. fio does not reserve the space first, so the file holds only what was
# written: reading empty space would be faster than reading data.
write_test_file() {
	rm -f "$test_file"
	fio --name=disk_speed --filename="$test_file" --size="$size_bytes" --rw=write --bs=1M --iodepth=8 \
		--ioengine="$engine" --direct="$direct" --fallocate=none --runtime=30 --end_fsync=1 \
		--output-format=json > /dev/null 2>&1 && [ -s "$test_file" ]
}

test_drive() {
	local name=$1 folder="" target how buffered="" readonly_option=() write_option=()
	local test label reading writing block depth
	separator
	row "$name" "$(lsblk -dn -o SIZE "/dev/$name" | tr -d ' ')" "$(describe "$name")"
	direct=1
	[ "$read_only" -eq 0 ] && folder=$(test_folder "$name")
	if [ -n "$folder" ]; then
		test_file="$folder/.disk_speed.$$.tmp"
		row "" "" "writing a test file of up to $size on $folder ..."
		# some filesystems (NTFS and exFAT through FUSE, ZFS) cannot bypass the cache
		if ! write_test_file; then
			direct=0
			buffered=", through the cache (this filesystem has no direct I/O)"
			write_option=(--end_fsync=1)
			if ! write_test_file; then
				row "" "" "could not write a test file on $folder, so it is only read"
				rm -f "$test_file"
				test_file=""
				direct=1
			fi
		fi
	fi

	if [ -n "$test_file" ]; then
		target=$test_file
		test_bytes=$(stat -c %s "$test_file")
		row "" "" "test file of $(( test_bytes / 1048576 )) MB on $folder ($(mount_info FSTYPE "$folder"))$buffered"
	else
		target=/dev/$name
		test_bytes=$(lsblk -dn -b -o SIZE "/dev/$name" | tr -d ' ')
		[ "$test_bytes" -gt "$size_bytes" ] && test_bytes=$size_bytes
		# --readonly: fio refuses to write, whatever the other options say
		readonly_option=(--readonly)
		if [ -n "$folder" ]; then how="read only, from the drive itself"; else how=$(plan "$name"); fi
		row "" "" "$how, the first $(( test_bytes / 1048576 )) MB"
	fi

	printf "%-15s %10s %12s\n" "" "read MB/s" "write MB/s"
	for test in "SEQ1M Q8:read:write:1M:8" "RND4K Q32:randread:randwrite:4k:32" "RND4K Q1:randread:randwrite:4k:1"; do
		IFS=: read -r label reading writing block depth <<< "$test"
		printf "%-15s" "$label"
		printf " %10s" "$(fio_test "$target" "$reading" "$block" "$depth" "${readonly_option[@]}")"
		if [ -n "$test_file" ]; then
			printf " %12s\n" "$(fio_test "$target" "$writing" "$block" "$depth" "${write_option[@]}")"
		else
			printf " %12s\n" "-"
		fi
	done

	if [ -n "$test_file" ]; then
		rm -f "$test_file"
		test_file=""
	fi
}

echo "${#drives[@]} drive(s), $seconds seconds per test; Ctrl+C stops and deletes the test file"
for name in "${drives[@]}"; do
	test_drive "$name"
done
separator
