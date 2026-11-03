# Runs a command on every machine of your list (~\.ssh\machines.txt, the list of
# ssh_setup_keys.ps1, with the same format), and shows what each machine printed and whether
# the command worked there:
#   ssh_run_all.ps1 'sudo apt update && sudo apt full-upgrade -y'
#   ssh_run_all.ps1 'df -h /'
#   ssh_run_all.ps1 uptime
# Put the command in quotes, as one argument: unquoted, PowerShell would take its options for
# the script's own, as it takes any beginning of an option's name (-y for -Yes).
# It shows the command and the machines, and asks before running it. One machine after the
# other (the default) the command can ask you things, such as the password of sudo or a
# question of apt, and what it prints goes straight to this window; with -Parallel all
# machines run at the same time and nothing can be asked (a sudo that needs a password
# fails), and what each machine printed is shown when all are done, and kept in
# %LOCALAPPDATA%\ssh_run_all until the next run. The logins must not ask for a password:
# ssh_setup_keys.ps1 sets that up, and a machine that asks is skipped.
#   ssh_run_all.ps1 [options] command
#   -List ~\servers.txt   another list of machines
#   -Parallel             all machines at the same time
#   -Yes                  runs without asking first
# The exit code is 1 if the command failed on a machine, or a machine could not be reached or
# asked for a password.

param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Command,
  [string]$List,
  [switch]$Parallel,
  [switch]$Yes
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

# starts a program whose output goes to files (Start-Process gives it no terminal, so
# nothing it asks can be answered). Windows PowerShell 5.1 passes arguments to programs in a
# way of its own (it drops empty ones and the quotes inside them), so the command line is
# written here, the same for 5.1 and PowerShell 7. With -Output what it prints goes to that
# file, and its errors to the same name with .err. Returns the process, or with -Wait its
# exit code
function Start-Program([string]$Program, [string[]]$Arguments, [string]$Output, [switch]$Wait) {
  $start = @{
    FilePath     = $Program
    ArgumentList = (($Arguments | ForEach-Object { ConvertTo-Argument $_ }) -join ' ')
    NoNewWindow  = $true
    PassThru     = $true
  }
  if ($Output) { $start.RedirectStandardOutput = $Output; $start.RedirectStandardError = "$Output.err" }
  $process = Start-Process @start
  $null = $process.Handle   # without it Windows PowerShell 5.1 loses the exit code
  if (-not $Wait) { return $process }
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

# what a program printed, and its errors, after Start-Program -Output
function Read-Output([string]$path) {
  $text = ''
  foreach ($part in $path, "$path.err") {
    if (Test-Path -LiteralPath $part) { $text += [IO.File]::ReadAllText($part, [Text.Encoding]::UTF8) }
  }
  return $text
}

# the parts of a line that matter for logging in (port, user, jump host, identity, -o
# settings), and the machine; forwards (-L -R -D), flags such as -N or -t, and a command
# after the machine are left out (the same as in ssh_setup_keys.ps1)
function ConvertFrom-MachineLine([string]$line) {
  $words = @($line.Trim() -split '\s+')
  if ($words[0] -ceq 'ssh') { $words = @($words | Select-Object -Skip 1) }
  $login = @(); $destination = ''
  for ($i = 0; $i -lt $words.Count; $i++) {
    $word = $words[$i]
    if ($word -cmatch '^-[DLRWwOQS]$') { $i++ }
    elseif ($word -cmatch '^-[DLRWwOQS].') { }
    elseif ($word -cmatch '^-[BbcEeFIiJlmopP]$') { $login += $word, $words[$i + 1]; $i++ }
    elseif ($word -cmatch '^-[BbcEeFIiJlmopP].') { $login += $word }
    elseif ($word -ceq '-4' -or $word -ceq '-6') { $login += $word }
    elseif ($word -like '-*') { }
    elseif (-not $destination) { $destination = $word }
    else { break }
  }
  return [pscustomobject]@{ Login = $login; Destination = $destination }
}

# the machine as user@host:port, as ssh resolves the line (with ~\.ssh\config); nothing if
# ssh does not understand it
function Resolve-Machine($machine) {
  if (-not $machine.Destination) { return $null }
  $out = [IO.Path]::GetTempFileName()
  try {
    if ((Start-Program 'ssh' (@('-G') + $machine.Login + $machine.Destination) -Output $out -Wait) -ne 0) { return $null }
    $settings = @{}
    foreach ($line in [IO.File]::ReadAllLines($out)) {
      $name, $value = $line -split ' ', 2
      if ($name -in 'user', 'hostname', 'port', 'proxyjump', 'proxycommand') { $settings[$name] = $value }
    }
    # with the jump host, as the same address behind two jump hosts is two machines
    $via = ''
    foreach ($name in 'proxyjump', 'proxycommand') {
      if ($settings[$name] -and $settings[$name] -ne 'none') { $via = " via $($settings[$name])" }
    }
    return "$($settings.user)@$($settings.hostname):$($settings.port)$via"
  } finally {
    Remove-Item -LiteralPath $out, "$out.err" -ErrorAction SilentlyContinue
  }
}

# the command as one argument, in quotes: words of a command without them can be taken for the
# script's options (a -y for -Yes, which runs without asking). And -Yes written in full, when
# it can be seen how it was written
if ($Command.Count -gt 1) {
  Write-Host "Put the whole command in quotes, its options too, as one argument: ssh_run_all.ps1 'df -h /'"; exit 1
}
if ($Yes -and $MyInvocation.Line -and $MyInvocation.Line -notmatch '(?i)(^|\s)-Yes(\s|:|$)') {
  Write-Host 'Write -Yes in full to run without asking (or put the command in quotes)'; exit 1
}
$commandText = ($Command -join ' ').Trim()
if (-not $commandText) {
  Write-Host "Which command? For example: ssh_run_all.ps1 'df -h /'"; exit 1
}
if (-not $List) { $List = Join-Path (Join-Path $HOME '.ssh') 'machines.txt' }
$List = $List.Trim().Trim('"') -replace '^~', $HOME
if (-not (Test-Path -LiteralPath $List -PathType Leaf)) {
  Write-Host "No list of machines: $List (the top of ssh_setup_keys.ps1 says how to write it)"; exit 1
}
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
  Write-Host 'ssh is needed: Settings > System > Optional features > OpenSSH Client'; exit 1
}
# .NET reads paths from the folder the process started in, not from PowerShell's
$List = (Resolve-Path -LiteralPath $List).ProviderPath

