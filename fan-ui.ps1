#Requires -Version 5.1
<#
Fan Butler GUI v3 — 超微主板风扇管家 (WPF 浅色版, 对标 FanControl 设计语言)
=============================================================================
双击桌面"风扇管家"快捷方式启动 (自动请求管理员权限)。

v3 设计 (研究 GitHub 20.5k★ FanControl 等项目后的结论):
  浅色主题 — 浅灰底 #F5F6F8 / 纯白卡片 / 1px 细边框 / 柔和投影 / 8px 圆角;
  颜色克制 — 语义色只出现在数值与细条上; 全局雅黑, 数值大号半粗。
技术: PowerShell 5.1 + WPF/XAML (系统自带, 零依赖), IPMI 走 Windows 自带驱动。
底层命令实测校准 (X12DAi-N6 / BMC 1.3):
  查询模式: raw 0x30 0x45 0x00 | 设置模式: raw 0x30 0x45 0x01 <模式>
  读占空比: raw 0x30 0x70 0x66 0x00 <区> | RPM = 原始读数 x 140
#>

# ---------- 自动提权 ----------
$ident = [Security.Principal.WindowsIdentity]::GetCurrent()
$princ = New-Object Security.Principal.WindowsPrincipal($ident)
if (-not $princ.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', $PSCommandPath)
    exit
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
$ErrorActionPreference = 'Stop'

# ============================================================
# IPMI 层 (与命令行版一致, 实测校准)
# ============================================================
$script:Device = $null
function Get-IpmiDevice {
    if ($script:Device) { return $script:Device }
    $d = Get-CimInstance -Namespace root\WMI -ClassName Microsoft_IPMI -ErrorAction Stop | Select-Object -First 1
    if (-not $d) { throw '找不到 IPMI 设备 (需要管理员权限)' }
    $script:Device = $d; return $d
}
function Invoke-IpmiRaw {
    param([byte]$NetFn, [byte]$Cmd, [byte[]]$Data = @())
    $a = @{ NetworkFunction=$NetFn; Command=$Cmd; Lun=[byte]0; ResponderAddress=[byte]0x20
            RequestData=[byte[]]$Data; RequestDataSize=[uint32]$Data.Length }
    $r = Invoke-CimMethod -InputObject (Get-IpmiDevice) -MethodName RequestResponse -Arguments $a
    $rd = [byte[]]$r.ResponseData
    if (-not $rd) { $rd = [byte[]]@() }
    if ($rd.Count -ge 2) { $rd = [byte[]]($rd[1..($rd.Count-1)]) } elseif ($rd.Count -eq 1) { $rd = [byte[]]@() }
    return [pscustomobject]@{ CompletionCode=[int]$r.CompletionCode; Data=$rd }
}
function Get-FanModeCode { $m = Invoke-IpmiRaw 0x30 0x45 @([byte]0x00); if ($m.CompletionCode -eq 0 -and $m.Data.Count -ge 1) { return [int]$m.Data[0] }; return -1 }
function Get-Duty { param([byte]$z) $g = Invoke-IpmiRaw 0x30 0x70 0x66 0x00 @($z); if ($g.CompletionCode -eq 0 -and $g.Data.Count -ge 1) { return [int]$g.Data[0] }; return -1 }
function Set-FanModeCode { param([int]$c) [void](Invoke-IpmiRaw 0x30 0x45 @([byte]0x01,[byte]$c)); Start-Sleep -Milliseconds 2500; return (Get-FanModeCode) }
function Read-SensorRaw { param([byte]$n) $r = Invoke-IpmiRaw 0x04 0x2D @($n); if ($r.CompletionCode -ne 0 -or $r.Data.Count -lt 1) { return $null }; return [int]$r.Data[0] }

$FanDefs = @(
    @{ Name='FAN1'; Num=0x41 }, @{ Name='FAN2'; Num=0x42 }, @{ Name='FAN3'; Num=0x43 }, @{ Name='FAN4'; Num=0x44 },
    @{ Name='FAN5'; Num=0x45 }, @{ Name='FAN6'; Num=0x46 }, @{ Name='FAN7'; Num=0x47 }, @{ Name='FANA'; Num=0x48 }
)
$TempDefs = @(
    @{ Name='CPU1'; Num=0x01 }, @{ Name='CPU2'; Num=0x02 }, @{ Name='PCH'; Num=0x0A },
    @{ Name='系统'; Num=0x0B }, @{ Name='外设'; Num=0x0C }, @{ Name='VRM 供电'; Num=0x10 }
)
$ModeNames = @{ 0='Standard 标准'; 1='Full 全速'; 2='Optimal 最优'; 3='Heavy IO' }

# ============================================================
# 界面 (XAML, WPF 浅色主题)
# ============================================================
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="风扇管家 · X12DAi-N6" Width="480" Height="742"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#F5F6F8" FontFamily="Microsoft YaHei UI" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="BorderBrush" Value="#E4E7EC"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,12,16,14"/>
      <Setter Property="Effect">
        <Setter.Value>
          <DropShadowEffect BlurRadius="14" ShadowDepth="2" Direction="270" Opacity="0.10" Color="#1F2937"/>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="#9CA3AF"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
    </Style>
    <Style x:Key="SubT" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="#9CA3AF"/>
    </Style>
    <Style x:Key="FlatBar" TargetType="ProgressBar">
      <Setter Property="Height" Value="5"/>
      <Setter Property="Foreground" Value="#10B981"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid ClipToBounds="True">
              <Border Background="#EEF0F3" CornerRadius="2.5"/>
              <Border x:Name="PART_Indicator" HorizontalAlignment="Left"
                      Background="{TemplateBinding Foreground}" CornerRadius="2.5"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ModeBtn" TargetType="Button">
      <Setter Property="Height" Value="44"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="7" Background="#FFFFFF" BorderBrush="#D8DCE2" BorderThickness="1">
              <TextBlock x:Name="tx" Text="{TemplateBinding Content}" HorizontalAlignment="Center" VerticalAlignment="Center"
                         Foreground="#374151" FontSize="{TemplateBinding FontSize}" FontWeight="SemiBold"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#F3F4F6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <StackPanel Margin="18,14,18,12">
    <!-- 头部 -->
    <Grid Margin="2,0,2,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock Text="风扇管家" FontSize="19" FontWeight="Bold" Foreground="#111827"/>
        <TextBlock Text="X12DAi-N6 · BMC 1.3 · IPMI 2.0" FontSize="11" Foreground="#9CA3AF" Margin="1,2,0,0"/>
      </StackPanel>
      <Border x:Name="ModePill" Grid.Column="1" CornerRadius="11" Padding="14,5" VerticalAlignment="Center"
              Background="#E7F6EC" BorderBrush="#BFE6CC" BorderThickness="1">
        <TextBlock x:Name="ModePillText" Text="Optimal 最优" FontSize="12" FontWeight="SemiBold" Foreground="#047857"/>
      </Border>
    </Grid>

    <!-- 温度卡片 -->
    <Border Style="{StaticResource Card}">
      <StackPanel>
        <TextBlock Text="温度 (°C)" Style="{StaticResource CardTitle}"/>
        <UniformGrid Columns="3" x:Name="TempGrid"/>
      </StackPanel>
    </Border>

    <!-- 风扇卡片 -->
    <Border Style="{StaticResource Card}" Margin="0,10,0,0">
      <StackPanel>
        <TextBlock Text="风扇转速" Style="{StaticResource CardTitle}"/>
        <UniformGrid Columns="2" x:Name="FanGrid"/>
        <TextBlock x:Name="DutyText" Text="CPU 区占空比 —" Style="{StaticResource SubT}" Margin="2,10,0,0"/>
      </StackPanel>
    </Border>

    <!-- 模式卡片 -->
    <Border Style="{StaticResource Card}" Margin="0,10,0,0">
      <StackPanel>
        <TextBlock Text="风扇模式" Style="{StaticResource CardTitle}"/>
        <UniformGrid Columns="3">
          <Button x:Name="BtnOpt" Content="安静 · Optimal" Style="{StaticResource ModeBtn}" Margin="0,0,8,0"/>
          <Button x:Name="BtnStd" Content="标准 · Standard" Style="{StaticResource ModeBtn}" Margin="4,0,4,0"/>
          <Button x:Name="BtnFul" Content="全速 · Full" Style="{StaticResource ModeBtn}" Margin="8,0,0,0"/>
        </UniformGrid>
        <TextBlock Text="安静 = BMC 智能调速 (日常推荐) · 标准 = 出厂默认 · 全速 = 最强散热" Style="{StaticResource SubT}" Margin="2,10,0,0"/>
      </StackPanel>
    </Border>

    <!-- 状态栏 -->
    <Grid Margin="2,12,2,0">
      <TextBlock x:Name="StatusText" Text="就绪。" FontSize="11.5" Foreground="#6B7280" HorizontalAlignment="Left"/>
      <TextBlock Text="每 5 秒刷新 · 命令行版 fan.ps1" FontSize="11" Foreground="#B0B6BF" HorizontalAlignment="Right"/>
    </Grid>
  </StackPanel>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Parse($xamlText)

# 窗口图标 (make-icon.ps1 生成的风扇图标)
$icoPath = Join-Path $PSScriptRoot 'assets\fan.ico'
if (Test-Path $icoPath) {
    try { $win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$icoPath) } catch { }
}

