# Updates the help pages (man\*.Rd) and NAMESPACE of every R package in Documents\GitHub (or
# the folder given) from their roxygen comments, one after the other, with
# roxygen2::roxygenise() (what devtools::document() does for one package). r_cmd_check.ps1
# uses man\ as it is, so run this first. It reports which packages failed and which files
# changed, to commit and push. It lists the packages and asks first. Nothing is committed or
# pushed.
#   r_document_all.ps1 [folder] [package ...]   every package, or only the ones named
#   r_document_all.ps1 -Check                   only lists the packages whose help pages or
#                                               NAMESPACE are out of date: roxygen runs on a
#                                               copy, nothing is changed
#   r_document_all.ps1 -Yes                     without asking first
# The folder is given as a path (~\GitHub, ., ..\work, C:\work): a plain word is a package.
# A package is a folder with a DESCRIPTION: a repository, or a folder in one (rwf\rwf).
# Mirror repositories with the same package (crypto and golemcrypto) are each documented.
# Packages without roxygen comments are skipped. The exit code is 1 if any failed, or with
# -Check if any is out of date.

param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Names,
  [switch]$Check,
  [switch]$Yes
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

# the folder is given as a path: a plain word is a package, as a package's name may also be a
# folder here
$Root = $null; $only = @()
foreach ($arg in $Names) {
  if ($arg -like '-*') { Write-Host "Unknown option: $arg"; exit 1 }
  $path = $arg.Trim().Trim('"') -replace '^~', $HOME
  if (-not $Root -and ($arg -match '[\\/]|^[A-Za-z]:' -or $arg -in '~', '.', '..')) {
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
$windows = $env:OS -eq 'Windows_NT'

# R and roxygen2 are needed, so without them it stops
$rscript = Find-Rscript
if (-not $rscript) {
  Write-Host 'Missing:'
  Write-Host ('  {0,-14} {1,-26} package {2}' -f 'Rscript', '(runs R)', 'RProject.R')
  if ((Get-Command winget -ErrorAction SilentlyContinue) -and (Test-Yes 'Install it now with winget install RProject.R?')) {
    winget install --id RProject.R --exact --source winget
    $rscript = Find-Rscript
  } else {
    Write-Host 'Install it from https://cran.r-project.org/ or with: winget install RProject.R'
  }
  if (-not $rscript) { exit 1 }
}
& $rscript -e "quit(status = !requireNamespace('roxygen2', quietly = TRUE))" 2> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host 'The R package roxygen2 is not installed.'
  if (-not (Test-Yes 'Install it now, into your R library?')) { exit 1 }
  & $rscript -e "lib <- Sys.getenv('R_LIBS_USER'); dir.create(lib, recursive = TRUE, showWarnings = FALSE); install.packages('roxygen2', lib = lib, repos = 'https://cloud.r-project.org')"
  if ($LASTEXITCODE -ne 0) { exit 1 }
}
$installed = & $rscript -e "cat(as.character(packageVersion('roxygen2')))" 2> $null

# the part of a path inside the folder, as rwf\rwf; the folder's own name when the folder
# itself is the package
function Get-Relative([string]$path) {
  if ($path.StartsWith($Root + [IO.Path]::DirectorySeparatorChar)) { return $path.Substring($Root.Length + 1) }
  if ($path -eq $Root) { return Split-Path $path -Leaf }
  return $path
}

# the value of a field of a DESCRIPTION file, as Package or Version
function Get-Field([string]$description, [string[]]$fields) {
  foreach ($line in Get-Content -LiteralPath $description) {
    foreach ($field in $fields) {
      if ($line -cmatch "^${field}:\s*(.*?)\s*$") { return $Matches[1] }
    }
  }
}

# the lines of DESCRIPTION with the roxygen2 version, which roxygen rewrites
$version_lines = '^(RoxygenNote|Config/roxygen2/version):'

# whether a package is documented with roxygen: its DESCRIPTION names the roxygen2 version,
# or its NAMESPACE or a help page says roxygen2 wrote it
function Test-UsesRoxygen([string]$dir) {
  if (Select-String -LiteralPath (Join-Path $dir 'DESCRIPTION') -Pattern $version_lines -CaseSensitive -Quiet) { return $true }
  $files = @(Get-Item -LiteralPath (Join-Path $dir 'NAMESPACE') -ErrorAction SilentlyContinue)
  $man = Join-Path $dir 'man'
  if (Test-Path -LiteralPath $man) { $files += @(Get-ChildItem -LiteralPath $man -File | Where-Object { $_.Extension -ceq '.Rd' }) }
  foreach ($file in $files) {
    if (Select-String -LiteralPath $file.FullName -Pattern 'Generated by roxygen2' -SimpleMatch -Quiet) { return $true }
  }
  return $false
}

# the packages: every folder with a DESCRIPTION, by folder, as each repository has its own
# help pages
$dirs = @(); $no_roxygen = @()
$skip = '^(\.git|renv|venv|\.venv|node_modules|.*\.Rcheck)$'
$descriptions = Get-ChildItem -LiteralPath $Root -Recurse -Depth 2 -Filter DESCRIPTION -File -ErrorAction SilentlyContinue |
  Where-Object { -not ((Get-Relative $_.DirectoryName) -split '[\\/]' | Where-Object { $_ -match $skip }) } |
  Sort-Object FullName
foreach ($description in $descriptions) {
  $dir = $description.DirectoryName
  $name = Get-Field $description.FullName 'Package'
  if (-not $name) { continue }
  if ($only.Count -gt 0) {
    $folder = Split-Path -Leaf $dir
    if (-not ($only | Where-Object { $_ -ceq $name -or $_ -ceq $folder })) { continue }
  }
  if (Test-UsesRoxygen $dir) { $dirs += $dir } else { $no_roxygen += Get-Relative $dir }
}
if ($dirs.Count -eq 0) {
  if ($only.Count -gt 0) { Write-Host "No R packages with roxygen comments named $($only -join ' ') in $Root" } else { Write-Host "No R packages with roxygen comments in $Root" }
  exit 1
}

$cache = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } elseif ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.cache' }
$out = Join-Path $cache 'r_document_all'
New-Item -ItemType Directory -Path $out -Force | Out-Null

