# Adds the shell_scripts folder (the one above this setup folder) to your PATH, so that its
# scripts run by name from any folder, in every new window: git_status_all.ps1 instead of
# & "$HOME\Documents\GitHub\shell_scripts\git_status_all.ps1". The setup scripts, which are
# run once, stay off the PATH. It goes at the end of the PATH of your user (not the
# computer's, so no administrator rights are needed), and into the PATH of this window too.
# Running it again changes nothing.
#   setup\path_add.ps1
# The other folders of the PATH stay as they were, also those written with a name such as
# %USERPROFILE%. Programs that are already running, such as VS Code and the terminals it
# opened, see the new PATH only when started again. To undo it: in the Start menu, open
# "Edit environment variables for your account", then Path, and delete the folder.

if ($args.Count -gt 0) { Write-Host "Unknown argument: $($args[0]) (path_add.ps1 takes none)"; exit 1 }

# the shell_scripts folder, above this one
$folder = Split-Path -Parent $PSScriptRoot

# the same folder, however it is written: with %USERPROFILE%, a \ at the end, other capitals
function Get-Plain([string]$path) {
  [Environment]::ExpandEnvironmentVariables($path.Trim().Trim('"')).TrimEnd('\')
}
function Test-Listed([string]$list) {
  [bool](@($list -split ';') | Where-Object { $_.Trim() -and (Get-Plain $_) -eq (Get-Plain $folder) })
}

# the PATH of the user as Windows keeps it: with names such as %USERPROFILE% not expanded,
# and of the same kind (REG_EXPAND_SZ), so that writing it back changes nothing else
$key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
$path = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
$kind = if ($null -ne $key.GetValue('Path')) { $key.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
if (Test-Listed $path) {
  Write-Host "Already on your PATH: $folder"
} else {
  $new = if ($path.Trim()) { $path.TrimEnd(';') + ';' + $folder } else { $folder }
  $key.SetValue('Path', $new, $kind)
  Write-Host "Added to your PATH: $folder"
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
if (-not (Test-Listed $env:Path)) { $env:Path = $env:Path.TrimEnd(';') + ';' + $folder }
Write-Host 'Its scripts now run by name, such as git_status_all.ps1, in this window and in new ones'
Write-Host '(in VS Code and its terminals once VS Code is started again)'
exit 0
