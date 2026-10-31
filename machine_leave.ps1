# Before handing back a computer: checks that every repository of yours in Documents\GitHub
# is completely on GitHub, then removes, one step at a time and only after asking, what would
# let someone else use your accounts from here:
#   1. your repositories, only the ones that are completely on GitHub
#   2. the SSH keys of this computer that are on your GitHub account
#   3. the GitHub passwords and tokens that git, GitHub Desktop and the GitHub CLI keep
#   4. lines with tokens or keys in .Renviron, the PowerShell profiles, ... and the history
#      files, and the user environment variables named like a token or a key
#   5. the shinyapps.io / Posit Connect logins that rsconnect keeps
# Other people's repositories (such as your employer's) and SSH keys that are not on your
# GitHub account are never touched. At the end it lists what only you can do on the websites,
# such as deleting the key from your GitHub account.
#   leave_machine.ps1 [folder] [user]     default Documents\GitHub (or ~\GitHub) and sedzinfo
#   leave_machine.ps1 -Check              only the report, nothing is removed

param(
  [string]$Folder,
  [string]$User = 'sedzinfo',
  [switch]$Check
)

# the ellipsis that hides a secret, as a code point, as Windows PowerShell reads a script
# without a BOM as ANSI
$ellipsis = [string][char]0x2026

# anything but y/yes is no; with -Check nothing is asked, so nothing is removed
function Test-Yes([string]$question) {
  if ($Check) { return $false }
  $answer = Read-Host "$question [y/N]"
  return $answer -match '^\s*y(es)?\s*$'
}

