# Runs R CMD check on every R package in Documents\GitHub (or the folder given), one
# after the other, and reports which packages have errors, warnings or notes, and which
# checks gave them. The repositories are not changed: each package is built and checked in
# %LOCALAPPDATA%\r_cmd_check_all, where the logs stay until the next run.
#   r_cmd_check.ps1 [folder] [package ...]   every package, or only the ones named
#   r_cmd_check.ps1 -AsCran                  as CRAN checks a submission
#   r_cmd_check.ps1 -Manual                  also the PDF manual (needs LaTeX, e.g. MiKTeX)
# A package is a folder with a DESCRIPTION: a repository, or a folder in one (rwf\rwf).
# Suggested packages that are not installed do not stop a check, and the tests skipped on
# CRAN run, unless -AsCran (r_install_packages.ps1 installs what a package needs). A package
# with C/C++ code needs Rtools to build. The exit code is 1 if any package has errors.

param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Names,
  [switch]$AsCran,
  [switch]$Manual
)

# anything but y/yes is no
function Test-Yes([string]$question) {
  $answer = Read-Host "$question [y/N]"
  return $answer -match '^\s*y(es)?\s*$'
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

# the first argument that is an existing folder is the folder, the others are packages
$Root = $null; $only = @()
foreach ($arg in $Names) {
  if ($arg -like '-*') { Write-Host "Unknown option: $arg"; exit 1 }
  $path = $arg.Trim().Trim('"') -replace '^~', $HOME
  if (-not $Root -and (Test-Path -LiteralPath $path -PathType Container)) {
    $Root = $path
  } else {
    $only += $arg
  }
}

# the folder given, or Documents\GitHub (where GitHub Desktop puts the repositories), or ~\GitHub
if (-not $Root) {
  $Root = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'GitHub'
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { $Root = Join-Path $HOME 'GitHub' }
}
# ask for the folder until one that exists is given (~ works, and the quotes of "Copy as path")
while (-not (Test-Path -LiteralPath $Root -PathType Container)) {
  Write-Host "Folder not found: $Root"
  $Root = Read-Host 'Folder with the repositories (empty to quit)'
  if (-not $Root) { exit 1 }
  $Root = $Root.Trim().Trim('"') -replace '^~', $HOME
}
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')

# R is needed, so without it it stops
$rscript = Find-Rscript
if (-not $rscript) {
  Write-Host 'Missing:'
  Write-Host ('  {0,-14} {1,-26} package {2}' -f 'Rscript', '(runs R CMD check)', 'RProject.R')
  if ((Get-Command winget -ErrorAction SilentlyContinue) -and (Test-Yes 'Install it now with winget install RProject.R?')) {
    winget install --id RProject.R --exact --source winget
    $rscript = Find-Rscript
  } else {
    Write-Host 'Install it from https://cran.r-project.org/ or with: winget install RProject.R'
  }
  if (-not $rscript) { exit 1 }
}
# R CMD runs through R.exe, which sits next to Rscript.exe
$r = Join-Path (Split-Path -Parent $rscript) 'R.exe'
if (-not (Test-Path -LiteralPath $r)) { $r = Join-Path (Split-Path -Parent $rscript) 'R' }

# the PDF manual needs LaTeX; without it the check goes on and reports the manual
if ($Manual -and -not (Get-Command pdflatex -ErrorAction SilentlyContinue)) {
  Write-Host 'Missing:'
  Write-Host ('  {0,-14} {1,-26} package {2}' -f 'pdflatex', '(the PDF manual)', 'MiKTeX.MiKTeX')
  if ((Get-Command winget -ErrorAction SilentlyContinue) -and (Test-Yes 'Install it now with winget install MiKTeX.MiKTeX?')) {
    winget install --id MiKTeX.MiKTeX --exact --source winget
    Write-Host 'Open a new PowerShell window for pdflatex to be found.'
  } else {
    Write-Host 'Install MiKTeX from https://miktex.org/ or with: winget install MiKTeX.MiKTeX'
  }
}

# the part of a path inside the folder, as rwf\rwf
function Get-Relative([string]$path) {
  if ($path.StartsWith($Root + [IO.Path]::DirectorySeparatorChar)) { return $path.Substring($Root.Length + 1) }
  return $path
}

# the value of a field of a DESCRIPTION file, as Package or Version
function Get-Field([string]$description, [string]$field) {
  foreach ($line in Get-Content -LiteralPath $description) {
    if ($line -match "^${field}:\s*(.*?)\s*$") { return $Matches[1] }
  }
}

# the packages, one folder per package name: a package found twice (a mirror repository,
# e.g. crypto and golemcrypto) is checked in the folder named after it. Package names are
# case-sensitive, so the dictionary is too
$folder_of = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$duplicates = @()
$skip = '^(\.git|renv|venv|\.venv|node_modules|.*\.Rcheck)$'
$descriptions = Get-ChildItem -LiteralPath $Root -Recurse -Depth 2 -Filter DESCRIPTION -File -ErrorAction SilentlyContinue |
  Where-Object { -not ((Get-Relative $_.DirectoryName) -split '[\\/]' | Where-Object { $_ -match $skip }) } |
  Sort-Object FullName
foreach ($description in $descriptions) {
  $dir = $description.DirectoryName
  $name = Get-Field $description.FullName 'Package'
  if (-not $name) { continue }
  if (-not $folder_of.ContainsKey($name)) {
    $folder_of[$name] = $dir
  } elseif ((Split-Path -Leaf $dir) -ceq $name) {
    $duplicates += "$(Get-Relative $folder_of[$name]) (the same package as $(Get-Relative $dir))"
    $folder_of[$name] = $dir
  } else {
    $duplicates += "$(Get-Relative $dir) (the same package as $(Get-Relative $folder_of[$name]))"
  }
}

# the packages named on the command line, by package name or folder name
$selected = @()
foreach ($name in ($folder_of.Keys | Sort-Object)) {
  if ($only.Count -gt 0) {
    $folder = Split-Path -Leaf $folder_of[$name]
    if (-not ($only | Where-Object { $_ -ceq $name -or $_ -ceq $folder })) { continue }
  }
  $selected += $name
}
if ($selected.Count -eq 0) {
  if ($only.Count -gt 0) { Write-Host "No R packages named $($only -join ' ') in $Root" } else { Write-Host "No R packages in $Root" }
  exit 1
}

# XDG_CACHE_HOME first, as git_push_checked.ps1 uses it to give the checks their own folder
$cache = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } elseif ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.cache' }
$out = Join-Path $cache 'r_cmd_check_all'
$check_args = @()
if (-not $Manual) { $check_args += '--no-manual' }
if ($AsCran) { $check_args += '--as-cran' }

