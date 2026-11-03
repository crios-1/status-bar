# SysWidget - compact always-on-top system monitor (CPU / RAM / disks)
# Drag with left mouse; right-click for menu (close). Uses WMI perf classes (locale independent).
param([int]$IntervalMs = 1500, [switch]$SelfTest)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SysWidget" Width="260" SizeToContent="Height" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent" Topmost="True"
        ShowInTaskbar="False" ResizeMode="NoResize">
  <Border CornerRadius="10" Background="#E61E1E24" BorderBrush="#33FFFFFF" BorderThickness="1" Padding="12,10">
    <StackPanel>
      <Grid Margin="0,0,0,6">
        <TextBlock Text="SYSTEM" Foreground="#8899AA" FontSize="11" FontWeight="Bold"/>
        <TextBlock x:Name="Close" Text="&#x2715;" Foreground="#8899AA" FontSize="11" HorizontalAlignment="Right" Cursor="Hand"/>
      </Grid>
      <StackPanel x:Name="Rows"/>
    </StackPanel>
  </Border>
</Window>
"@

$win  = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$rows = $win.FindName('Rows')
$conv = New-Object Windows.Media.BrushConverter

function New-Row([string]$label) {
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = '0,4,0,4'
    $g = New-Object Windows.Controls.Grid
    $l = New-Object Windows.Controls.TextBlock -Property @{ Text = $label; Foreground = $conv.ConvertFrom('#DDE3EA'); FontSize = 12; FontFamily = 'Segoe UI Semibold' }
    $v = New-Object Windows.Controls.TextBlock -Property @{ Foreground = $conv.ConvertFrom('#DDE3EA'); FontSize = 12; FontFamily = 'Consolas'; HorizontalAlignment = 'Right' }
    [void]$g.Children.Add($l); [void]$g.Children.Add($v)
    $bar = New-Object Windows.Controls.ProgressBar -Property @{ Height = 5; Minimum = 0; Maximum = 100; Margin = '0,3,0,0'; BorderThickness = 0; Background = $conv.ConvertFrom('#33FFFFFF') }
    $sub = New-Object Windows.Controls.TextBlock -Property @{ Foreground = $conv.ConvertFrom('#8899AA'); FontSize = 10; FontFamily = 'Consolas'; Margin = '0,2,0,0' }
    [void]$sp.Children.Add($g); [void]$sp.Children.Add($bar); [void]$sp.Children.Add($sub)
    [void]$rows.Children.Add($sp)
    @{ Value = $v; Bar = $bar; Sub = $sub }
}

function Set-Bar($row, [double]$pct) {
    $row.Bar.Value = $pct
    $c = if ($pct -ge 90) { '#E5534B' } elseif ($pct -ge 70) { '#E0A03A' } else { '#4CB782' }
    $row.Bar.Foreground = $conv.ConvertFrom($c)
}

function Format-Bytes([double]$b) {
    if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) } elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b / 1KB) } else { '{0:N0} B' -f $b }
}

$cpuRow = New-Row 'CPU'
$memRow = New-Row 'Memory'
$diskIoRow = New-Row 'Disk activity'
$driveRows = @{}

function Update-Stats {
    try {
        $cpu = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
        $cpuRow.Value.Text = '{0,3}%' -f $cpu
        Set-Bar $cpuRow $cpu
        $cpuRow.Sub.Text = "$env:NUMBER_OF_PROCESSORS logical cores"

        $os = Get-CimInstance Win32_OperatingSystem
        $tot = $os.TotalVisibleMemorySize * 1KB; $free = $os.FreePhysicalMemory * 1KB; $used = $tot - $free
        $mp = [math]::Round($used / $tot * 100)
        $memRow.Value.Text = '{0,3}%' -f $mp
        Set-Bar $memRow $mp
        $memRow.Sub.Text = '{0} / {1}' -f (Format-Bytes $used), (Format-Bytes $tot)

        $io = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
        $act = [math]::Min(100, [math]::Round(100 - $io.PercentIdleTime))
        $diskIoRow.Value.Text = '{0,3}%' -f $act
        Set-Bar $diskIoRow $act
        $diskIoRow.Sub.Text = 'R {0}/s  W {1}/s' -f (Format-Bytes $io.DiskReadBytesPersec), (Format-Bytes $io.DiskWriteBytesPersec)

        foreach ($d in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
            if (-not $driveRows[$d.Name]) { $driveRows[$d.Name] = New-Row ("Drive " + $d.Name.TrimEnd('\')) }
            $r = $driveRows[$d.Name]
            $u = $d.TotalSize - $d.AvailableFreeSpace
            $p = [math]::Round($u / $d.TotalSize * 100)
            $r.Value.Text = '{0,3}%' -f $p
            Set-Bar $r $p
            $r.Sub.Text = '{0} free of {1}' -f (Format-Bytes $d.AvailableFreeSpace), (Format-Bytes $d.TotalSize)
        }
    } catch { $cpuRow.Sub.Text = "Error: $($_.Exception.Message)" }
}

# Remember position between runs
$posFile = Join-Path $env:APPDATA 'SysWidget.pos'
if (Test-Path $posFile) {
    $p = (Get-Content $posFile) -split ','
    $win.WindowStartupLocation = 'Manual'; $win.Left = [double]$p[0]; $win.Top = [double]$p[1]
} else {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $win.WindowStartupLocation = 'Manual'; $win.Left = $wa.Right - 280; $win.Top = $wa.Top + 20
}

$win.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch {} })
$win.FindName('Close').Add_MouseLeftButtonUp({ $win.Close() })
$menu = New-Object Windows.Controls.ContextMenu
$mi = New-Object Windows.Controls.MenuItem -Property @{ Header = 'Close' }
$mi.Add_Click({ $win.Close() }); [void]$menu.Items.Add($mi)
$win.ContextMenu = $menu
$win.Add_Closing({ try { "{0},{1}" -f [int]$win.Left, [int]$win.Top | Set-Content $posFile } catch {} })

Update-Stats
if ($SelfTest) {
    "CPU: $($cpuRow.Value.Text) | MEM: $($memRow.Value.Text) $($memRow.Sub.Text) | IO: $($diskIoRow.Value.Text) $($diskIoRow.Sub.Text)"
    $driveRows.Keys | ForEach-Object { "$_ $($driveRows[$_].Value.Text) $($driveRows[$_].Sub.Text)" }
    return
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds($IntervalMs)
$timer.Add_Tick({ Update-Stats })
$timer.Start()
[void]$win.ShowDialog()