# a path as shown to you, with ~ for the home folder
function Get-Short([string]$path) {
  if ($path.StartsWith("$HOME\", [StringComparison]::OrdinalIgnoreCase)) { return '~' + $path.Substring($HOME.Length) }
  return $path
}

# a name and a note in two columns, the note in a color
function Write-Note([string]$name, [string]$note, [string]$color) {
  Write-Host ('  {0,-30} ' -f $name) -NoNewline
  if ($color) { Write-Host $note -ForegroundColor $color } else { Write-Host $note }
}

function Write-Title([string]$title) {
  Write-Host $title -ForegroundColor White
}

# git credential with its input from a file through cmd's <, which passes it on as it is:
# Windows PowerShell can put a byte order mark in front of what it pipes to a program,
# and git then does not understand the first line
function Invoke-GitCredential([string]$action, [string]$text) {
  $file = Join-Path ([IO.Path]::GetTempPath()) "git_credential_$PID.txt"
  [IO.File]::WriteAllText($file, $text, (New-Object System.Text.UTF8Encoding $false))
  cmd /c "git credential $action < `"$file`""
  $status = $LASTEXITCODE
  Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
  return $status
}

# the SHA256 fingerprint of a public key, as ssh-keygen -l shows it
function Get-Fingerprint([string]$pub) {
  $material = ((Get-Content -LiteralPath $pub -TotalCount 1) -split '\s+')[1]
  $hash = [Security.Cryptography.SHA256]::Create().ComputeHash([Convert]::FromBase64String($material))
  return 'SHA256:' + [Convert]::ToBase64String($hash).TrimEnd('=')
}

# the folder given, or Documents\GitHub (where GitHub Desktop puts the repositories), or ~\GitHub
if (-not $Folder) {
  $Folder = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'GitHub'
  if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { $Folder = Join-Path $HOME 'GitHub' }
}
$Folder = $Folder.Trim().Trim('"') -replace '^~', $HOME
# ask for the folder until one that exists is given (~ works, and the quotes of "Copy as path")
while (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
  Write-Host "Folder not found: $Folder"
  $Folder = Read-Host 'Folder with the repositories (empty to quit)'
  if (-not $Folder) { exit 1 }
  $Folder = $Folder.Trim().Trim('"') -replace '^~', $HOME
}
$Folder = (Resolve-Path -LiteralPath $Folder).ProviderPath

# files and folders that R, Python and the builds make again (caches, .Rhistory, ...)
$remade = '(^|/)(\.Rproj\.user|\.Rhistory|\.RData|\.Ruserdata|\.DS_Store|__pycache__|node_modules|venv|\.venv|renv/library|\.quarto|_freeze|_site|[^/]*_cache|[^/]*_files|[^/]*\.Rcheck)/?$'

# what of a repository is not on GitHub, as one text (empty: all of it is)
function Get-NotOnGitHub([string]$dir) {
  $reasons = @()
  # changed files, and new ones except the ones that are made again (empty folders hold nothing)
  $n = @(git -C $dir status --porcelain --untracked-files=no).Count +
    @(git -C $dir ls-files --others --exclude-standard --directory --no-empty-directory | Where-Object { $_ -notmatch $remade }).Count
  if ($n -gt 0) { $reasons += "$n uncommitted" }
  # commits of any local branch, not only the current one, that GitHub does not have
  $n = [int](git -C $dir rev-list --count --branches --not --remotes=origin)
  if ($n -gt 0) { $reasons += "$n to push" }
  $n = @(git -C $dir stash list).Count
  if ($n -gt 0) { $reasons += "$n stashed" }
  return $reasons -join ', '
}

if ($Check) { Write-Host '-Check: only the report, nothing is removed' }

#####################################################################
Write-Title "1. Your repositories in $(Get-Short $Folder)"
$mine = @(); $others = @()
foreach ($d in Get-ChildItem -LiteralPath $Folder -Directory) {
  if (-not (Test-Path -LiteralPath (Join-Path $d.FullName '.git'))) { continue }
  $url = git -C $d.FullName config --get remote.origin.url
  # yours: the origin is github.com/USER (GitHub names ignore case)
  if ("$url" -match "github\.com[:/]$([regex]::Escape($User))/") { $mine += $d.FullName } else { $others += $d.FullName }
}

# all fetched at once (much faster than one by one), without asking for a password or a
# passphrase, and without the sign-in window of the Git Credential Manager; a repository
# that cannot be fetched cannot be compared with GitHub
$saved = @{}
foreach ($name in 'GIT_TERMINAL_PROMPT', 'GCM_INTERACTIVE', 'GIT_SSH_COMMAND') { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$env:GIT_TERMINAL_PROMPT = '0'; $env:GCM_INTERACTIVE = 'never'; $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes'
$git = (Get-Command git).Source
$fetches = @(foreach ($dir in $mine) {
  $info = New-Object System.Diagnostics.ProcessStartInfo $git, "-C `"$dir`" fetch -q --prune origin"
  $info.UseShellExecute = $false
  $info.RedirectStandardError = $true
  $info.CreateNoWindow = $true
  $process = [System.Diagnostics.Process]::Start($info)
  $null = $process.StandardError.ReadToEndAsync()    # read, so that a long message cannot hold it up
  [pscustomobject]@{ Dir = $dir; Process = $process }
})
$unreachable = @{}
foreach ($fetch in $fetches) {
  $fetch.Process.WaitForExit()
  if ($fetch.Process.ExitCode -ne 0) { $unreachable[$fetch.Dir] = $true }
}
foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }

$safe = @(); $kept = 0
foreach ($dir in $mine) {
  $name = Split-Path $dir -Leaf
  $reasons = if ($unreachable[$dir]) { 'could not reach GitHub to compare' } else { Get-NotOnGitHub $dir }
  if ($reasons) {
    $kept++
    Write-Note $name $reasons 'Red'
    continue
  }
  $safe += $dir
  Write-Note $name 'completely on GitHub' 'Green'
  # files that git ignores are not on GitHub either and go with the repository
  $ignored = @(git -C $dir status --porcelain --ignored | Where-Object { $_.StartsWith('!! ') } |
    ForEach-Object { $_.Substring(3) } | Where-Object { $_ -notmatch $remade })
  if ($ignored.Count -gt 0) {
    $more = if ($ignored.Count -gt 3) { " and $($ignored.Count - 3) more" } else { '' }
    Write-Note '' "not in git, deleted with it: $(($ignored | Select-Object -First 3) -join ' ')$more" 'Yellow'
  }
}
foreach ($dir in $others) {
  $url = git -C $dir config --get remote.origin.url
  if (-not $url) {
    Write-Note (Split-Path $dir -Leaf) 'only on this computer (no remote), left alone' 'Red'
  } else {
    # git@github.com:owner/name.git or https://github.com/owner/name.git -> github.com/owner
    $owner = $url -replace '^[a-z+]+://', '' -replace '^[^@/]*@', ''
    $owner = ([regex]':').Replace($owner, '/', 1) -replace '/[^/]*$', ''
    Write-Note (Split-Path $dir -Leaf) "not yours ($owner), left alone" ''
  }
}