# the copy that -Check works on, removed after each package and at the end, also after
# Ctrl+C; only ever a folder this script made in $out. On Windows with rd and not
# Remove-Item, which in Windows PowerShell follows the copy's links (junctions) and would
# delete the package's own files
$copy = $null
function Remove-Copy {
  $path = $script:copy; $script:copy = $null
  if (-not $path -or (Split-Path -Parent $path) -ne $out -or -not (Split-Path -Leaf $path).StartsWith('copy.')) { return }
  if ($windows) {
    cmd /c rd /s /q "`"$path`"" 2> $null
  } else {
    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# a copy of a package for -Check: what roxygen writes (man\, NAMESPACE, DESCRIPTION) and
# what loading the package may write (R\ and src\, e.g. RcppExports, vignettes\) is copied;
# the other folders are linked, so that big data is not copied and nothing can change in the
# package itself. On Windows the links are junctions, which need no administrator rights,
# and the other files are copied, as linking a file does
function New-Copy([string]$dir) {
  $suffix = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
  $dest = Join-Path $out "copy.$suffix"
  New-Item -ItemType Directory -Path $dest | Out-Null
  # known at once, so that Ctrl+C while copying still removes it
  $script:copy = $dest
  foreach ($entry in Get-ChildItem -LiteralPath $dir -Force) {
    if ($entry.Name -ceq '.git') { continue }
    $target = Join-Path $dest $entry.Name
    if ($entry.Name -cin 'DESCRIPTION', 'NAMESPACE', 'R', 'man', 'src', 'vignettes') {
      Copy-Item -LiteralPath $entry.FullName -Destination $target -Recurse -Force
    } elseif ($windows -and $entry.PSIsContainer) {
      New-Item -ItemType Junction -Path $target -Target $entry.FullName | Out-Null
    } elseif ($windows) {
      Copy-Item -LiteralPath $entry.FullName -Destination $target -Force
    } else {
      New-Item -ItemType SymbolicLink -Path $target -Target $entry.FullName | Out-Null
    }
  }
  return $dest
}

# a checksum of a text file, the same whatever its line endings; lines matching $drop are
# left out
function Get-TextHash([string]$path, [string]$drop) {
  $text = [IO.File]::ReadAllText($path) -replace "`r`n", "`n"
  if ($drop) { $text = ($text -split "`n" | Where-Object { $_ -cnotmatch $drop }) -join "`n" }
  # SHA-256 and not MD5, which Windows refuses on computers set to FIPS mode
  $sha = [Security.Cryptography.SHA256]::Create()
  return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))
}

