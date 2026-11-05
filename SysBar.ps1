# SysBar - status bar docked to the top of a monitor (CPU / RAM / disk / drives / Claude sessions).
# Registers as a Windows "AppBar" so maximized windows leave room for it.
# -Monitor <n> picks the screen (0 = primary). Right-click the bar to close.
param([int]$Monitor = 0, [int]$IntervalMs = 1500, [int]$HeightDip = 26, [switch]$SelfTest)

# Only one bar per monitor: a second start (shortcut + scheduled task, double-click) exits quietly
$script:mutex = New-Object System.Threading.Mutex($false, "Local\SysBar-Monitor$Monitor")
if (-not $SelfTest -and -not $script:mutex.WaitOne(0)) { return }

# Errors at startup are otherwise invisible (hidden window), so keep a small log
$logFile = Join-Path $PSScriptRoot 'sysbar.log'
try { "$(Get-Date -Format s)  started (pid $PID, monitor $Monitor)" | Add-Content $logFile -ErrorAction Stop } catch {}
trap { try { "$(Get-Date -Format s)  $($_.Exception.Message)  @ $($_.InvocationInfo.PositionMessage)" | Add-Content $logFile -ErrorAction Stop } catch {}; break }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class AppBar {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct APPBARDATA {
        public int cbSize; public IntPtr hWnd; public uint uCallbackMessage; public uint uEdge; public RECT rc; public IntPtr lParam;
    }
    [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint msg, ref APPBARDATA data);
    [DllImport("user32.dll")] static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
    [DllImport("user32.dll")] static extern uint RegisterWindowMessage(string s);
    public static uint CallbackMsg = RegisterWindowMessage("SysBarAppBarMsg");
    const uint ABM_NEW = 0, ABM_REMOVE = 1, ABM_QUERYPOS = 2, ABM_SETPOS = 3, ABE_TOP = 1;

    public static void Dock(IntPtr hwnd, int left, int top, int right, int height, bool isNew) {
        var d = new APPBARDATA(); d.cbSize = Marshal.SizeOf(d); d.hWnd = hwnd; d.uEdge = ABE_TOP;
        if (isNew) { d.uCallbackMessage = CallbackMsg; SHAppBarMessage(ABM_NEW, ref d); }
        d.rc.left = left; d.rc.right = right; d.rc.top = top; d.rc.bottom = top + height;
        SHAppBarMessage(ABM_QUERYPOS, ref d);
        d.rc.bottom = d.rc.top + height;
        SHAppBarMessage(ABM_SETPOS, ref d);
        MoveWindow(hwnd, d.rc.left, d.rc.top, d.rc.right - d.rc.left, height, true);
    }
    public static void Remove(IntPtr hwnd) {
        var d = new APPBARDATA(); d.cbSize = Marshal.SizeOf(d); d.hWnd = hwnd;
        SHAppBarMessage(ABM_REMOVE, ref d);
    }
}
"@

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SysBar" WindowStyle="None" ResizeMode="NoResize" Topmost="True"
        ShowInTaskbar="False" Background="#F01A1B20" Width="800" Height="26">
  <Grid Margin="10,0">
    <StackPanel x:Name="Stats" Orientation="Horizontal" VerticalAlignment="Center"/>
    <TextBlock x:Name="Clock" HorizontalAlignment="Center" VerticalAlignment="Center"
               Foreground="#E6EAF0" FontFamily="Segoe UI Semibold" FontSize="12"/>
    <StackPanel x:Name="Drives" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center"/>
  </Grid>
</Window>
"@

$win    = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$stats  = $win.FindName('Stats')
$drives = $win.FindName('Drives')
$clock  = $win.FindName('Clock')
$conv   = New-Object Windows.Media.BrushConverter