if ($kept -gt 0) {
  Write-Host "  $kept not completely on GitHub: commit, push or drop the stash, then run this again. They are not deleted." -ForegroundColor Red
}
if ($unreachable.Count -gt 0 -and $unreachable.Count -eq $mine.Count) {
  Write-Host '  GitHub could not be reached at all: check the internet connection; for repositories cloned'
  Write-Host '  over SSH with a key that has a passphrase, load it first with ssh-add. Then run this again.'
} elseif ($unreachable.Count -gt 0) {
  Write-Host '  A repository GitHub does not answer for may have been renamed or deleted there.'
}
if ($safe.Count -gt 0 -and (Test-Yes "Delete the $($safe.Count) repositories that are completely on GitHub from this computer?")) {
  # out of the folders first, as Windows does not delete a folder that a program is in
  Push-Location -LiteralPath $HOME
  [Environment]::CurrentDirectory = $HOME
  foreach ($dir in $safe) {
    $name = Split-Path $dir -Leaf
    # anything new since the check above keeps the repository
    if (Get-NotOnGitHub $dir) {
      Write-Host "  ${name}: changed since the check, kept"
      continue
    }
    # rd and not Remove-Item, which in Windows PowerShell follows the links (junctions) that
    # renv makes to its cache, and would delete the packages of every project there
    cmd /c rd /s /q "`"$dir`"" 2> $null
    if (Test-Path -LiteralPath $dir) {
      Write-Host "  ${name}: not completely deleted, a program may have one of its files open" -ForegroundColor Red
    } else {
      Write-Host "  ${name}: deleted"
    }
  }
  Pop-Location -ErrorAction SilentlyContinue
}

#####################################################################
Write-Host ''
Write-Title '2. SSH keys'
$fingerprints = @()
# GitHub lists the public keys of every account at github.com/USER.keys, so a key of this
# computer is yours when it is in that list
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try {
  $github_keys = (Invoke-WebRequest -Uri "https://github.com/$User.keys" -UseBasicParsing -TimeoutSec 20).Content
  if ($github_keys -is [byte[]]) { $github_keys = [Text.Encoding]::UTF8.GetString($github_keys) }
} catch {
  $github_keys = $null
}
if ($null -eq $github_keys) {
  Write-Host "  could not get the keys of $User from GitHub, skipped" -ForegroundColor Yellow
} else {
  $materials = @("$github_keys" -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { ($_ -split '\s+')[1] })
  $personal = @(); $other = @()
  foreach ($pub in Get-ChildItem -LiteralPath (Join-Path $HOME '.ssh') -Filter '*.pub' -File -ErrorAction SilentlyContinue) {
    $material = ((Get-Content -LiteralPath $pub.FullName -TotalCount 1) -split '\s+')[1]
    # base64, so letter case matters
    if ($material -and $materials -ccontains $material) {
      $personal += $pub.FullName -replace '\.pub$', ''
    } else {
      $other += $pub.BaseName
    }
  }
  Write-Host "  SSH keys on your GitHub account: $($materials.Count); the ones on this computer:"
  if ($personal.Count -eq 0) { Write-Host '  none' }
  foreach ($key in $personal) {
    $fingerprint = Get-Fingerprint "$key.pub"
    $fingerprints += $fingerprint
    Write-Host "  $(Get-Short $key)  $fingerprint"
  }
  if ($other.Count -gt 0) { Write-Host "  left alone, not on your GitHub account: $($other -join ' ')" }
  foreach ($key in $personal) {
    if (Test-Yes "Delete $(Get-Short $key)? Servers and other sites that use this key stop working from here too") {
      # out of the running ssh-agent as well
      if (Get-Command ssh-add -ErrorAction SilentlyContinue) { ssh-add -d $key *> $null }
      Remove-Item -LiteralPath $key, "$key.pub" -Force -ErrorAction SilentlyContinue
      if (-not (Test-Path -LiteralPath $key)) { Write-Host '  deleted' }
    }
  }
}

#####################################################################
Write-Host ''
Write-Title '3. GitHub logins kept by git, GitHub Desktop and the GitHub CLI'
$helpers = @(git config --get-regexp '^credential\..*helper$' | ForEach-Object { ($_ -split '\s+', 2)[1] })
if ($helpers.Count -eq 0) {
  Write-Host '  git keeps no passwords here (no credential helper)'
} else {
  Write-Host "  git keeps passwords and tokens with: $($helpers -join ', ')"
  if (Test-Yes 'Make git forget the ones for github.com?') {
    # asks every helper to erase what it has for github.com
    if ((Invoke-GitCredential reject "protocol=https`nhost=github.com`n`n") -eq 0) { Write-Host '  done' }
  }
}
# Windows keeps logins in its Credential Manager: git's, through the Git Credential Manager,
# and GitHub Desktop's; the target names (LegacyGeneric:target=...) are the same in every language
$targets = @(cmdkey /list | ForEach-Object { [regex]::Match($_, '(\S*target=.*\S)').Groups[1].Value } |
  Where-Object { $_ -match 'github' })
