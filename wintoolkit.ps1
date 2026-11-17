& {
$Url = 'https://github.com/lenhei/wintoolkit/raw/main/wintoolkit.ps1'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $cmd = if ($PSCommandPath) { "& '$($PSCommandPath -replace "'", "''")'" }
           else { "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; irm '$Url' | iex" }
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    try { Start-Process -FilePath "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -EncodedCommand $enc" }
    catch { Write-Host 'Administrator rights are required.' -ForegroundColor Red }
    return
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$dir = Join-Path $env:windir 'Logs\WinHealth'
New-Item -ItemType Directory -Path $dir -Force | Out-Null

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinHealth - System Check &amp; Repair" Width="960" Height="600" MinWidth="720" MinHeight="420"
        WindowStartupLocation="CenterScreen" Background="#1E1E1E" Foreground="#DDDDDD" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#DDDDDD"/><Setter Property="Margin" Value="0,5"/></Style>
    <Style TargetType="Button">
      <Setter Property="Margin" Value="0,8,0,0"/><Setter Property="Padding" Value="8,7"/>
      <Setter Property="Background" Value="#2D2D30"/><Setter Property="Foreground" Value="#DDDDDD"/><Setter Property="BorderBrush" Value="#3F3F46"/>
    </Style>
  </Window.Resources>
  <DockPanel Margin="14">
    <StatusBar DockPanel.Dock="Bottom" Background="Transparent" Foreground="#AAAAAA" Margin="0,8,0,0">
      <StatusBarItem><ProgressBar x:Name="Bar" Width="180" Height="12"/></StatusBarItem>
      <StatusBarItem><TextBlock x:Name="Status" Text="Ready"/></StatusBarItem>
    </StatusBar>
    <StackPanel DockPanel.Dock="Left" Width="230" Margin="0,0,14,0">
      <TextBlock Text="Checks" FontWeight="Bold" FontSize="16" Margin="0,0,0,6"/>
      <CheckBox x:Name="cDism" Content="DISM component store" IsChecked="True"/>
      <CheckBox x:Name="cSfc"  Content="SFC system files" IsChecked="True"/>
      <CheckBox x:Name="cChk"  Content="CHKDSK file system" IsChecked="True"/>
      <CheckBox x:Name="cDisk" Content="Disk health (SMART)" IsChecked="True"/>
      <CheckBox x:Name="cSvc"  Content="Failed services" IsChecked="True"/>
      <CheckBox x:Name="cVss"  Content="VSS writers and errors" IsChecked="True"/>
      <Separator Margin="0,10" Background="#3F3F46"/>
      <CheckBox x:Name="cRepair" Content="Repair problems found" IsChecked="True"/>
      <Button x:Name="bRun" Content="Run checks" FontWeight="Bold"/>
      <Button x:Name="bLog" Content="Open log folder"/>
      <TextBlock Text="DISM and SFC can take 10-30 minutes." TextWrapping="Wrap" Foreground="#888888" Margin="0,12,0,0"/>
    </StackPanel>
    <ListBox x:Name="List" Background="#252526" BorderBrush="#3F3F46" FontFamily="Consolas" FontSize="12"
             ScrollViewer.HorizontalScrollBarVisibility="Disabled">
      <ListBox.ItemTemplate>
        <DataTemplate><TextBlock Text="{Binding Text}" Foreground="{Binding Color}" TextWrapping="Wrap"/></DataTemplate>
      </ListBox.ItemTemplate>
    </ListBox>
  </DockPanel>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
'Bar', 'Status', 'cDism', 'cSfc', 'cChk', 'cDisk', 'cSvc', 'cVss', 'cRepair', 'bRun', 'bLog', 'List' | ForEach-Object { $ui[$_] = $win.FindName($_) }
$items = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.List.ItemsSource = $items
$q  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$st = @{ Busy = $false; PS = $null; Job = $null; Last = '' }

$work = {
    param($Sel, $Repair, $Q, $LogPath)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $sys = Join-Path $env:windir 'System32'
    $n = @{ Fail = 0; Fixed = 0 }
    $col = @{ INFO = '#BBBBBB'; STEP = '#4FC3F7'; OK = '#6CCB5F'; WARN = '#E5C07B'; FIXED = '#56B6C2'; FAIL = '#FF6B6B' }

    function Log([string]$Msg, [ValidateSet('INFO','STEP','OK','WARN','FIXED','FAIL')][string]$Lvl = 'INFO') {
        $line = '{0:HH:mm:ss} [{1,-5}] {2}' -f (Get-Date), $Lvl, $Msg
        Add-Content -LiteralPath $LogPath -Value ('{0:yyyy-MM-dd} {1}' -f (Get-Date), $line) -Encoding UTF8
        $Q.Enqueue([pscustomobject]@{ Text = $line; Color = $col[$Lvl]; Lvl = $Lvl; Msg = $Msg })
        if ($Lvl -eq 'FAIL') { $n.Fail++ } elseif ($Lvl -eq 'FIXED') { $n.Fixed++ }
    }
    function Run([string]$Exe, [string[]]$Arg) {
        (Start-Process -FilePath (Join-Path $sys $Exe) -ArgumentList $Arg -Wait -PassThru -WindowStyle Hidden).ExitCode
    }
    function Read-Shared([string]$Path) {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { (New-Object IO.StreamReader($fs)).ReadToEnd() -split "`r?`n" } finally { $fs.Dispose() }
    }
    function Get-VssWriters {
        $out = (& (Join-Path $sys 'vssadmin.exe') list writers 2>&1) -join "`n"
        foreach ($b in ($out -split "`n\s*`n")) {
            if ($b -match '\[(\d+)\]') {
                $state = [int]$Matches[1]
                $name  = if ($b -match "['""](.+?)['""]") { $Matches[1] } else { 'unknown' }
                [pscustomobject]@{ Name = $name; State = $state }
            }
        }
    }

    Log "Start on $env:COMPUTERNAME, repair: $Repair, log: $LogPath"

    if ($Sel.Dism) {
        Log 'DISM component store' STEP
        try {
            Log "DISM CheckHealth: $((Repair-WindowsImage -Online -CheckHealth).ImageHealthState)"
            $s = (Repair-WindowsImage -Online -ScanHealth).ImageHealthState
            if ($s -eq 'Healthy') { Log 'DISM: component store healthy' OK }
            elseif (-not $Repair) { Log "DISM: component store $s (repair disabled)" FAIL }
            else {
                Log "DISM: component store $s, running RestoreHealth" WARN
                $s = (Repair-WindowsImage -Online -RestoreHealth).ImageHealthState
                if ($s -eq 'Healthy') { Log 'DISM RestoreHealth: repaired' FIXED } else { Log "DISM RestoreHealth: not repaired ($s)" FAIL }
            }
        } catch { Log "DISM error: $($_.Exception.Message)" FAIL }
    }

    if ($Sel.Sfc) {
        Log 'SFC system files' STEP
        try {
            $t0 = (Get-Date).AddSeconds(-2)
            $rc = Run 'sfc.exe' $(if ($Repair) { '/scannow' } else { '/verifyonly' })
            $all = @(Read-Shared (Join-Path $env:windir 'Logs\CBS\CBS.log') | Where-Object {
                $_ -match '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d),' -and [datetime]$Matches[1] -ge $t0
            })
            $sr  = @($all | Where-Object { $_ -match '\[SR\]' })
            $bad = @($sr | Where-Object { $_ -match 'Cannot repair' })
            $fix = @($sr | Where-Object { $_ -match 'Repairing corrupted file|Repaired file' })
            $cor = @($all | Where-Object { $_ -match 'corrupt|Hashes for file member .* do not match' })
            if ($bad.Count) { $bad | Select-Object -First 20 | ForEach-Object { Log "SFC: $($_ -replace '^.*\[SR\]\s*')" FAIL } }
            elseif ($fix.Count) { Log "SFC: $($fix.Count) corrupt file(s) repaired" FIXED }
            elseif (-not $Repair -and $cor.Count) { Log "SFC: corrupt files found (repair disabled)" FAIL }
            elseif ($sr) { Log 'SFC: no integrity violations' OK }
            else { Log "SFC: could not verify result (exit $rc)" FAIL }
        } catch { Log "SFC error: $($_.Exception.Message)" FAIL }
    }

    if ($Sel.Chk) {
        Log 'CHKDSK file system' STEP
        foreach ($d in @(Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.FileSystem -eq 'NTFS' } | ForEach-Object DriveLetter)) {
            try {
                switch (Run 'chkdsk.exe' @("$($d):", '/scan')) {
                    0 { Log "CHKDSK $($d): no errors" OK }
                    1 { Log "CHKDSK $($d): errors found and fixed" FIXED }
                    2 { Log "CHKDSK $($d): cleanup performed, no errors" OK }
                    3 { Log "CHKDSK $($d): errors not fixed, run 'chkdsk $($d): /spotfix' and reboot" FAIL }
                    default { Log "CHKDSK $($d): unexpected exit code $_" FAIL }
                }
            } catch { Log "CHKDSK $($d) error: $($_.Exception.Message)" FAIL }
        }
    }

    if ($Sel.Disk) {
        Log 'Disk health' STEP
        try {
            foreach ($p in @(Get-PhysicalDisk)) {
                if ("$($p.HealthStatus)" -eq 'Healthy') { Log "Disk '$($p.FriendlyName)': Healthy" OK }
                else { Log "Disk '$($p.FriendlyName)': $($p.HealthStatus) / $($p.OperationalStatus), back up your data" FAIL }
            }
        } catch { Log "Disk health error: $($_.Exception.Message)" FAIL }
    }

    if ($Sel.Svc) {
        Log 'Failed services' STEP
        try {
            $svc = @(Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running' AND ExitCode<>0")
            if (-not $svc.Count) { Log 'Services: no failed auto-start services' OK }
            foreach ($s in $svc) {
                if (-not $Repair) { Log "Service $($s.Name) ($($s.DisplayName)) stopped, exit $($s.ExitCode) (repair disabled)" FAIL; continue }
                Log "Service $($s.Name) ($($s.DisplayName)) stopped, exit $($s.ExitCode)" WARN
                try {
                    Start-Service -Name $s.Name
                    (Get-Service -Name $s.Name).WaitForStatus('Running', '00:00:30')
                    Log "Service $($s.Name) started" FIXED
                } catch { Log "Service $($s.Name) could not start: $($_.Exception.Message)" FAIL }
            }
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7000, 7001, 7023, 7024, 7031, 7034; StartTime = (Get-Date).AddDays(-1) } -ErrorAction SilentlyContinue |
                Group-Object Message | ForEach-Object { Log "SCM event (24h, x$($_.Count)): $(($_.Name -split "`r?`n")[0])" WARN }
        } catch { Log "Services error: $($_.Exception.Message)" FAIL }
    }

    if ($Sel.Vss) {
        Log 'VSS writers and errors' STEP
        try {
            if ((Get-Service VSS).StartType -eq 'Disabled') { Log 'VSS service is disabled' FAIL }
            else {
                $bad = @(Get-VssWriters | Where-Object State -ne 1)
                if (-not $bad.Count) { Log 'VSS: all writers stable' OK }
                elseif (-not $Repair) { $bad | ForEach-Object { Log "VSS writer '$($_.Name)' state $($_.State) (repair disabled)" FAIL } }
                else {
                    $bad | ForEach-Object { Log "VSS writer '$($_.Name)' state $($_.State)" WARN }
                    Restart-Service -Name VSS -Force
                    Start-Sleep -Seconds 5
                    $still = @(Get-VssWriters | Where-Object State -ne 1)
                    if (-not $still.Count) { Log 'VSS: writers stable after VSS restart' FIXED }
                    else { $still | ForEach-Object { Log "VSS writer '$($_.Name)' still state $($_.State), restart its service or reboot" FAIL } }
                }
            }
            Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'VSS'; Level = 2; StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue |
                Group-Object Id | ForEach-Object { Log "VSS event $($_.Name) (7d, x$($_.Count)): $((($_.Group[0].Message) -split "`r?`n")[0])" WARN }
        } catch { Log "VSS error: $($_.Exception.Message)" FAIL }
    }

    if ($n.Fail) { Log "Done: $($n.Fixed) fixed, $($n.Fail) unresolved problem(s)" FAIL }
    else { Log "Done: $($n.Fixed) fixed, no unresolved problems" OK }
}

function Set-Busy([bool]$b) {
    $st.Busy = $b
    'cDism', 'cSfc', 'cChk', 'cDisk', 'cSvc', 'cVss', 'cRepair', 'bRun' | ForEach-Object { $ui[$_].IsEnabled = -not $b }
    $ui.Bar.IsIndeterminate = $b
    if (-not $b) { $ui.Status.Text = $st.Last }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$timer.Add_Tick({
    $o = $null
    while ($q.TryDequeue([ref]$o)) {
        $items.Add($o); $ui.List.ScrollIntoView($o); $st.Last = $o.Msg
        if ($o.Lvl -eq 'STEP') { $ui.Status.Text = "Running: $($o.Msg)" }
    }
    if ($st.Job -and $st.Job.IsCompleted) {
        try { $null = $st.PS.EndInvoke($st.Job) } catch { $items.Add([pscustomobject]@{ Text = "Error: $($_.Exception.Message)"; Color = '#FF6B6B' }) }
        $st.PS.Runspace.Dispose(); $st.PS.Dispose(); $st.Job = $null
        $timer.Stop(); Set-Busy $false
    }
})

$ui.bRun.Add_Click({
    $sel = @{}
    'Dism', 'Sfc', 'Chk', 'Disk', 'Svc', 'Vss' | ForEach-Object { $sel[$_] = [bool]$ui["c$_"].IsChecked }
    if (-not ($sel.Values -contains $true)) { $ui.Status.Text = 'Select at least one check.'; return }
    $items.Clear()
    $logPath = Join-Path $dir ('WinHealth_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ExecutionPolicy = 'Bypass'
    $rs = [runspacefactory]::CreateRunspace($iss); $rs.Open()
    $st.PS = [powershell]::Create()
    $st.PS.Runspace = $rs
    $null = $st.PS.AddScript($work).AddArgument($sel).AddArgument([bool]$ui.cRepair.IsChecked).AddArgument($q).AddArgument($logPath)
    $st.Job = $st.PS.BeginInvoke()
    Set-Busy $true
    $ui.Status.Text = 'Starting...'
    $timer.Start()
})

$ui.bLog.Add_Click({ Start-Process -FilePath (Join-Path $env:windir 'explorer.exe') -ArgumentList "`"$dir`"" })

$win.Add_Closing({
    param($s, $e)
    if ($st.Busy) {
        $e.Cancel = $true
        [Windows.MessageBox]::Show('Checks are still running. Please wait until they finish.', 'WinHealth') | Out-Null
    }
})

$null = $win.ShowDialog()
}