# a checksum per file roxygen writes: the help pages, NAMESPACE and DESCRIPTION. With -Check
# the roxygen2 version in DESCRIPTION is left out: roxygen updates it whenever another
# version runs, which does not make the help pages out of date
function Get-Snapshot([string]$dir) {
  $sums = @{}
  $man = Join-Path $dir 'man'
  if (Test-Path -LiteralPath $man) {
    foreach ($rd in Get-ChildItem -LiteralPath $man -File | Where-Object { $_.Extension -ceq '.Rd' }) {
      $sums["man/$($rd.Name)"] = Get-TextHash $rd.FullName
    }
  }
  $namespace = Join-Path $dir 'NAMESPACE'
  if (Test-Path -LiteralPath $namespace) { $sums['NAMESPACE'] = Get-TextHash $namespace }
  $drop = if ($Check) { $version_lines } else { $null }
  $sums['DESCRIPTION'] = Get-TextHash (Join-Path $dir 'DESCRIPTION') $drop
  return $sums
}

# the files whose checksum differs between two snapshots: changed, new or removed
function Get-Changed([hashtable]$before, [hashtable]$after) {
  @($before.Keys) + @($after.Keys) | Sort-Object -Unique | Where-Object { $before[$_] -ne $after[$_] }
}

# minutes and seconds since a time
function Get-Duration([datetime]$since) {
  $seconds = [int]((Get-Date) - $since).TotalSeconds
  return '{0}m{1:00}s' -f [math]::Floor($seconds / 60), ($seconds % 60)
}

# copies left by a run that was closed before it could remove them
foreach ($old in @(Get-ChildItem -LiteralPath $out -Directory -Filter 'copy.*' -ErrorAction SilentlyContinue)) {
  $copy = $old.FullName; Remove-Copy
}

if ($Check) {
  Write-Host "Checking $($dirs.Count) package(s) in $Root against their roxygen comments (roxygen2 $installed); logs in $out"
} else {
  Write-Host "Documenting $($dirs.Count) package(s) in $Root (roxygen2 $installed); logs in $out"
  # the question before anything is changed
  if (-not $Yes) {
    Write-Host "Their help pages and NAMESPACE are written anew: $(($dirs | ForEach-Object { Get-Relative $_ }) -join ' ')"
    if ([Console]::IsInputRedirected) { Write-Host 'Not a terminal, so nothing can be asked: add -Yes to update them'; exit 1 }
    if (-not (Test-Yes 'Update them?')) { Write-Host 'Nothing was changed'; exit 0 }
  }
}
if ($no_roxygen.Count -gt 0) { Write-Host "Skipped, no roxygen comments: $($no_roxygen -join ' ')" }

