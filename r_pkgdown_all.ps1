# Builds the pkgdown website of every R package in Documents\GitHub (or the folder given)
# that has a _pkgdown.yml, one after the other, into the folder the site is published from
# (docs\, or the destination in _pkgdown.yml). It reports which builds failed and which
# repositories have changed files in their site, to commit and push. It lists the sites and
# asks first. Nothing is committed or pushed.
#   r_pkgdown_all.ps1 [folder] [package ...]   every package, or only the ones named
#   r_pkgdown_all.ps1 -NoExamples              without running the examples (quicker, but
#                                              the help pages then show none)
#   r_pkgdown_all.ps1 -Yes                     without asking first
# The folder is given as a path (~\GitHub, ., ..\work, C:\work): a plain word is a package.
# A package is a folder with a DESCRIPTION: a repository, or a folder in one (rwf\rwf).
# Mirror repositories with the same package (crypto and golemcrypto) each get their own site.
# The exit code is 1 if any build failed.

param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Names,
  [switch]$NoExamples,
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

# R and pkgdown are needed, so without them it stops; pandoc renders the articles, and
# without it the script goes on (pkgdown also finds the pandoc that comes with RStudio)
$rscript = Find-Rscript
$missing = @()
if (-not $rscript) { $missing += , @('Rscript', 'runs R', 'RProject.R') }
if (-not (Get-Command pandoc -ErrorAction SilentlyContinue)) { $missing += , @('pandoc', 'the articles (vignettes)', 'JohnMacFarlane.Pandoc') }
if ($missing.Count -gt 0) {
  Write-Host 'Missing:'
  foreach ($m in $missing) { Write-Host ('  {0,-14} {1,-26} package {2}' -f $m[0], "($($m[1]))", $m[2]) }
  $ids = $missing | ForEach-Object { $_[2] }
  if ((Get-Command winget -ErrorAction SilentlyContinue) -and (Test-Yes "Install them now with winget install $($ids -join ' ')?")) {
    foreach ($id in $ids) { winget install --id $id --exact --source winget }
    if (-not $rscript) { $rscript = Find-Rscript }
  } else {
    Write-Host "Install them with: winget install $($ids -join ' ')"
  }
}
if (-not $rscript) { exit 1 }
& $rscript -e "quit(status = !requireNamespace('pkgdown', quietly = TRUE))" 2> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host 'The R package pkgdown is not installed.'
  if (-not (Test-Yes 'Install it now, into your R library?')) { exit 1 }
  & $rscript -e "lib <- Sys.getenv('R_LIBS_USER'); dir.create(lib, recursive = TRUE, showWarnings = FALSE); install.packages('pkgdown', lib = lib, repos = 'https://cloud.r-project.org')"
  if ($LASTEXITCODE -ne 0) { exit 1 }
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

# the pkgdown configuration of a package folder, where pkgdown looks for it
function Get-Config([string]$dir) {
  foreach ($file in '_pkgdown.yml', '_pkgdown.yaml', 'pkgdown/_pkgdown.yml', 'pkgdown/_pkgdown.yaml', 'inst/_pkgdown.yml') {
    $path = Join-Path $dir $file
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
  }
}

# the packages: every folder with a DESCRIPTION, by folder, as each repository publishes its
# own site
$dirs = @(); $no_config = @()
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
  if (Get-Config $dir) { $dirs += $dir } else { $no_config += Get-Relative $dir }
}
if ($dirs.Count -eq 0) {
  if ($only.Count -gt 0) { Write-Host "No R packages with a _pkgdown.yml named $($only -join ' ') in $Root" } else { Write-Host "No R packages with a _pkgdown.yml in $Root" }
  if ($no_config.Count -gt 0) { Write-Host "Without one: $($no_config -join ' ') (pkgdown::use_pkgdown() sets one up)" }
  exit 1
}

$cache = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } elseif ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.cache' }
$out = Join-Path $cache 'r_pkgdown_all'
New-Item -ItemType Directory -Path $out -Force | Out-Null

# minutes and seconds since a time
function Get-Duration([datetime]$since) {
  $seconds = [int]((Get-Date) - $since).TotalSeconds
  return '{0}m{1:00}s' -f [math]::Floor($seconds / 60), ($seconds % 60)
}

$examples = if ($NoExamples) { 'FALSE' } else { 'TRUE' }

Write-Host "Building $($dirs.Count) site(s) in $Root; logs in $out"
# the question before anything is written
if (-not $Yes) {
  Write-Host "Their sites are built anew: $(($dirs | ForEach-Object { Get-Relative $_ }) -join ' ')"
  if ([Console]::IsInputRedirected) { Write-Host 'Not a terminal, so nothing can be asked: add -Yes to build them'; exit 1 }
  if (-not (Test-Yes 'Build them?')) { Write-Host 'Nothing was changed'; exit 0 }
}
if ($no_config.Count -gt 0) { Write-Host "Skipped, no _pkgdown.yml (pkgdown::use_pkgdown() sets one up): $($no_config -join ' ')" }