# ---- 调色板 ----
$PillGreen = @{ Fg='#047857'; Bg='#E7F6EC'; Bd='#BFE6CC' }
$PillBlue  = @{ Fg='#1D4ED8'; Bg='#E8EFFD'; Bd='#BFD3F6' }
$PillRed   = @{ Fg='#B91C1C'; Bg='#FDEAEA'; Bd='#F5C6C6' }
$PillGray  = @{ Fg='#6B7280'; Bg='#F3F4F6'; Bd='#E5E7EB' }

# ---- 动态生成温度格子 ----
$script:UI = @{}
$script:UI.TempGrid = $win.FindName('TempGrid')
$script:UI.TempVals = @{}
$script:UI.TempBars = @{}
foreach ($t in $TempDefs) {
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = '0,0,0,10'
    $n = New-Object Windows.Controls.TextBlock
    $n.Text = $t.Name; $n.FontSize = 11.5; $n.Foreground = '#6B7280'; $n.Margin = '0,0,0,1'
    [void]$sp.Children.Add($n)
    $v = New-Object Windows.Controls.TextBlock
    $v.Text = [string]::Empty; $v.FontSize = 20; $v.FontWeight = 'SemiBold'; $v.Foreground = '#111827'
    [void]$sp.Children.Add($v)
    $bar = New-Object Windows.Controls.ProgressBar
    $bar.Style = $win.Resources['FlatBar']; $bar.Width = 100; $bar.HorizontalAlignment = 'Left'
    $bar.Margin = '0,4,0,0'; $bar.Minimum = 0; $bar.Maximum = 100; $bar.Value = 0
    [void]$sp.Children.Add($bar)
    [void]$script:UI.TempGrid.Children.Add($sp)
    $script:UI.TempVals[$t.Name] = $v
    $script:UI.TempBars[$t.Name] = $bar
}