# the checks of 00check.log that were not OK, as "LEVEL: what was checked"; an error with
# its last lines (where R's error message is), a warning with its first ones (what it is
# about). A check's level is at the end of its line ("... NOTE", also "... [3s] NOTE"), or
# alone on a line after the tests' lines
function Show-Problems([string]$log) {
  $level = ''; $heading = ''; $lines = New-Object System.Collections.Generic.List[string]
  # prints the lines kept for the check before, and starts again
  $flush = {
    if ($level -eq 'ERROR') {
      $lines | Select-Object -Last 8 | ForEach-Object { Write-Host "        $_" }
    } elseif ($level -eq 'WARNING') {
      $lines | Select-Object -First 4 | ForEach-Object { Write-Host "        $_" }
    }
    $lines.Clear()
  }
  foreach ($line in Get-Content -LiteralPath $log) {
    if ($line -cmatch '^\* ') {
      . $flush; $level = ''
      $heading = $line -creplace '^\* (checking )?', ''
      if ($heading -cmatch ' \.\.\. (\[[^\]]*\] )?(ERROR|WARNING|NOTE)$') {
        $level = $Matches[2]
        $heading = $heading -creplace ' \.\.\. .*', ''
        Write-Host "    ${level}: $heading"
      } else {
        $heading = $heading -creplace ' \.\.\.$', ''
      }
    } elseif ($line -cmatch '^ ?(ERROR|WARNING|NOTE)$') {
      . $flush
      $level = $Matches[1]
      Write-Host "    ${level}: $heading"
    } elseif ($level -and $line.Trim()) {
      $lines.Add($line)
    }
  }
  . $flush
}

