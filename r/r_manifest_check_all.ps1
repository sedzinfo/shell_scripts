# Checks the manifest.json of every Shiny app in Documents\GitHub (or the folder given), the
# file Posit Connect (Cloud) deploys from: whether it lists every file the app needs, and only
# files that are on GitHub. Nothing is changed.
#   r_manifest_check_all.ps1 [folder] [app ...]   every app with a manifest.json, or only these
# For each app it reports:
#   missing        files git tracks in R\ and inst\, and app.R, DESCRIPTION and NAMESPACE,
#                  that the manifest does not list (and .rscignore does not leave out): the
#                  deployed app would not have them
#   not on GitHub  files the manifest lists that git does not track: a deploy from GitHub
#                  does not find them
#   deleted        files the manifest lists that no longer exist
# r_shiny_update_manifests.ps1 <app> writes the manifest anew. The folder is given as a path
# (~\GitHub, ., ..\work, C:\work): a plain word is an app. The exit code is 1 if any app has a
# problem.

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
# the folder given, or Documents\GitHub (where GitHub Desktop puts the repositories), or ~\GitHub
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

$problems = 0; $checked = 0
foreach ($dir in Get-ChildItem -LiteralPath $Root -Directory | Sort-Object Name) {
  $manifest = Join-Path $dir.FullName 'manifest.json'
  if (-not (Test-Path -LiteralPath $manifest)) { continue }
  if ($only.Count -gt 0 -and $dir.Name -notin $only) { continue }
  $checked++
  $listed = @((Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).files.PSObject.Properties.Name | Sort-Object)
  # what the app needs: tracked files of R/ and inst/, and the files at the top a golem app runs from
  $needed = @(git -C $dir.FullName ls-files -- R inst app.R DESCRIPTION NAMESPACE 2> $null)
  # .rscignore leaves files or folders out of a deploy on purpose (one name per line)
  $ignoreFile = Join-Path $dir.FullName '.rscignore'
  if (Test-Path -LiteralPath $ignoreFile) {
    foreach ($ignore in Get-Content -LiteralPath $ignoreFile) {
      $ignore = $ignore.Trim()
      if ($ignore) { $needed = @($needed | Where-Object { $_ -ne $ignore -and -not $_.StartsWith("$ignore/") }) }
    }
  }
  $tracked = @(git -C $dir.FullName ls-files 2> $null)
  $missing = @($needed | Where-Object { $_ -cnotin $listed } | Sort-Object)
  $deleted = @($listed | Where-Object { -not (Test-Path -LiteralPath (Join-Path $dir.FullName $_)) })
  # a deleted file is also untracked: say it once
  $untracked = @($listed | Where-Object { $_ -cnotin $tracked -and $_ -cnotin $deleted })

  if ($missing.Count + $untracked.Count + $deleted.Count -eq 0) {
    Write-Host ('{0,-24} ' -f $dir.Name) -NoNewline
    Write-Host 'ok' -ForegroundColor Green -NoNewline
    Write-Host " ($($listed.Count) files)"
    continue
  }
  $problems++
  Write-Host ('{0,-24} ' -f $dir.Name) -NoNewline
  Write-Host 'problem' -ForegroundColor Red
  foreach ($f in $missing) { Write-Host '    missing        ' -ForegroundColor Red -NoNewline; Write-Host $f }
  foreach ($f in $untracked) { Write-Host '    not on GitHub  ' -ForegroundColor Yellow -NoNewline; Write-Host $f }
  foreach ($f in $deleted) { Write-Host '    deleted        ' -ForegroundColor Yellow -NoNewline; Write-Host $f }
}

Write-Host ''
if ($checked -eq 0) {
  if ($only.Count -gt 0) { Write-Host "No apps with a manifest.json named $($only -join ' ') in $Root" } else { Write-Host "No apps with a manifest.json in $Root" }
  exit 1
} elseif ($problems -eq 0) {
  Write-Host "All $checked manifest(s) list what their app needs" -ForegroundColor Green
} else {
  Write-Host "$problems of $checked manifest(s) need attention: r_shiny_update_manifests.ps1 <app> writes one anew"
  exit 1
}
exit 0