# Icons come from the Windows 11 built-in icon font (falls back to the Windows 10 one)
$iconFont = New-Object Windows.Media.FontFamily 'Segoe Fluent Icons, Segoe MDL2 Assets'
$glyphs = @{ CPU = 0xE950; RAM = 0xEEA0; DISK = 0xEC4A; DRIVE = 0xEDA2; CLAUDE = 0xE99A }

function New-Stat([Windows.Controls.Panel]$parent, [string]$label, [string]$icon = $label) {
    $sp = New-Object Windows.Controls.StackPanel -Property @{ Orientation = 'Horizontal'; Margin = '0,0,18,0'; VerticalAlignment = 'Center' }
    if ($glyphs[$icon]) {
        $ic = New-Object Windows.Controls.TextBlock -Property @{ Text = [string][char]$glyphs[$icon]; FontFamily = $iconFont; FontSize = 13; Foreground = $conv.ConvertFrom('#8899AA'); VerticalAlignment = 'Center'; Margin = '0,0,5,0' }
        [void]$sp.Children.Add($ic)
    }
    $l = New-Object Windows.Controls.TextBlock -Property @{ Text = "$label "; Foreground = $conv.ConvertFrom('#8899AA'); FontSize = 11; FontFamily = 'Segoe UI Semibold'; VerticalAlignment = 'Center' }
    $bar = New-Object Windows.Controls.ProgressBar -Property @{ Width = 36; Height = 5; Minimum = 0; Maximum = 100; BorderThickness = 0; Margin = '0,0,5,0'; VerticalAlignment = 'Center'; Background = $conv.ConvertFrom('#33FFFFFF') }
    $v = New-Object Windows.Controls.TextBlock -Property @{ Foreground = $conv.ConvertFrom('#E6EAF0'); FontSize = 11; FontFamily = 'Consolas'; VerticalAlignment = 'Center' }
    [void]$sp.Children.Add($l); [void]$sp.Children.Add($bar); [void]$sp.Children.Add($v)
    [void]$parent.Children.Add($sp)
    @{ Value = $v; Bar = $bar; Panel = $sp; Icon = $ic }
}

function Set-Bar($item, [double]$pct) {
    $item.Bar.Value = $pct
    $c = if ($pct -ge 90) { '#E5534B' } elseif ($pct -ge 70) { '#E0A03A' } else { '#4CB782' }
    $item.Bar.Foreground = $conv.ConvertFrom($c)
}

function Format-Bytes([double]$b) {
    if ($b -ge 1GB) { '{0:N1}G' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N1}M' -f ($b / 1MB) } elseif ($b -ge 1KB) { '{0:N0}K' -f ($b / 1KB) } else { '{0:N0}B' -f $b }
}

$cpuItem  = New-Stat $stats 'CPU'
$memItem  = New-Stat $stats 'RAM'
$diskItem = New-Stat $stats 'DISK'
$driveItems = @{}

# --- Memory breakdown popup (click RAM) ---
$memPopup = New-Object Windows.Controls.Primitives.Popup -Property @{ StaysOpen = $false; Placement = 'Bottom'; AllowsTransparency = $true; PlacementTarget = $memItem.Panel; VerticalOffset = 12 }
$memPopupBody = New-Object Windows.Controls.StackPanel
$memPopup.Child = New-Object Windows.Controls.Border -Property @{ Background = $conv.ConvertFrom('#F51E1F25'); BorderBrush = $conv.ConvertFrom('#33FFFFFF'); BorderThickness = 1; CornerRadius = 8; Padding = '14,10'; Margin = '0,4,0,0'; Child = $memPopupBody }

$script:popupBody = $memPopupBody
function Add-PopupLine([string]$text, [string]$color = '#E6EAF0', [string]$font = 'Consolas', [int]$size = 12) {
    $t = New-Object Windows.Controls.TextBlock -Property @{ Text = $text; Foreground = $conv.ConvertFrom($color); FontFamily = $font; FontSize = $size; Margin = '0,1,0,1' }
    [void]$script:popupBody.Children.Add($t)
}