# runs R with the arguments given in the folder given, and writes what it prints to a log
# (captured here, as > would write the log as UTF-16 in Windows PowerShell); its exit code
function Invoke-R([string]$folder, [string]$log, [string[]]$arguments) {
  Push-Location -LiteralPath $folder
  try {
    $output = & $r @arguments 2>&1 | ForEach-Object { "$_" }
    $status = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  [IO.File]::WriteAllText($log, (@($output) -join [Environment]::NewLine) + [Environment]::NewLine)
  return $status
}

Write-Host "Checking $($selected.Count) package(s) of $Root; logs in $out"
foreach ($dup in $duplicates) { Write-Host "Skipped $dup" }

# locally a missing suggested package is a note, not an error, and the tests marked
# skip_on_cran() run, as with devtools::check(); -AsCran keeps CRAN's rules. The variables
# are put back afterwards, as a script shares them with the PowerShell window it runs in
$saved = @{ NOT_CRAN = $env:NOT_CRAN; _R_CHECK_FORCE_SUGGESTS_ = $env:_R_CHECK_FORCE_SUGGESTS_ }
if (-not $AsCran) {
  $env:_R_CHECK_FORCE_SUGGESTS_ = 'false'; $env:NOT_CRAN = 'true'
}

$with_errors = @(); $with_warnings = @(); $with_notes = @(); $summary = @()
try {
  foreach ($name in $selected) {
    $dir = $folder_of[$name]
    $work = Join-Path $out $name
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    Write-Host ''
    Write-Host ('#' * 80)
    $version = Get-Field (Join-Path $dir 'DESCRIPTION') 'Version'
    Write-Host "$name $version  ($(Get-Relative $dir))"
    $start = Get-Date

    # the tarball CRAN would get: .Rbuildignore applied, vignettes built
    $build_log = Join-Path $work 'build.log'
    if ((Invoke-R $work $build_log @('CMD', 'build', $dir)) -ne 0) {
      $result = 'build failed'
      $with_errors += $name
      Write-Host "  $result" -ForegroundColor Red -NoNewline
      Write-Host "; the end of ${build_log}:"
      Get-Content -LiteralPath $build_log -Tail 15 | ForEach-Object { Write-Host "    $_" }
    } else {
      $tarball = (Get-ChildItem -LiteralPath $work -Filter '*.tar.gz' | Select-Object -First 1).FullName
      $check_log = Join-Path $work 'check.log'
      Invoke-R $work $check_log (@('CMD', 'check') + $check_args + $tarball) | Out-Null
      $log = Join-Path (Join-Path $work "$name.Rcheck") '00check.log'
      $result = $null
      if (Test-Path -LiteralPath $log) {
        $result = Get-Content -LiteralPath $log | Where-Object { $_ -match '^Status: ' } |
          Select-Object -Last 1 | ForEach-Object { $_ -replace '^Status: ', '' }
      }
      if (-not $result) { $result = 'check did not finish' }
      if ($result -ceq 'OK') {
        Write-Host '  OK' -ForegroundColor Green
      } elseif ($result -clike '*ERROR*' -or $result -eq 'check did not finish') {
        $with_errors += $name; Write-Host "  $result" -ForegroundColor Red
      } elseif ($result -clike '*WARNING*') {
        $with_warnings += $name; Write-Host "  $result" -ForegroundColor Yellow
      } else {
        $with_notes += $name; Write-Host "  $result"
      }
      if ($result -eq 'check did not finish') {
        Get-Content -LiteralPath $check_log -Tail 15 | ForEach-Object { Write-Host "    $_" }
      } elseif ($result -ne 'OK') {
        Show-Problems $log
        Write-Host "    log: $log"
      }
    }
    $seconds = [int]((Get-Date) - $start).TotalSeconds
    $duration = '{0}m{1:00}s' -f [math]::Floor($seconds / 60), ($seconds % 60)
    $summary += '{0,-16} {1,-12} {2,-10} {3}' -f $name, $version, $duration, $result
  }
} finally {
  foreach ($variable in $saved.Keys) {
    if ($null -eq $saved[$variable]) {
      Remove-Item -Path "Env:$variable" -ErrorAction SilentlyContinue
    } else {
      Set-Item -Path "Env:$variable" -Value $saved[$variable]
    }
  }
}

Write-Host ''
Write-Host ('#' * 80)
Write-Host 'Summary'
$summary | ForEach-Object { Write-Host "  $_" }
Write-Host ''
if ($with_errors.Count -gt 0) {
  Write-Host "Errors in $($with_errors.Count):" -ForegroundColor Red -NoNewline
  Write-Host " $($with_errors -join ' ')"
}
if ($with_warnings.Count -gt 0) {
  Write-Host "Warnings in $($with_warnings.Count):" -ForegroundColor Yellow -NoNewline
  Write-Host " $($with_warnings -join ' ')"
}
if ($with_notes.Count -gt 0) {
  Write-Host "Only notes in $($with_notes.Count): $($with_notes -join ' ')"
}
$passed = $selected.Count - $with_errors.Count - $with_warnings.Count - $with_notes.Count
if ($passed -gt 0) { Write-Host "OK: $passed" -ForegroundColor Green }
if ($with_errors.Count -gt 0) { exit 1 }
exit 0
