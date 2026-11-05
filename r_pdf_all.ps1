# Makes the PDF reference manual (R CMD Rd2pdf, the manual CRAN shows) of every R package in
# Documents\GitHub (or the folder given), one after the other, as <package>.pdf at the top of
# its repository, where the build-tarball workflows put it; or all in one folder with -To.
# It reports which manuals failed (with LaTeX's error) and the size of the others. Nothing is
# committed or pushed. It lists the manuals and asks first.
#   r_pdf_all.ps1 [folder] [package ...]   every package, or only the ones named
#   r_pdf_all.ps1 -To ~\manuals            all the PDFs in that folder instead
#   r_pdf_all.ps1 -Yes                     without asking first
# The folder is given as a path (~\GitHub, ., ..\work, C:\work): a plain word is a package.
# A package is a folder with a DESCRIPTION: a repository, or a folder in one (rwf\rwf).
# Mirror repositories with the same package (crypto and golemcrypto) each get their own PDF.
# Needs R and LaTeX (MiKTeX). The exit code is 1 if any failed.

param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Names,
  [string]$To,
  [switch]$Yes
)

# anything but y/yes is no
function Test-Yes([string]$question) {
  $answer = Read-Host "$question [y/N]"
  return $answer -match '^\s*y(es)?\s*$'
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
if ($To) {
  $To = $To.Trim().Trim('"') -replace '^~', $HOME
  New-Item -ItemType Directory -Path $To -Force -ErrorAction Stop | Out-Null
  $To = (Resolve-Path -LiteralPath $To).ProviderPath.TrimEnd('\', '/')
}

# R and LaTeX are needed, so without them it stops. MiKTeX has pdflatex and makeindex
$rscript = Find-Rscript
$missing = @()
if (-not $rscript) { $missing += , @('Rscript', 'runs R CMD Rd2pdf', 'RProject.R') }
if (-not (Get-Command pdflatex -ErrorAction SilentlyContinue) -or -not (Get-Command makeindex -ErrorAction SilentlyContinue)) {
  $missing += , @('pdflatex', 'LaTeX, makes the PDF', 'MiKTeX.MiKTeX')
}
if ($missing.Count -gt 0) {
  Write-Host 'Missing:'
  foreach ($m in $missing) { Write-Host ('  {0,-14} {1,-26} package {2}' -f $m[0], "($($m[1]))", $m[2]) }
  $ids = $missing | ForEach-Object { $_[2] }
  foreach ($id in $ids) { Install-Program $id }
  if (-not $rscript) { $rscript = Find-Rscript }
  if (-not $rscript -or -not (Get-Command pdflatex -ErrorAction SilentlyContinue)) {
    Write-Host "Install them with: winget install $($ids -join ' ')"; exit 1
  }
}
# R CMD runs through R.exe, which sits next to Rscript.exe
$r = Join-Path (Split-Path -Parent $rscript) 'R.exe'
if (-not (Test-Path -LiteralPath $r)) { $r = Join-Path (Split-Path -Parent $rscript) 'R' }
# the font R's manuals use for code; MiKTeX can install it, TinyTeX has it
if ((Get-Command kpsewhich -ErrorAction SilentlyContinue) -and -not (kpsewhich inconsolata.sty)) {
  Write-Host "The LaTeX font inconsolata, which R's manuals use for code, is missing."
  if (Get-Command miktex -ErrorAction SilentlyContinue) {
    Write-Host 'Installing it with miktex packages install inconsolata ...'
    miktex packages install inconsolata
  }
}

# the part of a path inside the folder, as rwf\rwf
function Get-Relative([string]$path) {
  if ($path.StartsWith($Root + [IO.Path]::DirectorySeparatorChar)) { return $path.Substring($Root.Length + 1) }
  return $path
}

# the value of a field of a DESCRIPTION file, as Package
function Get-Field([string]$description, [string]$field) {
  foreach ($line in Get-Content -LiteralPath $description) {
    if ($line -cmatch "^${field}:\s*(.*?)\s*$") { return $Matches[1] }
  }
}

# a file size as du -h shows it: 640K, 1.2M
function Format-Size([long]$bytes) {
  if ($bytes -ge 1MB) { return '{0:0.0}M' -f ($bytes / 1MB) }
  if ($bytes -ge 1KB) { return '{0:0}K' -f [math]::Ceiling($bytes / 1KB) }
  return "${bytes}B"
}

# the packages: every folder with a DESCRIPTION, by folder, as each repository keeps its own PDF
$dirs = @()
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
  $dirs += $dir
}
if ($dirs.Count -eq 0) {
  if ($only.Count -gt 0) { Write-Host "No R packages named $($only -join ' ') in $Root" } else { Write-Host "No R packages in $Root" }
  exit 1
}

# R CMD Rd2pdf works in a temporary folder in the current one, so it runs here
$cache = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } elseif ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.cache' }
$out = Join-Path $cache 'r_pdf_all'
New-Item -ItemType Directory -Path $out -Force | Out-Null