function Show-MemoryBreakdown {
    $script:popupBody = $memPopupBody
    $memPopupBody.Children.Clear()
    $os = Get-CimInstance Win32_OperatingSystem
    $pm = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $tot = $os.TotalVisibleMemorySize * 1KB
    $avail = [double]$pm.AvailableBytes
    $standby = [double]($pm.StandbyCacheCoreBytes + $pm.StandbyCacheNormalPriorityBytes + $pm.StandbyCacheReserveBytes)
    $commitLimit = [double]$pm.CommitLimit

    Add-PopupLine 'MEMORY OVERVIEW' '#8899AA' 'Segoe UI Semibold' 11
    Add-PopupLine ('In use     {0,8}  of {1}  ({2}%)' -f (Format-Bytes ($tot - $avail)), (Format-Bytes $tot), [math]::Round(($tot - $avail) / $tot * 100))
    Add-PopupLine ('Available  {0,8}  ({1} cached, reusable)' -f (Format-Bytes $avail), (Format-Bytes $standby))
    Add-PopupLine ('Committed  {0,8}  of {1} limit (RAM + pagefile)' -f (Format-Bytes $pm.CommittedBytes), (Format-Bytes $commitLimit))
    Add-PopupLine ('Kernel     {0,8}  (paged {1}, non-paged {2})' -f (Format-Bytes ($pm.PoolPagedBytes + $pm.PoolNonpagedBytes)), (Format-Bytes $pm.PoolPagedBytes), (Format-Bytes $pm.PoolNonpagedBytes))
    Add-PopupLine ' '
    Add-PopupLine ('{0,-30} {1,5} {2,9}' -f 'TOP APPS', 'PROCS', 'RAM') '#8899AA'

    $groups = Get-Process | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Count = $_.Count; Bytes = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum }
    } | Sort-Object Bytes -Descending | Select-Object -First 15
    foreach ($g in $groups) {
        $name = if ($g.Name.Length -gt 30) { $g.Name.Substring(0, 29) + [char]0x2026 } else { $g.Name }
        $c = if ($g.Bytes -ge 2GB) { '#E0A03A' } else { '#E6EAF0' }
        Add-PopupLine ('{0,-30} {1,5} {2,9}' -f $name, $g.Count, (Format-Bytes $g.Bytes)) $c
    }
    Add-PopupLine ' '
    Add-PopupLine 'Shared pages count per process, so totals can exceed RAM.' '#667788' 'Segoe UI' 10
    Add-PopupLine 'Click RAM again or elsewhere to close.' '#667788' 'Segoe UI' 10
    $memPopup.IsOpen = $true
}

$memItem.Panel.Background = [Windows.Media.Brushes]::Transparent   # make the whole item clickable
$memItem.Panel.Cursor = [Windows.Input.Cursors]::Hand
$memItem.Panel.ToolTip = 'Click for memory breakdown'
$memItem.Panel.Add_MouseLeftButtonUp({
    if ($memPopup.IsOpen) { $memPopup.IsOpen = $false } else { try { Show-MemoryBreakdown } catch { Add-PopupLine "Error: $($_.Exception.Message)" '#E5534B'; $memPopup.IsOpen = $true } }
})