$failed = @(); $to_commit = @(); $example_errors = @(); $summary = @()
foreach ($dir in $dirs) {
  $label = Get-Relative $dir
  $name = Get-Field (Join-Path $dir 'DESCRIPTION') 'Package'
  $log = Join-Path $out (($label -replace '[\\/]', '_') + '.log')
  # the site's folder: destination in _pkgdown.yml, relative to the package, or docs
  $destination = Get-Content -LiteralPath (Get-Config $dir) | Where-Object { $_ -cmatch '^destination:' } |
    Select-Object -First 1 | ForEach-Object { ($_ -creplace '^destination:\s*', '').Trim() -replace '["'']', '' }
  if (-not $destination) { $destination = 'docs' }
  $site = [IO.Path]::GetFullPath([IO.Path]::Combine($dir, $destination)).TrimEnd('\', '/')
  Write-Host ''
  Write-Host ('#' * 80)
  Write-Host "$name  ($label -> $(Get-Relative $site))"
  $start = Get-Date

  # pkgdown installs the package in a temporary library and builds in a new R process. R's
  # messages are read as UTF-8, for pkgdown's warning signs to come through
  $encoding = [Console]::OutputEncoding
  try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
  try {
    # a blank line R writes to its errors comes as an error record, which Windows PowerShell
    # 5.1 would show as its type
    $output = & $rscript -e "pkgdown::build_site(commandArgs(TRUE)[1], preview = FALSE, examples = $examples)" $dir 2>&1 | ForEach-Object {
      if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } }
    $status = $LASTEXITCODE
  } finally {
    try { [Console]::OutputEncoding = $encoding } catch { }
  }
  [IO.File]::WriteAllText($log, (@($output) -join [Environment]::NewLine) + [Environment]::NewLine)
  if ($status -eq 0) {
    $result = 'built'; $color = 'Green'
    # an example that fails does not stop pkgdown: the help page shows the error (class
    # r-err), so the pages written now are searched for one, also the ones of the development
    # version (docs\dev\reference)
    $broken = @()
    if (Test-Path -LiteralPath $site) {
      $broken = @(Get-ChildItem -LiteralPath $site -Recurse -File -Filter '*.html' |
        Where-Object { (Split-Path -Leaf $_.DirectoryName) -eq 'reference' -and $_.LastWriteTime -gt $start } |
        Where-Object { Select-String -LiteralPath $_.FullName -Pattern 'class="r-err' -SimpleMatch -Quiet } |
        ForEach-Object { $_.BaseName } | Sort-Object -Unique)
    }
    if ($broken.Count -gt 0) {
      $result = "built, examples fail in $($broken.Count) pages"; $color = 'Yellow'
      $example_errors += "${label}: $($broken -join ' ')"
    }
    $changed = @(git -C $dir status --porcelain -- $site 2> $null).Count
    if ($changed -gt 0) {
      $top = git -C $dir rev-parse --show-toplevel 2> $null
      if ($top) { $to_commit += Split-Path -Leaf $top }
      $result = "$result, $changed changed files"
    }
    Write-Host "  $result" -ForegroundColor $color
    if ($broken.Count -gt 0) { Write-Host "    examples with errors: $($broken -join ' ')" -ForegroundColor Yellow }
    # pkgdown's warnings (lines starting with ! or a cross sign), such as missing alt-text or
    # topics missing from the reference index
    @($output) | Where-Object { $_ -cmatch '^(!|\u2716) ' } | Sort-Object -Unique |
      Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
  } else {
    $result = 'failed'
    $failed += "$name ($label)"
    Write-Host '  failed' -ForegroundColor Red -NoNewline
    Write-Host "; the end of ${log}:"
    @($output) | Select-Object -Last 15 | ForEach-Object { Write-Host "    $_" }
  }
  $summary += '{0,-32} {1,-10} {2}' -f $label, (Get-Duration $start), $result
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
if ($example_errors.Count -gt 0) {
  Write-Host 'Examples with errors (the help page shows the error):' -ForegroundColor Yellow
  $example_errors | ForEach-Object { Write-Host "  $_" }
}
if ($to_commit.Count -gt 0) {
  Write-Host "Changed sites, to commit and push for GitHub Pages: $(($to_commit | Sort-Object -Unique) -join ' ')"
  if ($NoExamples) {
    Write-Host '  built with -NoExamples, so their help pages show no examples: build again without it before committing' -ForegroundColor Yellow
  }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