# the machines of the list, each once, as user@host:port
$machines = @(); $seen = @{}; $lineNumber = 0
foreach ($line in [IO.File]::ReadAllLines($List)) {
  $lineNumber++
  $line = $line.Trim()
  if (-not $line -or $line.StartsWith('#')) { continue }
  $machine = ConvertFrom-MachineLine $line
  $name = Resolve-Machine $machine
  if (-not $name) { Write-Host "line $lineNumber is not a machine ssh understands, skipped: $line" -ForegroundColor Yellow; continue }
  if ($seen.ContainsKey($name)) { continue }
  $seen[$name] = $true
  $machine | Add-Member -NotePropertyName Name -NotePropertyValue $name
  $machines += $machine
}
if ($machines.Count -eq 0) { Write-Host "No machines in $List"; exit 1 }

Write-Host 'Command:  ' -NoNewline
Write-Host $commandText -ForegroundColor Cyan
Write-Host "Machines: $(($machines | ForEach-Object { $_.Name }) -join ' ')"
if ($Parallel) { Write-Host 'All at the same time (-Parallel): the command cannot ask anything' }
if (-not $Yes) {
  if ([Console]::IsInputRedirected) { Write-Host 'Not a terminal, so nothing can be asked: add -Yes to run it'; exit 1 }
  if (-not (Test-Yes "Run it on these $($machines.Count) machines?")) { Write-Host 'Nothing was run'; exit 0 }
}

# the ssh command line for a machine: no password asked, and without ssh's own notes such as
# "Connection to ... closed."
function Get-SshArguments($machine, [string[]]$first) {
  return $first + @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'LogLevel=ERROR') + $machine.Login + @($machine.Destination, $commandText)
}