# --- Claude Code sessions (reads ~/.claude/sessions/<pid>.json status files; never touches .key files) ---
$aiItem = New-Stat $stats 'CLAUDE'
$aiItem.Bar.Visibility = 'Collapsed'
# CLI status files only carry a folder-derived name; the real title (/rename or auto title) lives in the transcript.
$script:titleCache = @{}
function Get-SessionTitle([string]$profileDir, [string]$sessionId) {
    $c = $script:titleCache[$sessionId]
    $now = Get-Date
    if ($c -and ($now - $c.Checked).TotalSeconds -lt 30) { return $c.Title }
    if (-not $c) { $c = @{ Path = $null; Length = -1; Title = $null } }
    if (-not $c.Path) { $c.Path = (Get-ChildItem (Join-Path $profileDir '.claude\projects') -Recurse -Filter "$sessionId.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
    $c.Checked = $now
    if ($c.Path) {
        $len = (Get-Item $c.Path -ErrorAction SilentlyContinue).Length
        if ($len -ne $c.Length) {
            $c.Length = $len
            $custom = $null; $ai = $null
            foreach ($m in Select-String -Path $c.Path -Pattern '"type":"(custom-title|ai-title)"' -ErrorAction SilentlyContinue) {
                try { $o = $m.Line | ConvertFrom-Json } catch { continue }
                if ($o.type -eq 'custom-title' -and $o.customTitle) { $custom = $o.customTitle }
                elseif ($o.aiTitle) { $ai = $o.aiTitle }
            }
            $c.Title = if ($custom) { $custom } else { $ai }
        }
    }
    $script:titleCache[$sessionId] = $c
    $c.Title
}

function Get-ClaudeSessions {
    # Scan every profile we can read: CLI sessions in an elevated terminal often run as a separate admin account
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Get-ChildItem (Split-Path $env:USERPROFILE) -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $d = Join-Path $_.FullName '.claude\sessions'
        if (Test-Path $d) { Get-ChildItem $d -Filter *.json -ErrorAction SilentlyContinue }
    } | ForEach-Object {
        $user = $_.Directory.Parent.Parent.Name
        try {
            $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $proc = Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue
            if (-not $proc) { return }   # stale file from a session that has exited
            $since = if ($j.statusUpdatedAt) { $j.statusUpdatedAt } else { $j.updatedAt }
            [pscustomobject]@{
                Name    = $(
                    $t = if ($j.nameSource -ne 'user') { Get-SessionTitle $_.Directory.Parent.Parent.FullName $j.sessionId }
                    if ($t) { $t } elseif ($j.name) { $j.name } else { Split-Path $j.cwd -Leaf })
                Status  = if ($j.status) { [string]$j.status } else { 'unknown' }
                ForSec  = [math]::Max(0, ($now - [double]$since) / 1000)
                Started = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$j.startedAt).LocalDateTime
                Folder  = Split-Path $j.cwd -Leaf
                Entry   = if ($j.entrypoint -eq 'claude-desktop') { 'app' } elseif ($j.entrypoint) { $j.entrypoint } else { 'cli' }
                User    = $user
                Pid     = [int]$j.pid
                RAM     = $proc.WorkingSet64
            }
        } catch {}
    } | Sort-Object @{ e = { $_.Status -ne 'busy' } }, ForSec
}

function Format-Age([double]$s) {
    if ($s -lt 60) { '{0:N0}s' -f $s } elseif ($s -lt 3600) { '{0:N0}m' -f [math]::Floor($s / 60) } else { '{0}h{1:00}m' -f [math]::Floor($s / 3600), [math]::Floor(($s % 3600) / 60) }
}
function Get-StatusColor([string]$s) { switch ($s) { 'busy' { '#4CB782' } 'idle' { '#8899AA' } default { '#E0A03A' } } }

# --- Toast shown under the bar when a session goes busy -> idle ---
$script:notifyOn = $true
$script:prevStatus = @{}
$toastWin = $null; $toastBody = $null; $toastTimer = $null

