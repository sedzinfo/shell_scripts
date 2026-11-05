# Speed test of every drive: reading and writing in MB/s, sequential and random, as
# CrystalDiskMark does (SEQ1M Q8, RND4K Q32, RND4K Q1). Uses fio, installed with winget when missing.
# A drive with a volume (drive letter) with room is tested with a temporary file on it,
# written, read and deleted. A drive without one is only read, straight from the drive, which
# needs PowerShell run as administrator; nothing is ever written to a drive itself.
#   disk_speed.ps1                every drive
#   disk_speed.ps1 0 1            only these drives (the numbers Get-Disk shows)
#   disk_speed.ps1 -List          only list the drives and how each would be tested
#   disk_speed.ps1 -Size 256M     test file size (default 1G); smaller is quicker on SD cards and USB sticks
#   disk_speed.ps1 -Time 10       seconds per test (default 5)
#   disk_speed.ps1 -ReadOnly      write nothing, only read the drives themselves

param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Drives,
  [switch]$List,
  [string]$Size = '1G',
  [int]$Time = 5,
  [switch]$ReadOnly
)

foreach ($arg in $Drives) {
  if ($arg -like '-*') { Write-Host "Unknown option: $arg"; exit 1 }
}
$units = @{ '' = 1; 'K' = 1KB; 'M' = 1MB; 'G' = 1GB; 'T' = 1TB }
if ($Size -notmatch '^\s*(\d+(?:\.\d+)?)\s*([KMGTkmgt]?)(i?B)?\s*$' -or
    ($size_bytes = [long]([double]$Matches[1] * $units[$Matches[2].ToUpper()])) -lt 1MB) {
  Write-Host "-Size takes a size such as 256M or 1G, not: $Size"; exit 1
}
if ($Time -le 0) { Write-Host "-Time takes a number of seconds, not: $Time"; exit 1 }

if (-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
  Write-Host 'This needs Windows 8 or later (Get-Disk).'; exit 1
}

# a line of 80 # characters, between the drives
function Write-Separator { Write-Host ('#' * 80) }

# one line in three aligned columns: name, reading, details
function Write-Row([string]$name, [string]$value, [string]$details) {
  Write-Host ('{0,-15} {1,10}   {2}' -f $name, $value, $details)
}

# a size as lsblk shows it: 931.5G, 256M
function Format-Bytes([double]$bytes) {
  foreach ($unit in 'T', 'G', 'M', 'K') {
    if ($bytes -ge $units[$unit]) { return ('{0:0.#}' -f ($bytes / $units[$unit])) + $unit }
  }
  return "${bytes}B"
}

# whole drives, not their partitions; no empty card readers or virtual disks (VHD files)
$all = @(Get-Disk | Where-Object { $_.Size -gt 0 -and $_.BusType -ne 'File Backed Virtual' } | Sort-Object Number)
if ($Drives.Count -eq 0) {
  $disks = $all
} else {
  $disks = @()
  foreach ($arg in $Drives) {
    # 1, PhysicalDrive1 or \\.\PhysicalDrive1
    $disk = if ($arg -match '(\d+)$') { $all | Where-Object { $_.Number -eq [int]$Matches[1] } }
    if (-not $disk) { Write-Host "Not a drive: $arg (the numbers are the ones Get-Disk shows, such as 0 or 1)"; exit 1 }
    $disks += $disk
  }
}
if ($disks.Count -eq 0) { Write-Host 'No drives found'; exit 1 }

# NVMe SSD, SSD, hard disk, USB drive, or SD card / eMMC, with the model
function Get-Description($disk) {
  $media = (Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DeviceId -eq "$($disk.Number)" }).MediaType
  $kind = switch ([string]$disk.BusType) {
    'NVMe' { 'NVMe SSD' }
    'SD'   { 'SD card / eMMC' }
    'MMC'  { 'SD card / eMMC' }
    'USB'  { 'USB drive' }
    default { if ($media -eq 'HDD') { 'hard disk' } else { 'SSD' } }
  }
  $model = "$($disk.FriendlyName)".Trim()
  if ($model) { return "$kind, $model" }
  return $kind
}