$failed = @(); $out_of_date = @(); $to_commit = @(); $summary = @()
try {
  foreach ($dir in $dirs) {
    $label = Get-Relative $dir
    $description = Join-Path $dir 'DESCRIPTION'
    $name = Get-Field $description 'Package'
    $recorded = Get-Field $description 'Config/roxygen2/version', 'RoxygenNote'
    $log = Join-Path $out (($label -replace '[\\/:]', '_') + '.log')
    Write-Host ''
    Write-Host ('#' * 80)
    Write-Host "$name  ($label)"
    $start = Get-Date

    $before = Get-Snapshot $dir
    $description_before = Get-TextHash $description $version_lines
    $target = $dir
    if ($Check) { $copy = New-Copy $dir; $target = $copy }
    # roxygen loads the package (pkgload::load_all) to read its objects, so the packages it
    # uses must be installed (r_install_packages.ps1 installs them). R's messages are read
    # as UTF-8, for roxygen's warning signs to come through
    $encoding = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    try {
      $output = & $rscript -e 'roxygen2::roxygenise(commandArgs(TRUE)[1])' $target 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } }
      $status = $LASTEXITCODE
    } finally {
      try { [Console]::OutputEncoding = $encoding } catch { }
    }
    [IO.File]::WriteAllText($log, (@($output) -join [Environment]::NewLine) + [Environment]::NewLine)
    if ($status -eq 0) {
      $changed = @(Get-Changed $before (Get-Snapshot $target))
      # roxygen writes the version that ran into DESCRIPTION; say so when that is all
      if ($description_before -eq (Get-TextHash (Join-Path $target 'DESCRIPTION') $version_lines)) {
        $changed = @($changed | ForEach-Object { if ($_ -eq 'DESCRIPTION') { 'DESCRIPTION (roxygen2 version)' } else { $_ } })
      }
      $count = $changed.Count
      $files = ($changed | Select-Object -First 10) -join ' '
      if ($count -gt 10) { $files = "$files ... ($count in all)" }
      if ($count -eq 0) {
        $result = 'up to date'
        Write-Host "  $result" -ForegroundColor Green
      } elseif ($Check) {
        $result = "out of date: $count files"
        $out_of_date += $label
        Write-Host "  $result" -ForegroundColor Yellow -NoNewline
        Write-Host ": $files"
        # another major or minor roxygen2 version also lays files out differently
        if ($recorded -and ($recorded -replace '\.[^.]*$', '') -ne ($installed -replace '\.[^.]*$', '')) {
          Write-Host "    written with roxygen2 $recorded, this is ${installed}: some differences may only be layout"
        }
      } else {
        $result = "updated $count files"
        $top = git -C $dir rev-parse --show-toplevel 2> $null
        if ($top) { $to_commit += Split-Path -Leaf $top }
        Write-Host "  $result" -ForegroundColor Green -NoNewline
        Write-Host ": $files"
      }
      # roxygen's warnings (lines starting with a cross sign or !), such as a @param without
      # a description or a link to a topic that does not exist
      @($output) | Where-Object { $_ -cmatch '^(\u2716|!) |^Warning' } | Sort-Object -Unique |
        Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    } else {
      $result = 'failed'
      $failed += "$name ($label)"
      Write-Host '  failed' -ForegroundColor Red -NoNewline
      Write-Host "; the end of ${log}:"
      @($output) | Select-Object -Last 15 | ForEach-Object { Write-Host "    $_" }
    }
    Remove-Copy
    $summary += '{0,-32} {1,-10} {2}' -f $label, (Get-Duration $start), $result
  }
} finally {
  Remove-Copy
}

Write-Host ''
Write-Host ('#' * 80)
Write-Host 'Summary'
$summary | ForEach-Object { Write-Host "  $_" }
Write-Host ''
if ($failed.Count -gt 0) {
  Write-Host "Failed in $($failed.Count):" -ForegroundColor Red
  $failed | ForEach-Object { Write-Host "  $_" }
}
if ($out_of_date.Count -gt 0) {
  Write-Host "Out of date in $($out_of_date.Count):" -ForegroundColor Yellow -NoNewline
  Write-Host " $($out_of_date -join ' ')"
  $folders = $out_of_date | ForEach-Object { ($_ -split '[\\/]')[-1] }
  Write-Host "  r_document_all.ps1 $($folders -join ' ') updates them; git diff then shows what changed"
}
$to_commit = @($to_commit | Sort-Object -Unique)
if ($to_commit.Count -gt 0) {
  Write-Host "Changed, to commit and push: $($to_commit -join ' ')"
}
if ($failed.Count -gt 0 -or $out_of_date.Count -gt 0) { exit 1 }
exit 0
