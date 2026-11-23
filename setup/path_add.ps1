# Adds the shell_scripts folder (the one above this setup folder) and its git, r and monitor
# folders to your PATH, so that their scripts run by name from any folder, in every new window:
# git_status_all.ps1 instead of & "$HOME\Documents\GitHub\shell_scripts\git\git_status_all.ps1",
# and hwrt.ps1 instead of & "$HOME\Documents\GitHub\shell_scripts\monitor\hwrt.ps1". The
# setup scripts, which are run once, stay off the PATH. The folders go at the end of the
# PATH of your user (not the computer's, so no administrator rights are needed), and into
# the PATH of this window too. Running it again changes nothing; after an older run that
# added only some of these folders, it adds the missing ones.
#   setup\path_add.ps1
# The other folders of the PATH stay as they were, also those written with a name such as
# %USERPROFILE%. Programs that are already running, such as VS Code and the terminals it
# opened, see the new PATH only when started again. To undo it: in the Start menu, open
# "Edit environment variables for your account", then Path, and delete the folders.

if ($args.Count -gt 0) { Write-Host "Unknown argument: $($args[0]) (path_add.ps1 takes none)"; exit 1 }

# the shell_scripts folder, above this one, and its folders of scripts to run by name;
# setup\ (run once) and lib\ (loaded by the bash scripts, never run) stay off the PATH
$top = Split-Path -Parent $PSScriptRoot
$folders = @($top)
foreach ($sub in 'git', 'r', 'monitor') {
  $folder = Join-Path $top $sub
  if (Test-Path -LiteralPath $folder -PathType Container) { $folders += $folder }
}

# the same folder, however it is written: with %USERPROFILE%, a \ at the end, other capitals
function Get-Plain([string]$path) {
  [Environment]::ExpandEnvironmentVariables($path.Trim().Trim('"')).TrimEnd('\')
}
function Test-Listed([string]$list, [string]$folder) {
  [bool](@($list -split ';') | Where-Object { $_.Trim() -and (Get-Plain $_) -eq (Get-Plain $folder) })
}
# the list (folders separated by ;) with the folders it does not have yet added at the end
function Add-Missing([string]$list) {
  $missing = @($folders | Where-Object { -not (Test-Listed $list $_) })
  if ($missing.Count -eq 0) { return $list }
  (@($list.TrimEnd(';')) + $missing | Where-Object { $_.Trim() }) -join ';'
}

# the PATH of the user as Windows keeps it: with names such as %USERPROFILE% not expanded,
# and of the same kind (REG_EXPAND_SZ), so that writing it back changes nothing else
$key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
$path = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
$kind = if ($null -ne $key.GetValue('Path')) { $key.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
$missing = @($folders | Where-Object { -not (Test-Listed $path $_) })
$folders | Where-Object { $missing -notcontains $_ } | ForEach-Object { Write-Host "Already on your PATH: $_" }
if ($missing.Count -gt 0) {
  $key.SetValue('Path', (Add-Missing $path), $kind)
  $missing | ForEach-Object { Write-Host "Added to your PATH: $_" }
  # tells the programs that are running (Explorer, and so the windows it opens) that it changed
  if (-not ('PathAdd.Broadcast' -as [type])) {
    Add-Type -Namespace PathAdd -Name Broadcast -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
'@
  }
  $result = [UIntPtr]::Zero
  [void][PathAdd.Broadcast]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
}
$key.Close()

# this window too: the PATH of a window is its own, taken when it opened
$env:Path = Add-Missing $env:Path
Write-Host 'Their scripts now run by name, such as git_status_all.ps1 and hwrt.ps1, in this window and in new ones'
Write-Host '(in VS Code and its terminals once VS Code is started again)'
exit 0