if ($targets.Count -eq 0) {
  Write-Host '  no GitHub logins in the Windows Credential Manager'
} else {
  Write-Host '  GitHub logins in the Windows Credential Manager:'
  $targets | ForEach-Object { Write-Host "    $($_ -replace '^.*target=', '')" }
  if (Test-Yes '  Delete them? GitHub Desktop is then signed out') {
    foreach ($target in $targets) { cmdkey "/delete:$target" | Out-Null }
    Write-Host '    deleted'
  }
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Write-Host '  the GitHub CLI (gh) is not installed'
} else {
  gh auth status --hostname github.com *> $null
  if ($LASTEXITCODE -eq 0) {
    Write-Host '  the GitHub CLI (gh) is logged in to github.com'
    if (Test-Yes 'Log it out?') { gh auth logout --hostname github.com }
  } else {
    Write-Host '  the GitHub CLI (gh) is not logged in'
  }
}

#####################################################################
Write-Host ''
Write-Title '4. Tokens and keys in settings and history files'
# GitHub tokens, variables named like a token, key or password (GITHUB_PAT,
# COINMARKETCAP_APIKEY, ...) and the passwords of .netrc; PATH and the like are not
$names = '([A-Za-z0-9]+_)*(TOKEN|PAT|APIKEY|KEY|SECRET|PASSWORD)(_[A-Za-z0-9]+)*\s*='
$secret = "gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|(^|[^A-Za-z0-9_])$names|(^|\s)password\s+\S"
# a line without its secret, to show
function Hide-Secret([string]$text) {
  $text = $text -creplace '(=\s*["'']?).*', ('$1' + $ellipsis)
  $text = $text -creplace '(gh[pousr]_|github_pat_)[A-Za-z0-9_]+', ('$1' + $ellipsis)
  $text = $text -creplace '(password\s+)\S+', ('$1' + $ellipsis)
  if ($text.Length -gt 70) { $text = $text.Substring(0, 70) }
  return $text
}
# R's ~ is Documents on Windows, so its files can be there as well as in the home folder
$documents = [Environment]::GetFolderPath('MyDocuments')
$psreadline = Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell\PSReadLine'
$files = @(
  "$HOME\.Renviron", "$documents\.Renviron", "$HOME\.Rprofile", "$documents\.Rprofile",
  "$HOME\.bashrc", "$HOME\.bash_profile", "$HOME\.profile", "$HOME\.zshrc",
  "$HOME\.netrc", "$HOME\_netrc", "$HOME\.git-credentials"
) + @(Get-ChildItem -LiteralPath "$documents\WindowsPowerShell", "$documents\PowerShell" -Filter '*profile.ps1' -File -ErrorAction SilentlyContinue |
  ForEach-Object { $_.FullName }) + @(
  "$HOME\.bash_history", "$HOME\.zsh_history", "$HOME\.Rhistory", "$documents\.Rhistory", "$HOME\.python_history"
) + @(Get-ChildItem -LiteralPath $psreadline -Filter '*_history.txt' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
# read as one character per byte, so that each file is written back exactly as it was but for
# the lines taken out, whatever its encoding
$latin1 = [Text.Encoding]::GetEncoding(28591)
$found = $false
foreach ($file in $files | Select-Object -Unique) {
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
  $lines = $latin1.GetString([IO.File]::ReadAllBytes($file)) -split "`n"
  $hits = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -cmatch $secret) { $i } })
  if ($hits.Count -eq 0) { continue }
  $found = $true
  Write-Host "  $(Get-Short $file):"
  foreach ($i in $hits | Select-Object -First 10) {
    $text = [Text.Encoding]::UTF8.GetString($latin1.GetBytes($lines[$i].TrimEnd("`r")))
    Write-Host ('    line {0}: {1}' -f ($i + 1), (Hide-Secret $text))
  }
  if ($hits.Count -gt 10) { Write-Host "    and $($hits.Count - 10) more" }
  if (Test-Yes "  Delete these $($hits.Count) lines from $(Get-Short $file)?") {
    $keep = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($hits -notcontains $i) { $lines[$i] } })
    try {
      [IO.File]::WriteAllBytes($file, $latin1.GetBytes($keep -join "`n"))
      Write-Host '    deleted'
    } catch {
      Write-Host "    could not write it: $($_.Exception.Message)" -ForegroundColor Red
    }
    # a window that is still open keeps the history in memory
    if ($file -like "$psreadline\*") {
      Write-Host '    in the PowerShell windows still open, run: [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory()'
    } elseif ($file -like '*bash_history' -or $file -like '*zsh_history') {
      Write-Host '    in the Git Bash windows still open, run: history -c'
    }
  }
}
# user environment variables named like a token or a key, as setx GITHUB_PAT ... makes them
$variables = @([Environment]::GetEnvironmentVariables('User').Keys |
  Where-Object { $_ -match '^([A-Za-z0-9]+_)*(TOKEN|PAT|APIKEY|KEY|SECRET|PASSWORD)(_[A-Za-z0-9]+)*$' } | Sort-Object)