function Show-Toast([string]$title, [string]$text) {
    if (-not $script:toastWin) {
        $script:toastWin = New-Object Windows.Window -Property @{ WindowStyle = 'None'; AllowsTransparency = $true; Background = [Windows.Media.Brushes]::Transparent; Topmost = $true; ShowInTaskbar = $false; ShowActivated = $false; SizeToContent = 'WidthAndHeight'; ResizeMode = 'NoResize' }
        $script:toastBody = New-Object Windows.Controls.StackPanel
        $script:toastWin.Content = New-Object Windows.Controls.Border -Property @{ Background = $conv.ConvertFrom('#F51E1F25'); BorderBrush = $conv.ConvertFrom('#4CB782'); BorderThickness = 1; CornerRadius = 8; Padding = '14,10'; MinWidth = 300; MaxWidth = 420; Child = $script:toastBody }
        $script:toastWin.Add_MouseLeftButtonUp({ $script:toastWin.Hide(); $script:toastBody.Children.Clear() })
        $script:toastTimer = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromSeconds(8) }
        $script:toastTimer.Add_Tick({ $script:toastTimer.Stop(); $script:toastWin.Hide(); $script:toastBody.Children.Clear() })
    }
    if (-not $script:toastBody.Children.Count) {
        [void]$script:toastBody.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = 'CLAUDE - READY FOR YOU'; Foreground = $conv.ConvertFrom('#4CB782'); FontFamily = 'Segoe UI Semibold'; FontSize = 11; Margin = '0,0,0,4' }))
    }
    [void]$script:toastBody.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $title; Foreground = $conv.ConvertFrom('#E6EAF0'); FontFamily = 'Segoe UI Semibold'; FontSize = 13; TextTrimming = 'CharacterEllipsis' }))
    [void]$script:toastBody.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $text; Foreground = $conv.ConvertFrom('#8899AA'); FontFamily = 'Segoe UI'; FontSize = 11; Margin = '0,0,0,4' }))
    $script:toastWin.Show()
    $script:toastWin.UpdateLayout()
    $script:toastWin.Left = $win.Left + $win.ActualWidth - $script:toastWin.ActualWidth - 12
    $script:toastWin.Top  = $win.Top + $win.ActualHeight + 12
    $script:toastTimer.Stop(); $script:toastTimer.Start()
    try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
}

function Update-ClaudeItem {
    $s = @(Get-ClaudeSessions)
    foreach ($x in $s) {
        if ($script:notifyOn -and $script:prevStatus[$x.Pid] -eq 'busy' -and $x.Status -ne 'busy') {
            Show-Toast $x.Name ("{0}  -  {1} ({2}, {3})" -f $x.Status, (Get-Date -Format 'HH:mm'), $x.Entry, $x.User)
        }
        $script:prevStatus[$x.Pid] = $x.Status
    }
    $busy = @($s | Where-Object Status -eq 'busy').Count
    $idle = @($s | Where-Object Status -eq 'idle').Count
    $other = $s.Count - $busy - $idle
    $txt = '{0} sess  {1} busy  {2} idle' -f $s.Count, $busy, $idle
    if ($other) { $txt += "  $other other" }
    $aiItem.Value.Text = $txt
    $aiItem.Value.Foreground = $conv.ConvertFrom($(if ($other) { '#E0A03A' } elseif ($busy) { '#4CB782' } else { '#E6EAF0' }))
    $aiItem.Icon.Foreground  = $conv.ConvertFrom($(if ($other) { '#E0A03A' } elseif ($busy) { '#4CB782' } else { '#8899AA' }))
    $s
}

function Stop-ClaudeSession($x) {
    $aiPopup.IsOpen = $false
    $warn = if ($x.Entry -eq 'app') { "`n`nThis is a desktop-app session: the app will show it as stopped/errored." } else { '' }
    if ($x.Status -eq 'busy') { $warn += "`n`nIt is BUSY right now - work in progress will be interrupted." }
    $ok = [Windows.MessageBox]::Show("End Claude session '$($x.Name)'?`n`nPID $($x.Pid), user $($x.User), $($x.Entry).$warn", 'SysBar - end session', 'YesNo', 'Warning')
    if ($ok -ne 'Yes') { return }
    # /T also ends the session's child processes (shells, tools)
    $out = & taskkill.exe /PID $x.Pid /T /F 2>&1
    if ($LASTEXITCODE -ne 0 -and (Get-Process -Id $x.Pid -ErrorAction SilentlyContinue)) {
        # Usually access denied: session belongs to another (admin) account. Retry elevated via UAC.
        $again = [Windows.MessageBox]::Show("Could not end it as $env:USERNAME:`n$out`n`nRetry as administrator (UAC prompt)?", 'SysBar - end session', 'YesNo', 'Question')
        if ($again -eq 'Yes') {
            try { Start-Process taskkill.exe -ArgumentList "/PID $($x.Pid) /T /F" -Verb RunAs -WindowStyle Hidden -Wait } catch { return }
        }
    }
    Start-Sleep -Milliseconds 500
    [void](Update-ClaudeItem)
    Show-ClaudeSessions
}

