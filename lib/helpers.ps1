# The functions that several scripts of this folder share. The scripts load this file
# (it is not run by itself, and it is not on the PATH, like setup\), so a change here
# changes every script that uses the function.

# anything but y/yes is no
function Test-Yes([string]$question) {
  $answer = Read-Host "$question [y/N]"
  return $answer -match '^\s*y(es)?\s*$'
}

# minutes and seconds since a time
function Get-Duration([datetime]$since) {
  $seconds = [int]((Get-Date) - $since).TotalSeconds
  return '{0}m{1:00}s' -f [math]::Floor($seconds / 60), ($seconds % 60)
}

# installs a missing program with winget, without asking (its installer may ask for
# administrator approval). A new program is on the PATH of new windows only: this one gets
# it too. Nothing happens where winget is missing
function Install-Program([string]$package) {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return }
  Write-Host "Installing $package with winget ..."
  winget install --id $package --exact --source winget --silent --accept-package-agreements --accept-source-agreements
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

# Rscript: on the PATH, or where the R installer put it, as it does not add R to the PATH
function Find-Rscript {
  $command = Get-Command Rscript -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  foreach ($key in 'HKCU:\SOFTWARE\R-core\R', 'HKLM:\SOFTWARE\R-core\R') {
    $path = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).InstallPath
    if ($path -and (Test-Path -LiteralPath "$path\bin\Rscript.exe")) { return "$path\bin\Rscript.exe" }
  }
  # the newest R in Program Files
  Get-ChildItem "$env:ProgramFiles\R\R-*\bin\Rscript.exe" -ErrorAction SilentlyContinue |
    Sort-Object { [version]($_.Directory.Parent.Name -replace '^R-', '' -replace '[^0-9.]', '') } |
    Select-Object -Last 1 -ExpandProperty FullName
}

# the value of a field of a DESCRIPTION file, as Package or Version; with several fields,
# that of the first of them in the file. Names are matched with their capitals, as R does
function Get-Field([string]$description, [string[]]$fields) {
  foreach ($line in Get-Content -LiteralPath $description) {
    foreach ($field in $fields) {
      if ($line -cmatch "^${field}:\s*(.*?)\s*$") { return $Matches[1] }
    }
  }
}

# the part of a path inside the folder $Root of the script, as rwf\rwf; the folder's own
# name when the folder itself is the package
function Get-Relative([string]$path) {
  if ($path.StartsWith($Root + [IO.Path]::DirectorySeparatorChar)) { return $path.Substring($Root.Length + 1) }
  if ($path -eq $Root) { return Split-Path $path -Leaf }
  return $path
}