# the volumes of a drive that have a drive letter, with their free space and file system
function Get-Volumes($disk) {
  Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
    Where-Object { "$($_.DriveLetter)" -match '^[A-Za-z]$' -and -not $_.IsReadOnly } |
    ForEach-Object { Get-Volume -Partition $_ -ErrorAction SilentlyContinue } |
    Where-Object { $_.FileSystem }
}

# where the test file goes: of the volumes of the drive the one with the most free space,
# if it has room for the file. On the Windows drive the user's temporary folder, elsewhere a
# folder of its own, as users may make folders but not files at the top of a drive. Returns
# nothing when there is none
function Get-TestPlace($disk) {
  if ($disk.IsReadOnly) { return }
  $best = Get-Volumes $disk | Sort-Object SizeRemaining -Descending | Select-Object -First 1
  if (-not $best -or $best.SizeRemaining -le $size_bytes + 100MB) { return }
  $letter = "$($best.DriveLetter):"
  $folder = if ((Split-Path -Qualifier $env:TEMP) -eq $letter) { $env:TEMP } else { "$letter\" }
  return [pscustomobject]@{ Volume = "$letter\"; Folder = $folder; FileSystem = $best.FileSystem }
}

# whether this PowerShell runs as administrator, which reading a drive directly needs
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)

# how the drive is tested, in words
function Get-Plan($disk) {
  if ($ReadOnly) { return 'read only, from the drive itself' }
  $place = Get-TestPlace $disk
  if ($place) { return "test file on $($place.Volume) ($($place.FileSystem))" }
  if (Get-Volumes $disk) { return "read only, from the drive itself (no writable volume with room for $Size)" }
  return 'read only, from the drive itself (no volume with a drive letter)'
}

if ($List) {
  foreach ($disk in $disks) {
    Write-Row "$($disk.Number)" (Format-Bytes $disk.Size) (Get-Description $disk)
    Write-Row '' '' (Get-Plan $disk)
  }
  exit 0
}

# fio has a Windows installer, which puts it on the PATH
function Find-Fio {
  $found = (Get-Command fio -ErrorAction SilentlyContinue).Source
  if (-not $found -and (Test-Path -LiteralPath "$env:ProgramFiles\fio\fio.exe")) { $found = "$env:ProgramFiles\fio\fio.exe" }
  return $found
}
$fio = Find-Fio
# missing: installed with winget, which asks for administrator approval. The new PATH reaches
# only new windows, so it is read again here
if (-not $fio -and (Get-Command winget -ErrorAction SilentlyContinue)) {
  Write-Host 'Installing fio (the speed tests) with winget ...'
  & winget install --id fio.fio --exact --silent --accept-package-agreements --accept-source-agreements
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
  $fio = Find-Fio
}
if (-not $fio) {
  Write-Host 'Missing:'
  Write-Host ('  {0,-14} {1,-26} {2}' -f 'fio', '(the speed tests)', 'https://github.com/axboe/fio/releases (fio-<version>-x64.msi)')
  exit 1
}

# a path for fio, which separates file names with colons: C:\x is written C\:\x
function ConvertTo-FioPath([string]$path) { return $path.Replace(':', '\:') }

# one test with fio; the speed in MB/s, or "failed". windowsaio keeps several requests in
# flight (the Q8 and Q32 tests), and is the engine that can bypass the cache (direct I/O)
function Invoke-FioTest([string]$target, [long]$bytes, [string]$rw, [string]$block, [int]$depth, [string[]]$more) {
  $arguments = @('--name=disk_speed', "--filename=$target", "--size=$bytes", "--rw=$rw", "--bs=$block",
    "--iodepth=$depth", '--ioengine=windowsaio', '--direct=1', "--runtime=$Time", '--time_based',
    '--output-format=json') + $more
  $text = (& $fio @arguments 2> $null) -join "`n"
  try {
    $job = ($text.Substring($text.IndexOf('{')) | ConvertFrom-Json).jobs[0]
    $speed = [math]::Max([double]$job.read.bw_bytes, [double]$job.write.bw_bytes)
    if ($speed -gt 0) { return '{0:0.0}' -f ($speed / 1e6) }
  } catch { }
  return 'failed'
}

# the test file and the folder made for it, deleted however the script ends, also with Ctrl+C
$test_file = $null; $made_folder = $null
function Remove-TestFile {
  if ($script:test_file) { Remove-Item -LiteralPath $script:test_file -Force -ErrorAction SilentlyContinue }
  if ($script:made_folder) { Remove-Item -LiteralPath $script:made_folder -Recurse -Force -ErrorAction SilentlyContinue }
  $script:test_file = $null; $script:made_folder = $null
}

# writes the test file, for at most 30 seconds, so a slow drive gets a smaller file. fio does
# not reserve the space first, so the file holds only what was written: reading empty space
# would be faster than reading data
function New-TestFile {
  Remove-Item -LiteralPath $script:test_file -Force -ErrorAction SilentlyContinue
  & $fio --name=disk_speed "--filename=$(ConvertTo-FioPath $script:test_file)" "--size=$size_bytes" --rw=write --bs=1M `
    --iodepth=8 --ioengine=windowsaio --direct=1 --fallocate=none --runtime=30 --end_fsync=1 --output-format=json *> $null
  $file = Get-Item -LiteralPath $script:test_file -ErrorAction SilentlyContinue
  return ($LASTEXITCODE -eq 0 -and $file -and $file.Length -gt 0)
}

function Test-Drive($disk) {
  Write-Separator
  Write-Row "$($disk.Number)" (Format-Bytes $disk.Size) (Get-Description $disk)
  $place = if ($ReadOnly) { $null } else { Get-TestPlace $disk }
  if ($place) {
    if ($place.Folder -eq $place.Volume) {
      $script:made_folder = Join-Path $place.Volume "disk_speed.$PID"
      New-Item -ItemType Directory -Path $script:made_folder -ErrorAction SilentlyContinue | Out-Null
      $folder = $script:made_folder
    } else {
      $folder = $place.Folder
    }
    $script:test_file = Join-Path $folder ".disk_speed.$PID.tmp"
    Write-Row '' '' "writing a test file of up to $Size on $($place.Volume) ..."
    if (-not (New-TestFile)) {
      Write-Row '' '' "could not write a test file on $($place.Volume), so it is only read"
      Remove-TestFile
    }
  }

  $more = @()
  if ($script:test_file) {
    $target = ConvertTo-FioPath $script:test_file
    $bytes = (Get-Item -LiteralPath $script:test_file).Length
    Write-Row '' '' "test file of $([math]::Floor($bytes / 1MB)) MB on $($place.Volume) ($($place.FileSystem))"
  } else {
    if (-not $admin) {
      Write-Row '' '' 'reading the drive itself needs PowerShell run as administrator; skipped'
      return
    }
    $target = "\\.\PhysicalDrive$($disk.Number)"
    $bytes = [math]::Min([long]$disk.Size, $size_bytes)
    # --readonly: fio refuses to write, whatever the other options say
    $more = @('--readonly')
    $how = if ($place) { 'read only, from the drive itself' } else { Get-Plan $disk }
    Write-Row '' '' "$how, the first $([math]::Floor($bytes / 1MB)) MB"
  }

  Write-Host ('{0,-15} {1,10} {2,12}' -f '', 'read MB/s', 'write MB/s')
  foreach ($test in @(@('SEQ1M Q8', 'read', 'write', '1M', 8), @('RND4K Q32', 'randread', 'randwrite', '4k', 32), @('RND4K Q1', 'randread', 'randwrite', '4k', 1))) {
    $reading = Invoke-FioTest $target $bytes $test[1] $test[3] $test[4] $more
    $writing = if ($script:test_file) { Invoke-FioTest $target $bytes $test[2] $test[3] $test[4] @() } else { '-' }
    Write-Host ('{0,-15} {1,10} {2,12}' -f $test[0], $reading, $writing)
  }
  Remove-TestFile
}

Write-Host "$($disks.Count) drive(s), $Time seconds per test; Ctrl+C stops and deletes the test file"
try {
  foreach ($disk in $disks) { Test-Drive $disk }
} finally {
  Remove-TestFile
}
Write-Separator