$ok = @(); $failed = @(); $asks = @(); $unreachable = @()
# what happened on a machine, from its exit code. 255 is the code of ssh when it cannot log
# in, but a command can end with it too: a second login, without the command, tells them
# apart, and says why ssh could not log in
function Write-Outcome($machine, [int]$code, [int]$seconds) {
  if ($code -eq 0) {
    Write-Host "  done in ${seconds}s" -ForegroundColor Green; $script:ok += $machine.Name; return
  }
  if ($code -eq 255) {
    $probe = [IO.Path]::GetTempFileName()
    try {
      $status = Start-Program 'ssh' (@('-n', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'LogLevel=ERROR') +
        $machine.Login + @($machine.Destination, 'exit')) -Output $probe -Wait
      $printed = Read-Output $probe
    } finally {
      Remove-Item -LiteralPath $probe, "$probe.err" -ErrorAction SilentlyContinue
    }
    if ($status -ne 0) {
      if ($printed -match 'Permission denied|No more authentication methods') {
        Write-Host '  asks for a password: skipped (ssh_setup_keys.ps1 sets up the key)' -ForegroundColor Yellow; $script:asks += $machine.Name
      } elseif ($printed -match 'Host key verification failed') {
        Write-Host '  not known yet: log in once with ssh to confirm its fingerprint' -ForegroundColor Yellow; $script:unreachable += $machine.Name
      } else {
        $last = @($printed -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
        Write-Host "  cannot reach it: $last" -ForegroundColor Red; $script:unreachable += $machine.Name
      }
      return
    }
  }
  Write-Host "  failed with exit code $code, after ${seconds}s" -ForegroundColor Red; $script:failed += "$($machine.Name) ($code)"
}

if (-not $Parallel) {
  # straight to this window, with a terminal on the machine when there is one here, so that
  # the command can ask you things
  if ([Console]::IsInputRedirected) { $first = @('-n') } else { $first = @('-t') }
  foreach ($machine in $machines) {
    Write-Host ''
    Write-Host ('#' * 80)
    Write-Host $machine.Name -ForegroundColor Cyan
    $start = Get-Date
    # called directly, as only then the terminal is ssh's, so that what you type reaches it
    $arguments = @(Get-SshArguments $machine $first | ForEach-Object { Protect-Argument $_ })
    & ssh @arguments
    $code = $LASTEXITCODE
    Write-Outcome $machine $code ([int]((Get-Date) - $start).TotalSeconds)
  }
} else {
  if ($env:XDG_CACHE_HOME) { $cache = $env:XDG_CACHE_HOME }
  elseif ($env:LOCALAPPDATA) { $cache = $env:LOCALAPPDATA }
  else { $cache = Join-Path $HOME '.cache' }
  $logs = Join-Path $cache 'ssh_run_all'
  if (Test-Path -LiteralPath $logs) { Remove-Item -LiteralPath $logs -Recurse -Force }
  New-Item -ItemType Directory -Path $logs | Out-Null
  $running = @()
  foreach ($machine in $machines) {
    # Windows allows no : in a file name
    $log = Join-Path $logs (($machine.Name -replace '[:\\/]', '_') + '.log')
    $process = Start-Program 'ssh' (Get-SshArguments $machine @('-n')) -Output $log
    $running += [pscustomobject]@{ Machine = $machine; Process = $process; Log = $log; Start = Get-Date; Seconds = 0; Done = $false }
  }
  Write-Host "Running on $($running.Count) machines..."
  $finished = 0
  while ($finished -lt $running.Count) {
    foreach ($run in $running) {
      if (-not $run.Done -and $run.Process.HasExited) {
        $run.Done = $true; $finished++
        $run.Seconds = [int]((Get-Date) - $run.Start).TotalSeconds
        Write-Host "  $($run.Machine.Name) finished ($finished of $($running.Count))"
      }
    }
    Start-Sleep -Milliseconds 200
  }
  foreach ($run in $running) {
    Write-Host ''
    Write-Host ('#' * 80)
    Write-Host $run.Machine.Name -ForegroundColor Cyan
    $printed = Read-Output $run.Log
    if ($printed) { Write-Host $printed.TrimEnd() }
    Write-Outcome $run.Machine $run.Process.ExitCode $run.Seconds
  }
}

Write-Host ''
Write-Host ('#' * 80)
if ($ok.Count -gt 0) { Write-Host "Done on: $($ok -join ' ')" -ForegroundColor Green }
if ($failed.Count -gt 0) { Write-Host "Failed on: $($failed -join ' ')" -ForegroundColor Red }
if ($asks.Count -gt 0) { Write-Host "Ask for a password, skipped: $($asks -join ' ')" -ForegroundColor Yellow }
if ($unreachable.Count -gt 0) { Write-Host "Could not reach: $($unreachable -join ' ')" -ForegroundColor Red }
if ($Parallel) { Write-Host "What each machine printed: $logs" }
if ($failed.Count -gt 0 -or $unreachable.Count -gt 0 -or $asks.Count -gt 0) { exit 1 }
exit 0
