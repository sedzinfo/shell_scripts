# hwrt.sh for Windows: RAM, CPU speed and load, the GPUs, temperatures and fans, refreshed
# every 5 seconds; it beeps when less than 3000 MB of RAM is available. Ctrl+C to quit.
# Windows itself reports only the temperatures of its ACPI thermal zones and no fan speeds;
# while LibreHardwareMonitor (or OpenHardwareMonitor) runs, it shows all of theirs instead.

# a line of 80 # characters, between the sections
$separator = '#' * 80
# the degree sign as a code point, as Windows PowerShell reads a script without a BOM as ANSI
$degrees = [char]0xB0
$invariant = [Globalization.CultureInfo]::InvariantCulture

# one line in three aligned columns: name, reading, details
function Format-Row([string]$name, [string]$reading, [string]$details) {
  '{0,-15} {1,10}   {2}' -f $name, $reading, $details
}

# a temperature as +45.0 C (with a dot, whatever the language of Windows)
function Format-Celsius([double]$value) {
  '+' + $value.ToString('0.0', $invariant) + $degrees + 'C'
}

# the processor, which does not change
$processors = @(Get-CimInstance Win32_Processor)
$cpu_name = $processors[0].Name.Trim()
$cpu_base = $processors[0].MaxClockSpeed
$cores = ($processors | Measure-Object NumberOfCores -Sum).Sum
$threads = ($processors | Measure-Object NumberOfLogicalProcessors -Sum).Sum

# the graphics adapters, each with the id that the GPU counters of Windows name it by
# (DirectX keeps it in the registry); the Microsoft Basic Render Driver (vendor 0x1414) is no GPU
$adapters = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\DirectX' -ErrorAction SilentlyContinue | ForEach-Object {
  $p = Get-ItemProperty $_.PSPath
  if ($null -ne $p.AdapterLuid -and $p.VendorId -ne 0x1414) {
    $luid = [int64]$p.AdapterLuid
    [pscustomobject]@{
      Name   = $p.Description
      Luid   = 'luid_0x{0:x8}_0x{1:x8}' -f ($luid -shr 32), ($luid -band 0xFFFFFFFF)
      Nvidia = $p.VendorId -eq 0x10DE
    }
  }
} | Sort-Object Luid -Unique)
$nvidia_smi = [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue)

# how busy each GPU is, as Task Manager counts it: per engine, the sum over the programs
# using it, and for the GPU its busiest engine
function Get-GpuBusy {
  $busy = @{}
  try {
    $engines = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop
  } catch {
    return $busy
  }
  $sums = @{}
  foreach ($engine in $engines) {
    if ($engine.Name -match '(luid_0x[0-9A-Fa-f]+_0x[0-9A-Fa-f]+)_phys_(\d+)_eng_(\d+)') {
      $key = "$($Matches[1].ToLower())|$($Matches[2])|$($Matches[3])"
      $sums[$key] = [int]$sums[$key] + [int]$engine.UtilizationPercentage
    }
  }
  foreach ($key in $sums.Keys) {
    $luid = $key.Split('|')[0]
    $busy[$luid] = [math]::Max([int]$busy[$luid], [math]::Min(100, $sums[$key]))
  }
  return $busy
}

# the NVIDIA cards by name: temperature, clock and memory
function Get-NvidiaDetails {
  $details = @{}
  if (-not $nvidia_smi) { return $details }
  nvidia-smi --query-gpu=name,temperature.gpu,clocks.gr,clocks.max.gr,memory.used,memory.total --format=csv,noheader,nounits 2> $null |
    ForEach-Object {
      $f = $_ -split ',\s*'
      if ($f.Count -ge 6) {
        $details[$f[0].Trim()] = "$($f[1])$($degrees)C, $($f[2]) of $($f[3]) MHz, memory $($f[4]) of $($f[5]) MB"
      }
    }
  return $details
}

# LibreHardwareMonitor or OpenHardwareMonitor, while one of them runs: its namespace
$monitor = $null
foreach ($namespace in 'root/LibreHardwareMonitor', 'root/OpenHardwareMonitor') {
  try {
    Get-CimInstance -Namespace $namespace -ClassName Sensor -ErrorAction Stop | Select-Object -First 1 | Out-Null
    $monitor = $namespace
    break
  } catch { }
}