if ($variables.Count -gt 0) {
  $found = $true
  Write-Host '  user environment variables:'
  $variables | ForEach-Object { Write-Host "    $_=$ellipsis" }
  if (Test-Yes "  Delete these $($variables.Count) variables?") {
    foreach ($name in $variables) { [Environment]::SetEnvironmentVariable($name, $null, 'User') }
    Write-Host '    deleted; programs that are already open keep them until they are closed'
  }
}
if (-not $found) { Write-Host '  none found' }

#####################################################################
Write-Host ''
Write-Title '5. Logins for deploying Shiny apps (rsconnect)'
# where R keeps the settings of packages (tools::R_user_dir), on Windows in AppData\Roaming
$config = if ($env:R_USER_CONFIG_DIR) { $env:R_USER_CONFIG_DIR } else { Join-Path $env:APPDATA 'R\config' }
$accounts = @(Get-ChildItem -Path (Join-Path $config 'R\rsconnect\accounts\*\*.dcf') -File -ErrorAction SilentlyContinue)
if ($accounts.Count -eq 0) { Write-Host '  none' }
foreach ($dcf in $accounts) {
  $account = $dcf.BaseName; $server = $dcf.Directory.Name
  Write-Host "  $account on $server"
  if (Test-Yes "  Remove it? With it, this computer can deploy and delete the apps of $account") {
    Remove-Item -LiteralPath $dcf.FullName -Force
    if (-not (Test-Path -LiteralPath $dcf.FullName)) { Write-Host '    removed' }
  }
}

#####################################################################
Write-Host ''
Write-Title 'What only you can do, on the websites'
Write-Host "  - Delete this computer's key from your GitHub account: https://github.com/settings/keys"
foreach ($fingerprint in $fingerprints) { Write-Host "      $fingerprint" }
Write-Host '  - Sign out the other sessions: https://github.com/settings/sessions'
Write-Host '  - Revoke the tokens and apps you no longer use: https://github.com/settings/tokens'
Write-Host '    and https://github.com/settings/applications'
if ($accounts.Count -gt 0) {
  Write-Host '  - Removing an rsconnect login here does not cancel its token: delete it on the site'
  Write-Host '    too (shinyapps.io: Account > Tokens)'
}
Write-Host '  - Sign out of GitHub and your other accounts in the browsers, and delete saved passwords'
Write-Host "  - Your own files outside $(Get-Short $Folder), such as in Desktop, Documents and Downloads"
if ($kept -gt 0) { exit 1 }
exit 0
