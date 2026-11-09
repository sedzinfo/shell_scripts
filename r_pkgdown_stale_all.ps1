# Finds the pkgdown websites that are out of date: for every R package in Documents\GitHub (or
# the folder given) with a _pkgdown.yml, it compares the site (last_built in docs\pkgdown.yml,
# or the last commit of docs\ when later, as a lazy build does not rewrite last_built) with
# the last change to what the site shows: R\, man\, README.md,
# DESCRIPTION, NEWS.md, _pkgdown.yml, pkgdown\ and vignettes\. Nothing is changed.
#   r_pkgdown_stale_all.ps1 [folder] [package ...]   every package, or only the ones named
# When the built site is committed, the commits after the one that brought it count (what was
# committed with it, or before, is in it); when it is built but not committed, the commits
# after it was built. Uncommitted files count by their date. Each site is:
#   up to date      nothing changed since
#   stale           changed since: the files changed are listed
#   never built     no docs\pkgdown.yml
#   not pushed      built, but the site has uncommitted changes: GitHub shows the old one
# r_pkgdown_all.ps1 <package> (or r_build_all.ps1 <package> -Only pkgdown) builds it again.
# The folder is given as a path (~\GitHub, ., ..\work, C:\work): a plain word is a package.
# The exit code is 1 if any site is stale, never built or not pushed.

param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Names
)

$Root = $null; $only = @()
foreach ($arg in $Names) {
  if ($arg -like '-*') { Write-Host "Unknown option: $arg"; exit 1 }
  $path = $arg.Trim().Trim('"') -replace '^~', $HOME
  if (-not $Root -and ($arg -match '[\\/]|^[A-Za-z]:' -or $arg -in '~', '.', '..')) { $Root = $path } else { $only += $arg }
}
if (-not $Root) {
  $Root = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'GitHub'
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { $Root = Join-Path $HOME 'GitHub' }
}
while (-not (Test-Path -LiteralPath $Root -PathType Container)) {
  Write-Host "Folder not found: $Root"
  $Root = Read-Host 'Folder with the repositories (empty to quit)'
  if (-not $Root) { exit 1 }
  $Root = $Root.Trim().Trim('"') -replace '^~', $HOME
}
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')

function Get-Relative([string]$path) {
  if ($path.StartsWith($Root + [IO.Path]::DirectorySeparatorChar)) { return $path.Substring($Root.Length + 1) }
  return $path
}
function Format-Time([datetime]$t) { $t.ToLocalTime().ToString('dd/MM/yyyy HH:mm') }

$sources = 'R', 'man', 'README.md', 'DESCRIPTION', 'NEWS.md', '_pkgdown.yml', 'pkgdown', 'vignettes'
$skip = '^(\.git|renv|venv|\.venv|node_modules|docs|.*\.Rcheck)$'
$ymls = Get-ChildItem -LiteralPath $Root -Recurse -Depth 2 -Filter _pkgdown.yml -File -ErrorAction SilentlyContinue |
  Where-Object { -not ((Get-Relative $_.DirectoryName) -split '[\\/]' | Where-Object { $_ -match $skip }) } |
  Sort-Object FullName