$aiPopup = New-Object Windows.Controls.Primitives.Popup -Property @{ StaysOpen = $false; Placement = 'Bottom'; AllowsTransparency = $true; PlacementTarget = $aiItem.Panel; VerticalOffset = 12 }
$aiPopupBody = New-Object Windows.Controls.StackPanel
$aiPopup.Child = New-Object Windows.Controls.Border -Property @{ Background = $conv.ConvertFrom('#F51E1F25'); BorderBrush = $conv.ConvertFrom('#33FFFFFF'); BorderThickness = 1; CornerRadius = 8; Padding = '14,10'; Child = $aiPopupBody }

function Show-ClaudeSessions {
    $script:popupBody = $aiPopupBody
    $aiPopupBody.Children.Clear()
    $s = @(Update-ClaudeItem)
    Add-PopupLine 'CLAUDE CODE SESSIONS' '#8899AA' 'Segoe UI Semibold' 11
    if (-not $s.Count) { Add-PopupLine 'No running sessions.' '#8899AA' }
    else {
        $fmt = '{0,-40} {1,-6} {2,7} {3,8} {4,7}  {5,-4} {6}'
        Add-PopupLine ($fmt -f 'SESSION', 'STATE', 'FOR', 'RAM', 'STARTED', 'VIA', 'USER') '#8899AA'
        foreach ($x in $s) {
            $n = if ($x.Name.Length -gt 40) { $x.Name.Substring(0, 39) + [char]0x2026 } else { $x.Name }
            Add-PopupLine ($fmt -f $n, $x.Status, (Format-Age $x.ForSec), (Format-Bytes $x.RAM), $x.Started.ToString($(if ($x.Started.Date -eq (Get-Date).Date) { 'HH:mm' } else { 'dd/MM' })), $x.Entry, $x.User) (Get-StatusColor $x.Status)
            # Append a kill button to the line just added
            $line = $aiPopupBody.Children[$aiPopupBody.Children.Count - 1]
            $aiPopupBody.Children.Remove($line)
            $row = New-Object Windows.Controls.DockPanel
            $kill = New-Object Windows.Controls.TextBlock -Property @{ Text = [string][char]0x2715; Foreground = $conv.ConvertFrom('#E5534B'); FontSize = 12; Margin = '12,1,0,1'; Cursor = [Windows.Input.Cursors]::Hand; ToolTip = "End this session (PID $($x.Pid))"; Tag = $x }
            $kill.Add_MouseLeftButtonUp({ param($sender) Stop-ClaudeSession $sender.Tag })
            [Windows.Controls.DockPanel]::SetDock($kill, 'Right')
            [void]$row.Children.Add($kill); [void]$row.Children.Add($line)
            [void]$aiPopupBody.Children.Add($row)
        }
    }
    Add-PopupLine ' '
    Add-PopupLine 'busy = working   idle = waiting for you   other states shown in amber' '#667788' 'Segoe UI' 10
    Add-PopupLine 'RAM is the session process only (not the shared desktop app).' '#667788' 'Segoe UI' 10
    $aiPopup.IsOpen = $true
}