Write-Host "Making $($dirs.Count) manual(s) of $Root; logs in $out"
# the question before anything is written
if (-not $Yes) {
  $where = if ($To) { " in $To" } else { '' }
  Write-Host "The PDF manuals are written anew$where, for: $(($dirs | ForEach-Object { Get-Relative $_ }) -join ' ')"
  if ([Console]::IsInputRedirected) { Write-Host 'Not a terminal, so nothing can be asked: add -Yes to write them'; exit 1 }
  if (-not (Test-Yes 'Write them?')) { Write-Host 'Nothing was changed'; exit 0 }
}

$failed = @(); $written = @(); $summary = @()
$made_from = New-Object 'System.Collections.Generic.Dictionary[string,string]'
foreach ($dir in $dirs) {
  $label = Get-Relative $dir
  $name = Get-Field (Join-Path $dir 'DESCRIPTION') 'Package'
  $log = Join-Path $out (($label -replace '[\\/]', '_') + '.log')
  # in the -To folder one PDF per package is enough: a mirror repository of a package
  # already made there is skipped
  if ($To -and $made_from.ContainsKey($name)) {
    $summary += '{0,-32} {1}' -f $label, "skipped, the same package as $($made_from[$name])"
    continue
  }
  $made_from[$name] = $label
  # at the top of the repository, as the workflows do, or in the -To folder
  if ($To) {
    $pdf = Join-Path $To "$name.pdf"
  } else {
    $top = git -C $dir rev-parse --show-toplevel 2> $null
    $top = if ($top) { [IO.Path]::GetFullPath($top) } else { $dir }
    $pdf = Join-Path $top "$name.pdf"
  }
  Write-Host ''
  Write-Host ('#' * 80)
  Write-Host "$name  ($label -> $(Get-Relative $pdf))"

  # written now, and not an older PDF left as it was: Rd2pdf does not fail when it cannot
  # replace one (such as one open in a viewer that locks it). A blank line R writes to its
  # errors comes as an error record, which Windows PowerShell 5.1 would show as its type
  $start = Get-Date
  Push-Location -LiteralPath $out
  try {
    $output = & $r CMD Rd2pdf $dir --force --no-preview "--output=$pdf" 2>&1 | ForEach-Object {
      if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } }
    $status = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  [IO.File]::WriteAllText($log, (@($output) -join [Environment]::NewLine) + [Environment]::NewLine)
  $file = Get-Item -LiteralPath $pdf -ErrorAction SilentlyContinue
  if ($status -eq 0 -and $file -and $file.Length -gt 0 -and $file.LastWriteTime -ge $start) {
    $written += $pdf
    $pages = $null
    if (Get-Command pdfinfo -ErrorAction SilentlyContinue) {
      $pages = pdfinfo $pdf 2> $null | Where-Object { $_ -match '^Pages:\s*(\d+)' } | ForEach-Object { $Matches[1] }
    }
    $result = if ($pages) { "$pages pages, $(Format-Size $file.Length)" } else { Format-Size $file.Length }
    Write-Host "  $result" -ForegroundColor Green
    # problems in the help files that R warns about but still puts in the manual
    @($output) | Where-Object { $_ -cmatch '^Warning' } | Sort-Object -Unique |
      Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
  } else {
    $result = 'failed'
    $failed += "$name ($label)"
    Write-Host '  failed' -ForegroundColor Red -NoNewline
    Write-Host "; LaTeX's error, from ${log}:"
    # LaTeX's first error (lines starting with !; LaTeX runs several times and repeats it),
    # with the line it is on; without one, the end of the log
    $lines = @($output)
    $first = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -like '!*') { $first = $i; break } }
    if ($first -ge 0) {
      $lines[$first..([math]::Min($first + 3, $lines.Count - 1))] | ForEach-Object { Write-Host "    $_" }
    } else {
      $lines | Select-Object -Last 15 | ForEach-Object { Write-Host "    $_" }
    }
  }
  $summary += '{0,-32} {1}' -f $label, $result
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
if ($written.Count -gt 0) {
  if ($To) {
    Write-Host "$($written.Count) PDF(s) in $To" -ForegroundColor Green
  } else {
    Write-Host "$($written.Count) PDF(s) written in their repositories; commit them, or let the build-tarball workflows rebuild them on push."
  }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