# ---- 动态生成风扇行 ----
$script:UI.FanGrid = $win.FindName('FanGrid')
$script:UI.FanVals = @{}
$script:UI.FanBars = @{}
foreach ($f in $FanDefs) {
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = '0,0,14,9'
    $grid = New-Object Windows.Controls.Grid
    $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = '*'
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
    [void]$grid.ColumnDefinitions.Add($c0); [void]$grid.ColumnDefinitions.Add($c1)
    $n = New-Object Windows.Controls.TextBlock
    $n.Text = $f.Name; $n.FontSize = 11.5; $n.Foreground = '#6B7280'; $n.VerticalAlignment = 'Bottom'; $n.Margin = '0,0,0,2'
    [void]$grid.Children.Add($n); [void][Windows.Controls.Grid]::SetColumn($n, 0)
    $v = New-Object Windows.Controls.TextBlock
    $v.Text = [string]::Empty; $v.FontSize = 15; $v.FontWeight = 'SemiBold'; $v.Foreground = '#111827'
    [void]$grid.Children.Add($v); [void][Windows.Controls.Grid]::SetColumn($v, 1)
    [void]$sp.Children.Add($grid)
    $bar = New-Object Windows.Controls.ProgressBar
    $bar.Style = $win.Resources['FlatBar']; $bar.Height = 4
    $bar.Minimum = 0; $bar.Maximum = 100; $bar.Value = 0; $bar.Margin = '0,3,0,0'
    [void]$sp.Children.Add($bar)
    [void]$script:UI.FanGrid.Children.Add($sp)
    $script:UI.FanVals[$f.Name] = $v
    $script:UI.FanBars[$f.Name] = $bar
}

$script:UI.ModePill     = $win.FindName('ModePill')
$script:UI.ModePillText = $win.FindName('ModePillText')
$script:UI.DutyText     = $win.FindName('DutyText')
$script:UI.StatusText   = $win.FindName('StatusText')
$BtnOpt = $win.FindName('BtnOpt'); $BtnStd = $win.FindName('BtnStd'); $BtnFul = $win.FindName('BtnFul')

function Set-Pill($palette) {
    $script:UI.ModePill.Background = $palette.Bg
    $script:UI.ModePill.BorderBrush = $palette.Bd
    $script:UI.ModePillText.Foreground = $palette.Fg
}
function Set-Status([string]$t) {
    $script:UI.StatusText.Text = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $t
}
function Set-ModeBtnVisual($active) {
    $map = @{ 2 = $BtnOpt; 0 = $BtnStd; 1 = $BtnFul }
    $acc = @{ 2 = '#059669'; 0 = '#2563EB'; 1 = '#DC2626' }
    foreach ($k in $map.Keys) {
        $b = $map[$k]
        [void]$b.ApplyTemplate()
        $bd = $b.Template.FindName('bd', $b)
        $tx = $b.Template.FindName('tx', $b)
        if ($null -eq $bd -or $null -eq $tx) { continue }
        if ($k -eq $active) {
            $bd.Background = $acc[$k]; $bd.BorderBrush = $acc[$k]; $tx.Foreground = '#FFFFFF'
        } else {
            $bd.Background = '#FFFFFF'; $bd.BorderBrush = '#D8DCE2'; $tx.Foreground = '#374151'
        }
    }
}