# the screen is cleared only once; after that each refresh is written over the
# previous one, so it does not flash (when the output goes to a file, refreshes follow each other)
$interactive = -not [Console]::IsOutputRedirected
if ($interactive) {
  Clear-Host
  [Console]::CursorVisible = $false
}
$previous = 0

try {
  while ($true) {
    $os = Get-CimInstance Win32_OperatingSystem
    $available = [int]($os.FreePhysicalMemory / 1024)
    $total = [int]($os.TotalVisibleMemorySize / 1024)
    try {
      $load = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
      $cpu_now = "$([int]($cpu_base * $load.PercentProcessorPerformance / 100)) MHz"
      $cpu_load = "load $([math]::Min(100, [int]$load.PercentProcessorUtility))%, "
    } catch {
      $cpu_now = '..'; $cpu_load = ''
    }
    $gpu_busy = Get-GpuBusy
    $nvidia = Get-NvidiaDetails

    # the whole screen is collected first and printed at once
    $screen = @(
      $separator
      "AVAILABLE RAM : $available MB of $total MB"
      $separator
      Format-Row 'CPU' $cpu_now "${cpu_load}base $cpu_base MHz, $cores cores, $threads threads, $cpu_name"
      $separator
      foreach ($adapter in $adapters) {
        $busy = if ($gpu_busy.ContainsKey($adapter.Luid)) { "busy $($gpu_busy[$adapter.Luid])%" } else { 'busy ..' }
        $extra = if ($adapter.Nvidia -and $nvidia.ContainsKey($adapter.Name)) { ", $($nvidia[$adapter.Name])" } else { '' }
        Format-Row 'GPU' $busy "$($adapter.Name)$extra"
      }
      if ($adapters.Count -gt 0) { $separator }

      if ($monitor) {
        # every sensor of the hardware monitor, by the hardware it belongs to
        $hardware = @{}
        Get-CimInstance -Namespace $monitor -ClassName Hardware | ForEach-Object { $hardware[$_.Identifier] = $_.Name }
        $sensors = @(Get-CimInstance -Namespace $monitor -ClassName Sensor | Sort-Object Parent, Identifier)
        foreach ($sensor in $sensors | Where-Object SensorType -eq 'Temperature') {
          Format-Row $sensor.Name (Format-Celsius $sensor.Value) $hardware[$sensor.Parent]
        }
        $separator
        $fans = @($sensors | Where-Object SensorType -eq 'Fan')
        foreach ($sensor in $fans) {
          Format-Row $sensor.Name "$([int]$sensor.Value) RPM" $hardware[$sensor.Parent]
        }
        if ($fans.Count -eq 0) { 'no fan' }
      } else {
        $zones = @(Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction SilentlyContinue)
        foreach ($zone in $zones) {
          $kelvin = if ($zone.HighPrecisionTemperature -gt 0) { $zone.HighPrecisionTemperature / 10 } else { $zone.Temperature }
          Format-Row ($zone.Name -replace '^.*\.', '') (Format-Celsius ($kelvin - 273.15)) 'ACPI thermal zone'
        }
        if ($zones.Count -eq 0) { 'no temperatures' }
        'CPU temperatures and fans: run LibreHardwareMonitor (as administrator), which this shows'
        $separator
        'no fan speeds: Windows does not report them'
      }
      $separator
    )

    if ($interactive) {
      # back to the top, each line cleared to its end, then anything left below
      $width = [Console]::WindowWidth - 1
      [Console]::SetCursorPosition(0, 0)
      foreach ($line in $screen) {
        if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
        [Console]::WriteLine($line.PadRight($width))
      }
      for ($i = $screen.Count; $i -lt $previous; $i++) { [Console]::WriteLine(''.PadRight($width)) }
      $previous = $screen.Count
    } else {
      $screen
      ''
    }

    if ($available -lt 3000) {
      try { [Console]::Beep(1000, 1000) } catch { }
    }
    Start-Sleep -Seconds 5
  }
} finally {
  # the cursor comes back on Ctrl+C
  if ($interactive) { [Console]::CursorVisible = $true }
}
