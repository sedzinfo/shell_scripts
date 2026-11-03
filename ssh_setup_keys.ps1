# Sets up passwordless SSH logins, with your key instead of a password, to every machine
# listed in a text file, ~\.ssh\machines.txt unless another is given. Nothing creates that
# file: make it yourself, with any text editor
#   notepad $HOME\.ssh\machines.txt
# and write one machine per line, as you would type it:
#   # Raspberry Pis
#   ssh dimitrios@192.168.1.10
#   ssh dimitrios@myhost.example.com -p 5000
#   ssh -L 8080:192.168.1.1:80 dimitrios@myhost.example.com -p 1515
#   pi@raspberrypi.local
#   ssh pip0                          (a Host of ~\.ssh\config)
# Empty lines and lines starting with # are skipped. The port is -p (lowercase): with -P
# ssh uses port 22. ssh reads each line itself (ssh -G), so your ~\.ssh\config applies, and
# forwards such as -L are left out. To add a machine later, add its line and run the script
# again: the machines that already work are left as they are. The list has no secrets: copy
# it to your other computers, but keep it out of public repositories, and run the script on
# each computer (each one has its own key; never copy a private key).
# It uses the key you already have (~\.ssh\id_ed25519, id_ecdsa or id_rsa, in that order,
# or the one given with -Key), and only when there is none it asks to create one; a key is
# never replaced. For each machine it:
#   - checks whether you can already log in without a password; if so the machine is left
#     as it is
#   - otherwise adds your public key to ~/.ssh/authorized_keys there, as ssh-copy-id does
#     (which Windows does not have): ssh asks for the password of the machine once, the key
#     is added only if it is missing, and ~/.ssh gets the permissions sshd requires
#   - checks that the login now works without a password
#   ssh_setup_keys.ps1 [file]               default ~\.ssh\machines.txt
#   ssh_setup_keys.ps1 -Key ~\.ssh\id_rsa   copies this key instead
#   ssh_setup_keys.ps1 -Check               only checks which machines need no password
# The machines must run Linux, macOS or another system with a POSIX shell, such as Raspberry
# Pi OS. The exit code is 1 if a machine still asks for a password or cannot be reached.

param(
  [Parameter(Position = 0)]
  [string]$File,
  [string]$Key,
  [switch]$Check
)

# anything but y/yes is no. Not Read-Host: in PowerShell on Linux and macOS it keeps
# reading the terminal afterwards, and what you then type for ssh (a password) is lost
function Test-Yes([string]$question) {
  Write-Host "$question [y/N]: " -NoNewline
  $answer = [Console]::ReadLine()
  return $answer -match '^\s*y(es)?\s*$'
}