$attention = 0; $checked = 0
foreach ($yml in $ymls) {
  $dir = $yml.DirectoryName; $label = Get-Relative $dir
  $description = Join-Path $dir 'DESCRIPTION'
  if (-not (Test-Path -LiteralPath $description)) { continue }
  $name = (Select-String -LiteralPath $description -Pattern '^Package:\s*(\S+)' | Select-Object -First 1).Matches.Groups[1].Value
  if (-not $name) { continue }
  if ($only.Count -gt 0 -and -not ($only | Where-Object { $_ -ceq $name -or $_ -ceq (Split-Path -Leaf $dir) })) { continue }
  $checked++
  # the folder the site is built into: destination in _pkgdown.yml, or docs
  $dest = (Select-String -LiteralPath $yml.FullName -Pattern '^destination:\s*["'']?([^"''#\s]+)' | Select-Object -First 1).Matches.Groups[1].Value
  if (-not $dest) { $dest = 'docs' }
  $siteYml = Join-Path (Join-Path $dir $dest) 'pkgdown.yml'
  $builtLine = if (Test-Path -LiteralPath $siteYml) { (Select-String -LiteralPath $siteYml -Pattern '^last_built:\s*(\S+)' | Select-Object -First 1).Matches.Groups[1].Value }
  if (-not $builtLine) {
    Write-Host ('{0,-28} ' -f $label) -NoNewline; Write-Host 'never built' -ForegroundColor Red -NoNewline; Write-Host " (no $dest/pkgdown.yml)"
    $attention++; continue
  }
  $built = [datetime]::Parse($builtLine, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
  $builtEpoch = [DateTimeOffset]::new($built, [TimeSpan]::Zero).ToUnixTimeSeconds()

  # a lazy build (build_site(lazy = TRUE)) does not rewrite last_built: the site is as new as
  # the last commit of anything in it, or, built but not committed, its newest file
  $siteCommit = $null
  if (-not (git -C $dir status --porcelain -- $dest 2> $null)) {
    $siteCommit = git -C $dir log -1 --format=%H -- $dest 2> $null
    $t = git -C $dir log -1 --format=%ct -- $dest 2> $null
    if ($t -and [long]$t -gt $builtEpoch) { $builtEpoch = [long]$t; $built = [DateTimeOffset]::FromUnixTimeSeconds($builtEpoch).UtcDateTime }
  } else {
    foreach ($f in @(git -C $dir status --porcelain --untracked-files=all -- $dest 2> $null)) {
      $item = Get-Item -LiteralPath (Join-Path $dir $f.Substring(3)) -Force -ErrorAction SilentlyContinue
      if ($item -and $item.LastWriteTimeUtc -gt $built) { $built = $item.LastWriteTimeUtc }
    }
    $builtEpoch = [DateTimeOffset]::new($built, [TimeSpan]::Zero).ToUnixTimeSeconds()
  }
  if ($siteCommit) {
    $changed = @(git -C $dir diff --name-only $siteCommit HEAD -- @sources 2> $null)
  } else {
    $changed = @(git -C $dir log --since="@$builtEpoch" --format= --name-only -- @sources 2> $null | Where-Object { $_ })
  }
  $latestEpoch = [long](git -C $dir log -1 --format=%ct -- @sources 2> $null)
  $latest = [DateTimeOffset]::FromUnixTimeSeconds($latestEpoch).UtcDateTime
  # uncommitted files by their date (as UTF-8, for names with Greek or other letters)
  $encoding = [Console]::OutputEncoding
  [Console]::OutputEncoding = [Text.Encoding]::UTF8
  $raw = (git -C $dir status --porcelain -z --untracked-files=all -- @sources 2> $null) -join ''
  [Console]::OutputEncoding = $encoding
  foreach ($entry in $raw -split "`0") {
    if ($entry.Length -lt 4) { continue }
    $file = $entry.Substring(3)
    $item = Get-Item -LiteralPath (Join-Path $dir $file) -Force -ErrorAction SilentlyContinue
    if (-not $item) { continue }
    $t = $item.LastWriteTimeUtc
    if ($t -gt $built) { $changed += "$file (uncommitted)" }
    if ($t -gt $latest) { $latest = $t }
  }
  $changed = @($changed | Where-Object { $_ } | Sort-Object -Unique)
  $unpushed = @(git -C $dir status --porcelain -- $dest 2> $null).Count

  Write-Host ('{0,-28} ' -f $label) -NoNewline
  if ($changed.Count -gt 0) {
    Write-Host 'stale' -ForegroundColor Red -NoNewline
    Write-Host ": built $(Format-Time $built), $($changed.Count) file(s) changed since, the last $(Format-Time $latest)"
    $changed | Select-Object -First 8 | ForEach-Object { Write-Host "    $_" }
    if ($changed.Count -gt 8) { Write-Host "    ... and $($changed.Count - 8) more" }
    $attention++
  } elseif ($unpushed -gt 0) {
    Write-Host 'not pushed' -ForegroundColor Yellow -NoNewline
    Write-Host ": built $(Format-Time $built), $unpushed file(s) of $dest/ not committed"
    $attention++
  } else {
    Write-Host 'up to date' -ForegroundColor Green -NoNewline
    Write-Host " (built $(Format-Time $built))"
  }
}

Write-Host ''
if ($checked -eq 0) {
  Write-Host "No packages with a _pkgdown.yml in $Root"; exit 1
} elseif ($attention -eq 0) {
  Write-Host "All $checked site(s) are up to date" -ForegroundColor Green
} else {
  Write-Host "$attention of $checked site(s) need attention: r_pkgdown_all.ps1 <package> builds a site again, then commit and push it"
  exit 1
}
exit 0