function Invoke-Refresh {
    try {
        $mode = Get-FanModeCode
        if ($ModeNames.ContainsKey($mode)) {
            $script:UI.ModePillText.Text = $ModeNames[$mode]
            switch ($mode) {
                2 { Set-Pill $PillGreen }
                0 { Set-Pill $PillBlue }
                1 { Set-Pill $PillRed }
                default { Set-Pill $PillGray }
            }
            Set-ModeBtnVisual $mode
        } else {
            $script:UI.ModePillText.Text = '未知'; Set-Pill $PillGray
        }
        foreach ($f in $FanDefs) {
            $raw = Read-SensorRaw ([byte]$f.Num)
            $v = $script:UI.FanVals[$f.Name]; $bar = $script:UI.FanBars[$f.Name]
            if ($null -ne $raw -and $raw -gt 0) {
                $rpm = $raw * 140
                $v.Text = [string]$rpm; $v.Foreground = '#111827'
                $bar.Value = [math]::Min(100, $rpm / 25)
                $bar.Foreground = if ($rpm -ge 1900) { '#EF4444' } elseif ($rpm -ge 1250) { '#F59E0B' } else { '#10B981' }
            } else {
                $v.Text = '空位'; $v.Foreground = '#C4C9D0'; $bar.Value = 0
            }
        }
        $duty = Get-Duty 0x00
        if ($duty -ge 0) { $script:UI.DutyText.Text = "CPU 区占空比 $duty% · BMC 自动曲线当前输出 · 空位 = 未插风扇" }
        foreach ($t in $TempDefs) {
            $raw = Read-SensorRaw ([byte]$t.Num)
            $v = $script:UI.TempVals[$t.Name]; $bar = $script:UI.TempBars[$t.Name]
            if ($null -ne $raw -and $raw -gt 0) {
                $v.Text = [string]$raw
                $v.Foreground = if ($raw -ge 75) { '#DC2626' } elseif ($raw -ge 60) { '#D97706' } else { '#059669' }
                $bar.Value = [math]::Min(100, $raw)
                $bar.Foreground = if ($raw -ge 75) { '#EF4444' } elseif ($raw -ge 60) { '#F59E0B' } else { '#10B981' }
            } else { $v.Text = '—'; $v.Foreground = '#C4C9D0'; $bar.Value = 0 }
        }
    } catch { Set-Status ("刷新失败: " + $_.Exception.Message) }
}

function Invoke-ApplyMode([int]$code, [string]$label) {
    $script:timer.Stop()
    try {
        Set-Status "正在切换到 $label ..."
        [void](Set-FanModeCode $code)
        Start-Sleep -Milliseconds 1200
        Invoke-Refresh
        $now = Get-FanModeCode
        if ($now -eq $code) { Set-Status "已切换到 $label (BMC 回读确认)。" }
        else { Set-Status "切换后回读为 [$($ModeNames[$now])], 请再点一次。" }
    } catch {
        Set-Status ("切换失败: " + $_.Exception.Message)
    } finally {
        $script:timer.Start()
    }
}
$BtnOpt.Add_Click({ Invoke-ApplyMode 2 '安静模式 Optimal' })
$BtnStd.Add_Click({ Invoke-ApplyMode 0 '标准模式 Standard' })
$BtnFul.Add_Click({
    $r = [Windows.MessageBox]::Show('全速模式噪音很大, 确定切换吗?', '确认', 'YesNo', 'Warning')
    if ($r -eq 'Yes') { Invoke-ApplyMode 1 '全速模式 Full' }
})

$script:timer = New-Object Windows.Threading.DispatcherTimer
$script:timer.Interval = [TimeSpan]::FromSeconds(5)
$script:timer.Add_Tick({ Invoke-Refresh })
$script:timer.Start()

if (-not [Environment]::UserInteractive) {
    Invoke-Refresh; Start-Sleep -Seconds 3; Invoke-Refresh
    Write-Output ("SELFTEST mode=[{0}] duty=[{1}] FAN1=[{2}] CPU1=[{3}]" -f `
        $script:UI.ModePillText.Text, $script:UI.DutyText.Text, $script:UI.FanVals['FAN1'].Text, $script:UI.TempVals['CPU1'].Text)
    exit 0
}
[void]$win.ShowDialog()