$aiItem.Panel.Background = [Windows.Media.Brushes]::Transparent
$aiItem.Panel.Cursor = [Windows.Input.Cursors]::Hand
$aiItem.Panel.ToolTip = 'Click for Claude session details'
$aiItem.Panel.Add_MouseLeftButtonUp({
    if ($aiPopup.IsOpen) { $aiPopup.IsOpen = $false } else { try { Show-ClaudeSessions } catch { $script:popupBody = $aiPopupBody; Add-PopupLine "Error: $($_.Exception.Message)" '#E5534B'; $aiPopup.IsOpen = $true } }
})

function Update-Stats {
    try {
        $clock.Text = ''   # centre slot is only used for error messages (Windows already shows the time)

        $cpu = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
        Set-Bar $cpuItem $cpu
        $cpuItem.Value.Text = '{0,3}%' -f $cpu

        $os = Get-CimInstance Win32_OperatingSystem
        $tot = $os.TotalVisibleMemorySize * 1KB; $used = $tot - $os.FreePhysicalMemory * 1KB
        $mp = [math]::Round($used / $tot * 100)
        Set-Bar $memItem $mp
        $memItem.Value.Text = '{0,3}% {1}/{2}' -f $mp, (Format-Bytes $used), (Format-Bytes $tot)

        $io = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
        $act = [math]::Min(100, [math]::Round(100 - $io.PercentIdleTime))
        Set-Bar $diskItem $act
        $diskItem.Value.Text = '{0,3}% R {1}/s W {2}/s' -f $act, (Format-Bytes $io.DiskReadBytesPersec), (Format-Bytes $io.DiskWriteBytesPersec)

        foreach ($d in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
            if (-not $driveItems[$d.Name]) { $driveItems[$d.Name] = New-Stat $drives $d.Name.TrimEnd('\') 'DRIVE' }
            $r = $driveItems[$d.Name]
            $p = [math]::Round(($d.TotalSize - $d.AvailableFreeSpace) / $d.TotalSize * 100)
            Set-Bar $r $p
            $r.Value.Text = '{0} free' -f (Format-Bytes $d.AvailableFreeSpace)
        }
    } catch { $clock.Text = "Error: $($_.Exception.Message)" }
}

Update-Stats
if ($SelfTest) {
    "CPU $($cpuItem.Value.Text) | RAM $($memItem.Value.Text) | DISK $($diskItem.Value.Text)"
    $driveItems.Keys | ForEach-Object { "$_ $($driveItems[$_].Value.Text)" }
    if ($env:SYSBAR_PREVIEW) {   # render the bar to a PNG for a visual check
        $win.Width = 1600; $win.Show(); $win.UpdateLayout()
        $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap 1600, ([int]$win.ActualHeight), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($win.Content); $win.Hide()
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $fs = [IO.File]::Create($env:SYSBAR_PREVIEW); $enc.Save($fs); $fs.Close()
    }
    Show-ClaudeSessions; $aiPopup.IsOpen = $false
    if ($env:SYSBAR_POPUPS) {    # render both popups to PNGs (session names replaced by demo titles)
        $demo = 'Refactor billing API', 'Fix flaky login test', 'Write release notes', 'Investigate slow query', 'Update dependencies'
        $i = 0
        foreach ($row in $aiPopupBody.Children) {
            if ($row -is [Windows.Controls.DockPanel]) { $t = $row.Children[1]; $t.Text = ('{0,-40}' -f $demo[$i % $demo.Count]) + $t.Text.Substring(40) -replace '(ADMIN)?JRAU', 'me'; $i++ }
        }
        Show-MemoryBreakdown; $memPopup.IsOpen = $false
        foreach ($p in @(@{ n = 'popup-memory'; c = $memPopup.Child }, @{ n = 'popup-claude'; c = $aiPopup.Child })) {
            $p.c.Margin = '0'; $p.c.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity)); $p.c.Arrange([Windows.Rect]::new($p.c.DesiredSize))
            $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$p.c.ActualWidth * 2), ([int]$p.c.ActualHeight * 2), 192, 192, ([Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($p.c)
            $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $fs = [IO.File]::Create((Join-Path $env:SYSBAR_POPUPS "$($p.n).png")); $enc.Save($fs); $fs.Close()
        }
    }
    "BAR: CLAUDE $($aiItem.Value.Text)"
    $aiPopupBody.Children | ForEach-Object { if ($_ -is [Windows.Controls.DockPanel]) { $_.Children[1].Text + '  [x]' } else { $_.Text } }
    [System.Windows.Forms.Screen]::AllScreens | ForEach-Object { "Screen: $($_.DeviceName) $($_.Bounds) primary=$($_.Primary)" }
    return
}

# Pick the target screen: primary first, then the others in Windows' order
$script:hwnd = [IntPtr]::Zero
$script:dockedFor = ''

function Get-TargetScreen {
    $screens = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { -not $_.Primary })
    $screens[[math]::Min($Monitor, $screens.Count - 1)]
}