# an argument as a program's command line needs it: in double quotes when it has spaces or
# quotes, with the quotes (and the backslashes before them) escaped
function ConvertTo-Argument([string]$value) {
  if ($value -ne '' -and $value -notmatch '[\s"]') { return $value }
  return '"' + (($value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

# runs a program whose output goes to files and waits for it (Start-Process gives it no
# terminal, so nothing it asks can be answered). Windows PowerShell 5.1 passes arguments to
# programs in a way of its own (it drops empty ones and the quotes inside them), so the command line is
# written here, the same for 5.1 and PowerShell 7. With -Output what it prints goes to that
# file, and its errors to the same name with .err; with -InputFile it reads that file.
# Returns the exit code
function Invoke-Program([string]$Program, [string[]]$Arguments, [string]$Output, [string]$InputFile) {
  $start = @{
    FilePath     = $Program
    ArgumentList = (($Arguments | ForEach-Object { ConvertTo-Argument $_ }) -join ' ')
    NoNewWindow  = $true
    PassThru     = $true
  }
  if ($Output) { $start.RedirectStandardOutput = $Output; $start.RedirectStandardError = "$Output.err" }
  if ($InputFile) { $start.RedirectStandardInput = $InputFile }
  $process = Start-Process @start
  $null = $process.Handle   # without it Windows PowerShell 5.1 loses the exit code
  $process.WaitForExit()
  return $process.ExitCode
}

# Windows PowerShell 5.1 and PowerShell before 7.3 drop the quotes inside the arguments they
# give to programs; for those, the quotes (and the backslashes before them) are escaped here
$legacyArguments = $PSVersionTable.PSVersion -lt [version]'7.3' -or
  (Get-Variable PSNativeCommandArgumentPassing -ValueOnly -ErrorAction SilentlyContinue) -eq 'Legacy'
function Protect-Argument([string]$value) {
  if (-not $legacyArguments) { return $value }
  $value = $value -replace '(\\*)"', '$1$1\"'
  if ($value -match '\s') { $value = $value -replace '(\\+)$', '$1$1' }
  return $value
}

# what a program printed, and its errors, after Invoke-Program -Output
function Read-Output([string]$path) {
  $text = ''
  foreach ($part in $path, "$path.err") {
    if (Test-Path -LiteralPath $part) { $text += [IO.File]::ReadAllText($part, [Text.Encoding]::UTF8) }
  }
  return $text
}

# whether a private key has a passphrase: an OpenSSH key names its cipher ("none" without a
# passphrase), an older PEM key says ENCRYPTED
function Test-Passphrase([string]$path) {
  $text = [IO.File]::ReadAllText($path)
  if ($text -match 'ENCRYPTED') { return $true }
  if ($text -notmatch '-----BEGIN OPENSSH PRIVATE KEY-----([A-Za-z0-9+/=\s]+)-----END') { return $false }
  $bytes = [Convert]::FromBase64String(($Matches[1] -replace '\s', ''))
  # after "openssh-key-v1" and a zero byte comes the length of the cipher name, then the name
  $length = ([int]$bytes[15] -shl 24) -bor ([int]$bytes[16] -shl 16) -bor ([int]$bytes[17] -shl 8) -bor $bytes[18]
  return [Text.Encoding]::ASCII.GetString($bytes, 19, $length) -ne 'none'
}

# the parts of a line that matter for logging in (port, user, jump host, identity, -o
# settings), and the machine; forwards (-L -R -D), flags such as -N or -t, and a command
# after the machine are left out. Options are case-sensitive: -p is the port, -P a tag
function ConvertFrom-MachineLine([string]$line) {
  $words = @($line.Trim() -split '\s+')
  if ($words[0] -ceq 'ssh') { $words = @($words | Select-Object -Skip 1) }
  $login = @(); $skipped = @(); $destination = ''; $warning = ''
  for ($i = 0; $i -lt $words.Count; $i++) {
    $word = $words[$i]
    if ($word -cmatch '^-[DLRWwOQS]$') { $skipped += "$word $($words[$i + 1])"; $i++ }
    elseif ($word -cmatch '^-[DLRWwOQS].') { $skipped += $word }
    elseif ($word -ceq '-P') {
      if ($words[$i + 1] -match '^\d+$') { $warning = "-P $($words[$i + 1])" }
      $login += $word, $words[$i + 1]; $i++
    }
    elseif ($word -cmatch '^-[BbcEeFIiJlmop]$') { $login += $word, $words[$i + 1]; $i++ }
    elseif ($word -cmatch '^-[BbcEeFIiJlmopP].') { $login += $word }
    elseif ($word -ceq '-4' -or $word -ceq '-6') { $login += $word }
    elseif ($word -like '-*') { }
    elseif (-not $destination) { $destination = $word }
    else { break }
  }
  return [pscustomobject]@{ Login = $login; Destination = $destination; Skipped = $skipped; PortWarning = $warning }
}

# the machine as user@host:port, as ssh resolves the line (with ~\.ssh\config); nothing if
# ssh does not understand it
function Resolve-Machine($machine) {
  if (-not $machine.Destination) { return $null }
  $out = [IO.Path]::GetTempFileName()
  try {
    if ((Invoke-Program 'ssh' (@('-G') + $machine.Login + $machine.Destination) -Output $out) -ne 0) { return $null }
    $settings = @{}
    foreach ($line in [IO.File]::ReadAllLines($out)) {
      $name, $value = $line -split ' ', 2
      if ($name -in 'user', 'hostname', 'port') { $settings[$name] = $value }
    }
    return "$($settings.user)@$($settings.hostname):$($settings.port)"
  } finally {
    Remove-Item -LiteralPath $out, "$out.err" -ErrorAction SilentlyContinue
  }
}

# whether ssh logs in without asking anything; the error, if not, in $script:loginError
function Test-Login($machine) {
  $out = [IO.Path]::GetTempFileName()
  try {
    $arguments = @('-n', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10') + $machine.Login + @($machine.Destination, 'true')
    $code = Invoke-Program 'ssh' $arguments -Output $out
    $script:loginError = (Read-Output $out).Trim()
    return $code -eq 0
  } finally {
    Remove-Item -LiteralPath $out, "$out.err" -ErrorAction SilentlyContinue
  }
}

# the last line of a message
function Get-LastLine([string]$text) { return @($text -split "`r?`n" | Where-Object { $_ })[-1] }

$sshFolder = Join-Path $HOME '.ssh'
if (-not $File) { $File = Join-Path $sshFolder 'machines.txt' }
$File = $File.Trim().Trim('"') -replace '^~', $HOME
if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
  Write-Host "No list of machines: $File"
  Write-Host "Make it with any text editor, for example: notepad $File"
  Write-Host 'and write one machine per line, as you would type it:'
  Write-Host '  ssh dimitrios@192.168.1.10'
  Write-Host '  ssh dimitrios@myhost.example.com -p 5000'
  Write-Host '(the top of this script says more)'
  exit 1
}
# .NET reads paths from the folder the process started in, not from PowerShell's
$File = (Resolve-Path -LiteralPath $File).ProviderPath
foreach ($program in 'ssh', 'ssh-keygen') {
  if (-not (Get-Command $program -ErrorAction SilentlyContinue)) {
    Write-Host "$program is needed: Settings > System > Optional features > OpenSSH Client"
    exit 1
  }
}

# the key to copy: the one given, or the first one you have
if ($Key) {
  $Key = ($Key.Trim().Trim('"') -replace '^~', $HOME) -replace '\.pub$', ''
  if (Test-Path -LiteralPath $Key) { $Key = (Resolve-Path -LiteralPath $Key).ProviderPath }
} else {
  foreach ($name in 'id_ed25519', 'id_ecdsa', 'id_rsa') {
    $candidate = Join-Path $sshFolder $name
    if ((Test-Path -LiteralPath $candidate) -and (Test-Path -LiteralPath "$candidate.pub")) { $Key = $candidate; break }
  }
}
if (-not $Key) {
  Write-Host 'You have no SSH key yet (~\.ssh\id_ed25519, id_ecdsa or id_rsa).'
  if ($Check -or -not (Test-Yes 'Create one now (ssh-keygen -t ed25519)?')) { exit 1 }
  Write-Host 'A passphrase encrypts the key on this computer; with an empty one (Enter) nothing is ever asked.'
  if (-not (Test-Path -LiteralPath $sshFolder)) { New-Item -ItemType Directory -Path $sshFolder | Out-Null }
  $Key = Join-Path $sshFolder 'id_ed25519'
  $comment = "$([Environment]::UserName)@$([Environment]::MachineName)"
  & ssh-keygen -t ed25519 -C (Protect-Argument $comment) -f (Protect-Argument $Key)
  if ($LASTEXITCODE -ne 0) { exit 1 }
} elseif (-not (Test-Path -LiteralPath "$Key.pub")) {
  Write-Host "No public key $Key.pub"; exit 1
}
$out = [IO.Path]::GetTempFileName()
$null = Invoke-Program 'ssh-keygen' @('-l', '-f', "$Key.pub") -Output $out
$fingerprint = @((Read-Output $out).Trim() -split '\s+')
Remove-Item -LiteralPath $out, "$out.err" -ErrorAction SilentlyContinue
Write-Host "Key: $Key.pub ($($fingerprint[1]) $($fingerprint[-1]))"

# a key with a passphrase logs in without asking only once ssh-agent holds it; on Windows
# the ssh-agent service is off until it is turned on, as administrator
if (Test-Passphrase $Key) {
  $out = [IO.Path]::GetTempFileName()
  $agent = Invoke-Program 'ssh-add' @('-l') -Output $out
  $held = (Read-Output $out).Contains($fingerprint[1])
  Remove-Item -LiteralPath $out, "$out.err" -ErrorAction SilentlyContinue
  if ($held) {
  } elseif ($agent -ne 2 -and -not $Check) {
    Write-Host 'The key has a passphrase: ssh-add asks for it once, so that no login asks for it again'
    & ssh-add (Protect-Argument $Key)
  } else {
    Write-Host 'The key has a passphrase and ssh-agent is not running: logins will ask for the passphrase.' -ForegroundColor Yellow
    Write-Host '  To turn it on for good, in PowerShell as administrator:'
    Write-Host '  Get-Service ssh-agent | Set-Service -StartupType Automatic; Start-Service ssh-agent'
  }
}
if ($Check) { Write-Host 'Check only: no key is copied' }

# what a machine runs to add the key it reads, as ssh-copy-id does: only if it is not there
# yet, after a line break if the file does not end with one, without the \r of Windows
$addKey = 'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; key=$(tr -d ''\r''); ' +
  'grep -qxF "$key" ~/.ssh/authorized_keys || { [ -z "$(tail -c 1 ~/.ssh/authorized_keys)" ] || echo >> ~/.ssh/authorized_keys; echo "$key" >> ~/.ssh/authorized_keys; }; ' +
  'chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'
$publicKey = [IO.File]::ReadAllText("$Key.pub").Trim()

$asks = @(); $unreachable = @(); $already = 0; $setUp = 0; $lineNumber = 0; $seen = @{}
foreach ($line in [IO.File]::ReadAllLines($File)) {
    $lineNumber++
    $line = $line.Trim()
    if (-not $line -or $line.StartsWith('#')) { continue }
    $machine = ConvertFrom-MachineLine $line
    Write-Host ''
    Write-Host ('#' * 80)
    $name = Resolve-Machine $machine
    if (-not $name) {
      Write-Host "line ${lineNumber}: not a machine ssh understands: $line" -ForegroundColor Red
      $unreachable += "line $lineNumber"; continue
    }
    Write-Host $name -ForegroundColor Cyan -NoNewline
    Write-Host "  ($line)"
    if ($machine.Skipped.Count -gt 0) { Write-Host "  left out, not needed for the key: $($machine.Skipped -join ' ')" }
    if ($machine.PortWarning) {
      Write-Host "  $($machine.PortWarning) is not a port for ssh, so this is port $(($name -split ':')[-1]): ssh takes the port with -p (lowercase)" -ForegroundColor Yellow
    }
    if ($seen.ContainsKey($name)) { Write-Host "  the same machine as line $($seen[$name])"; continue }
    $seen[$name] = $lineNumber

    if (Test-Login $machine) {
      Write-Host '  already logs in without a password' -ForegroundColor Green
      $already++; continue
    }
    if ($script:loginError -notmatch 'Permission denied|Host key verification failed|No more authentication methods') {
      Write-Host "  cannot reach it: $(Get-LastLine $script:loginError)" -ForegroundColor Red
      $unreachable += $name; continue
    }
    if ($Check) {
      if ($script:loginError -match 'Host key verification failed') {
        Write-Host '  not known yet: the first login asks you to confirm its fingerprint' -ForegroundColor Yellow
      } else {
        Write-Host '  asks for a password' -ForegroundColor Yellow
      }
      $asks += $name; continue
    }

    Write-Host "  copying your key: ssh asks for the password of $name once"
    # called directly, as only then the terminal is ssh's, so that the password you type reaches it
    $arguments = @($machine.Login + @($machine.Destination, $addKey) | ForEach-Object { Protect-Argument $_ })
    $publicKey | & ssh @arguments
    if ($LASTEXITCODE -ne 0) {
      Write-Host '  the key could not be copied' -ForegroundColor Red
      $asks += $name; continue
    }
    if (Test-Login $machine) {
      Write-Host '  logs in without a password now' -ForegroundColor Green
      $setUp++
    } else {
      Write-Host "  still asks for a password: $(Get-LastLine $script:loginError)" -ForegroundColor Red
      Write-Host '    the machine may not accept keys (PubkeyAuthentication no in /etc/ssh/sshd_config)'
      $asks += $name
    }
  }
Write-Host ''
Write-Host ('#' * 80)
if ($already -gt 0) { Write-Host "Already without a password: $already" -ForegroundColor Green }
if ($setUp -gt 0) { Write-Host "Without a password now: $setUp" -ForegroundColor Green }
if ($asks.Count -gt 0) { Write-Host "Still ask for a password: $($asks -join ' ')" -ForegroundColor Yellow }
if ($unreachable.Count -gt 0) { Write-Host "Could not reach: $($unreachable -join ' ')" -ForegroundColor Red }
if ($asks.Count -gt 0 -or $unreachable.Count -gt 0) { exit 1 }
exit 0