function Dock-Bar([bool]$isNew) {
    $screen = Get-TargetScreen
    $scale = [Windows.Media.VisualTreeHelper]::GetDpi($win).DpiScaleY
    $b = $screen.Bounds
    [AppBar]::Dock($script:hwnd, $b.Left, $b.Top, $b.Right, [int][math]::Ceiling($HeightDip * $scale), $isNew)
    $script:dockedFor = "$($b)|$scale"
}

# Re-dock when monitors, resolution or scaling change (docking/undocking the laptop, etc.)
function Test-Dock {
    if ($script:hwnd -eq [IntPtr]::Zero) { return }
    $scale = [Windows.Media.VisualTreeHelper]::GetDpi($win).DpiScaleY
    $b = (Get-TargetScreen).Bounds
    $widthOff = [math]::Abs($win.ActualWidth * $scale - $b.Width) -gt 2
    if ($widthOff -or "$($b)|$scale" -ne $script:dockedFor) { Dock-Bar $false }
}
$win.Add_DpiChanged({ $win.Dispatcher.BeginInvoke([action]{ Dock-Bar $false }) })

$win.Add_SourceInitialized({
    $script:hwnd = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
    Dock-Bar $true
    # Re-dock when the shell asks (taskbar moved, display settings changed, etc.)
    $src = [Windows.Interop.HwndSource]::FromHwnd($script:hwnd)
    $src.AddHook({
        param($h, $msg, $wParam, $lParam, [ref]$handled)
        if ($msg -eq [AppBar]::CallbackMsg -and $wParam.ToInt32() -eq 1) { Dock-Bar $false }  # ABN_POSCHANGED
        [IntPtr]::Zero
    })
})
$win.Add_Closed({ if ($script:hwnd -ne [IntPtr]::Zero) { [AppBar]::Remove($script:hwnd) } })

$menu = New-Object Windows.Controls.ContextMenu
$mi = New-Object Windows.Controls.MenuItem -Property @{ Header = 'Close SysBar' }
$mi.Add_Click({ $win.Close() })
$miNotify = New-Object Windows.Controls.MenuItem -Property @{ Header = 'Notify when Claude goes idle'; IsCheckable = $true; IsChecked = $true }
$miNotify.Add_Click({ $script:notifyOn = $miNotify.IsChecked })
$miTest = New-Object Windows.Controls.MenuItem -Property @{ Header = 'Test notification' }
$miTest.Add_Click({ Show-Toast 'Test session' ('idle  -  {0} (test)' -f (Get-Date -Format 'HH:mm')) })
[void]$menu.Items.Add($miNotify); [void]$menu.Items.Add($miTest); [void]$menu.Items.Add((New-Object Windows.Controls.Separator)); [void]$menu.Items.Add($mi)
$win.ContextMenu = $menu

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds($IntervalMs)
$timer.Add_Tick({ Update-Stats; try { Test-Dock } catch {}; try { [void](Update-ClaudeItem) } catch {} })
$timer.Start()
[void]$win.ShowDialog()


