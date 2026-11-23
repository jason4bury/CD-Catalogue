<#
.SYNOPSIS
    CD Catalogue - A searchable list of your CDs, with artist, album, year and cover.

.DESCRIPTION
    PowerShell/WPF tool for cataloguing a CD collection.

    Project layout (house style):
        <project>\Source\               the git repo (this script is in Source\src\)
        <project>\Source\assets\        icon (.ico) and logo (.png)
        <project>\Builds\               "CD Catalogue v<version>\" release folders, their zips and
                                        "CD Catalogue.lnk", made by Build.cmd (no exe)
    Settings and data: %APPDATA%\CD Catalogue

.NOTES
    Author:    Jason Rhodes
    Copyright: (c) 2026 Jason Rhodes - MIT licence (see LICENSE)
    Version:   see $script:AppVersion below and CHANGELOG.md
    Runs in Windows PowerShell 5.1 on an STA thread (WPF needs it).
#>

#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

# The version lives here and in CHANGELOG.md; Build.cmd stops if they disagree.
# Two-digit minor: 1.00, 1.01 ... 1.10. The release folder is "CD Catalogue v<version>".
$script:AppName     = 'CD Catalogue'
$script:AppVersion  = '1.03'
$script:Description = 'PowerShell/WPF tool for cataloguing a CD collection'
$script:Copyright   = 'Copyright (c) 2026 Jason Rhodes'
$script:RepoUrl     = 'https://github.com/jason4bury/CD-Catalogue'
$script:IsPrivate   = $false  # public tool: settings and data in %APPDATA%\<App Name>
$script:AppId       = 'jason4bury.CD-Catalogue'   # taskbar ID; the shortcut made by New-CDCatalogueShortcut.ps1 uses the same one

# ---------------------------------------------------------------------------
#  Where is everything? No exe: this script runs from Source\src\ (while
#  developing) or from a release folder, Builds\CD Catalogue v<version>\ (or
#  wherever the release zip was unpacked), with assets\ beside it.
# ---------------------------------------------------------------------------
# WPF needs an STA thread. Started any other way, restart in Windows PowerShell with -STA.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    return
}

# One taskbar button with the tool's own icon (not PowerShell's), and pinning it pins the tool.
try {
    Add-Type -Namespace 'HomeTool' -Name 'Shell' -MemberDefinition '[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);'
    [void][HomeTool.Shell]::SetCurrentProcessExplicitAppUserModelID($script:AppId)
} catch { Write-Verbose "No taskbar ID: $($_.Exception.Message)" }

$script:ProgramDir = Split-Path -Parent $PSCommandPath
$script:AssetsDir  = @((Join-Path $script:ProgramDir 'assets'), (Join-Path (Split-Path -Parent $script:ProgramDir) 'assets')) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $script:AssetsDir) { $script:AssetsDir = Join-Path $script:ProgramDir 'assets' }

function Get-DataDir {
    <# Public tools: %APPDATA%\<App Name>. Private tools: <project>\Data, beside Source\ and
       Builds\, so nothing is written to the unencrypted drive. Never inside Source\ (keeps
       personal data out of git) or a release folder (each version has its own, so data kept
       there would be left behind by the next version). #>
    if (-not $script:IsPrivate) { return (Join-Path $env:APPDATA $script:AppName) }
    $up = Split-Path -Parent $script:ProgramDir
    # Source\src\<script> or Builds\<App> v<x.yy>\<script>: <project> is two levels up.
    if (@('Source', 'Builds') -contains (Split-Path -Leaf $up)) { return (Join-Path (Split-Path -Parent $up) 'Data') }
    return (Join-Path $script:ProgramDir 'Data')   # an unpacked release zip somewhere else
}
$script:DataDir      = Get-DataDir
$script:SettingsPath = Join-Path $script:DataDir 'settings.json'
$script:LogPath      = Join-Path $script:DataDir "$($script:AppName).log"
if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# ---------------------------------------------------------------------------
#  Small helpers
# ---------------------------------------------------------------------------
function Write-AppLog {
    param([string]$Message)
    try { Add-Content -LiteralPath $script:LogPath -Value ('{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 }
    catch { Write-Verbose "Couldn't write the log: $($_.Exception.Message)" }
}

function Get-AssetImage {
    <# A frozen BitmapImage for a WPF Image or window Icon, or $null if the asset is missing. #>
    param([string]$Name)
    $path = Join-Path $script:AssetsDir $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $img = New-Object Windows.Media.Imaging.BitmapImage
    $img.BeginInit()
    $img.StreamSource = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($path))
    $img.CacheOption  = 'OnLoad'
    $img.EndInit(); $img.Freeze()
    return $img
}


function Get-AppSetting {
    <# Settings from settings.json in the data folder: the look, and covers or list. The CDs are in catalogue.json. #>
    $s = @{ Look = 'Light'; View = 'Covers' }
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            $j = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $s[$p.Name] = [string]$p.Value }
        } catch { Write-AppLog "settings.json couldn't be read: $($_.Exception.Message)" }
    }
    return $s
}

function Save-AppSetting {
    try { [pscustomobject]$script:Settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8 }
    catch { Write-AppLog "settings.json couldn't be saved: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
#  Look: Light, Dark or System (follow Windows). Used from the next start.
# ---------------------------------------------------------------------------
$script:Settings = Get-AppSetting
function Test-DarkLook {
    switch ($script:Settings.Look) {
        'Dark' { return $true }
        'System' {
            try { return ([int](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 0) }
            catch { return $false }
        }
        default { return $false }
    }
}
$script:Dark = Test-DarkLook
$script:Palette = if ($script:Dark) {
    @{ Page = '#101B1C'; Card = '#182728'; Line = '#2B3F40'; Ink = '#EAF2F0'; Soft = '#93A9A6'; Accent = '#F4B740'; AccentInk = '#17201F'
       Field = '#213435'; Chip = '#223637'; Hover = '#263D3E'; Select = '#31504F'; Thumb = '#3C5756'; Sleeve = '#213435'; Disc = '#45615F'
       Rail = '#0A1314'; RailInk = '#DCE9E6'; RailMark = '#F4B740'; RailHover = '#1A2A2B'
       Good = '#5FD3A0'; Warn = '#F0A85C'; Bad = '#F07178' }
} else {
    @{ Page = '#E9F0EE'; Card = '#FBFDFC'; Line = '#C5D5D1'; Ink = '#142625'; Soft = '#536966'; Accent = '#0C6663'; AccentInk = '#FFFFFF'
       Field = '#EBF1EF'; Chip = '#E3ECEA'; Hover = '#D8E6E2'; Select = '#C0DCD6'; Thumb = '#AFC4BF'; Sleeve = '#D3E1DE'; Disc = '#9DB8B3'
       Rail = '#0B3C3D'; RailInk = '#E3EFEC'; RailMark = '#F4B740'; RailHover = '#165051'
       Good = '#146C45'; Warn = '#8A4F00'; Bad = '#B3261E' }
}
$script:BrushConv = New-Object Windows.Media.BrushConverter
function Get-Brush([string]$Key) { return $script:BrushConv.ConvertFromString($script:Palette[$Key]) }

function Set-TitleBar([Windows.Window]$Window) {
    <# The window's own shape: rounded corners and a hairline edge (Windows 11; older Windows ignores it). #>
    try {
        if (-not ('CdDwm' -as [type])) { Add-Type -Namespace '' -Name 'CdDwm' -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr h, int a, ref int v, int s);' }
        $h = (New-Object Windows.Interop.WindowInteropHelper $Window).EnsureHandle()
        $on = [int]$script:Dark; [void][CdDwm]::DwmSetWindowAttribute($h, 20, [ref]$on, 4)
        $round = 2; [void][CdDwm]::DwmSetWindowAttribute($h, 33, [ref]$round, 4)
        $c = $script:Palette.Line                                                   # #RRGGBB, wanted as 0x00BBGGRR
        $edge = [Convert]::ToInt32($c.Substring(5, 2) + $c.Substring(3, 2) + $c.Substring(1, 2), 16)
        [void][CdDwm]::DwmSetWindowAttribute($h, 34, [ref]$edge, 4)
    } catch { Write-Verbose 'no rounded corners' }
}

function Expand-Xaml([string]$Xaml) {
    <# Puts the look's colours into a window's XAML ({Page}, {Ink} ...). #>
    foreach ($k in $script:Palette.Keys) { $Xaml = $Xaml.Replace("{$k}", $script:Palette[$k]) }
    return $Xaml
}

# Every window draws its own top strip instead of Windows' title bar. It can still be dragged, snapped,
# double-clicked to maximise and resized from its edges. The main window's content runs up behind the strip.
$script:FrameXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework" TextElement.Foreground="{Ink}">
  <Grid.Resources>
    <Style x:Key="Dot" TargetType="Button">
      <Setter Property="Width" Value="30"/><Setter Property="Height" Value="30"/><Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="Focusable" Value="False"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="shell:WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Grid>
          <Ellipse x:Name="E" Fill="{Chip}"/>
          <Path x:Name="P" Data="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" Stroke="{Ink}" StrokeThickness="1.4"
                StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="None" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="E" Property="Fill" Value="{Accent}"/><Setter TargetName="P" Property="Stroke" Value="{AccentInk}"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
  </Grid.Resources>
  <Grid.RowDefinitions><RowDefinition Height="48"/><RowDefinition/></Grid.RowDefinitions>
  <ContentPresenter x:Name="Body" Grid.Row="1"/>
  <TextBlock x:Name="Caption" Text="{Binding Title, RelativeSource={RelativeSource AncestorType=Window}}" FontSize="16" FontWeight="SemiBold"
             VerticalAlignment="Center" Margin="22,4,140,0" TextTrimming="CharacterEllipsis" IsHitTestVisible="False"/>
  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,4,12,0">
    <Button x:Name="WinMin" Style="{StaticResource Dot}" Tag="M0,5 L10,5 M0,0 M0,10" ToolTip="Minimise"/>
    <Button x:Name="WinMax" Style="{StaticResource Dot}" Tag="M0,4 L0,0 L4,0 M10,6 L10,10 L6,10" ToolTip="Maximise or restore"/>
    <Button x:Name="WinClose" Style="{StaticResource Dot}" Tag="M0,0 L10,10 M10,0 L0,10" ToolTip="Close"/>
  </StackPanel>
</Grid>
'@

function New-XamlWindow {
    param([Parameter(Mandatory)][string]$Xaml, [Windows.Window]$Owner)
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml](Expand-Xaml $Xaml))))
    if ($Owner) { $w.Owner = $Owner; $w.Icon = $Owner.Icon }
    $sized = $w.ResizeMode -ne 'NoResize'

    $chrome = New-Object Windows.Shell.WindowChrome
    $chrome.CaptionHeight = 48
    $chrome.ResizeBorderThickness = if ($sized) { New-Object Windows.Thickness 6 } else { New-Object Windows.Thickness 0 }
    $chrome.GlassFrameThickness = New-Object Windows.Thickness 0, 0, 0, 1      # keeps Windows' shadow
    $chrome.CornerRadius = New-Object Windows.CornerRadius 0
    $chrome.UseAeroCaptionButtons = $false
    [Windows.Shell.WindowChrome]::SetWindowChrome($w, $chrome)

    $frame = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml](Expand-Xaml $script:FrameXaml))))
    $body = $frame.FindName('Body')
    $content = $w.Content; $w.Content = $null
    $body.Content = $content
    if ($w.Tag -eq 'bare') {                                                   # the main window
        [Windows.Controls.Grid]::SetRow($body, 0); [Windows.Controls.Grid]::SetRowSpan($body, 2)
        $frame.FindName('Caption').Visibility = 'Collapsed'
    }
    $min = $frame.FindName('WinMin'); $max = $frame.FindName('WinMax')
    if ($w.Tag -ne 'bare') { $min.Visibility = 'Collapsed' }
    if (-not $sized) { $max.Visibility = 'Collapsed' }
    $min.Add_Click({ [Windows.Window]::GetWindow($this).WindowState = 'Minimized' })
    $max.Add_Click({ $win = [Windows.Window]::GetWindow($this); $win.WindowState = if ($win.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } })
    $frame.FindName('WinClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    $w.Content = $frame

    $w.Add_SourceInitialized({ Set-TitleBar $this })
    # A maximised window hangs over the screen's edge by the width of its (unseen) border.
    $w.Add_StateChanged({ $this.Content.Margin = New-Object Windows.Thickness $(if ($this.WindowState -eq 'Maximized') { 7 } else { 0 }) })
    # WPF mis-measures a window sized to its content when it has its own frame, until asked again.
    if ($w.SizeToContent -ne 'Manual') { $w.Add_ContentRendered({ $this.InvalidateMeasure() }) }
    return $w
}

# Shared styles: pill buttons, round-cornered fields, slim scroll bars, tooltips.
$script:Styles = @'
    <Style x:Key="FocusRing">
      <Setter Property="Control.Template"><Setter.Value><ControlTemplate>
        <Rectangle Margin="-2" RadiusX="16" RadiusY="16" Stroke="{Accent}" StrokeThickness="2"/>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{Ink}"/><Setter Property="Background" Value="{Chip}"/><Setter Property="BorderBrush" Value="{Chip}"/>
      <Setter Property="Padding" Value="17,8"/><Setter Property="Margin" Value="0,0,8,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="17" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{Hover}"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Background" Value="{Select}"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.4"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Accent" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{Accent}"/><Setter Property="Foreground" Value="{AccentInk}"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="17" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.88"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.7"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.4"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="BuThumb" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb">
        <Border x:Name="T" CornerRadius="3" Background="{Thumb}"/>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="{Soft}"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="BuPage" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/><Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Vertical">
          <Setter Property="Width" Value="12"/><Setter Property="MinWidth" Value="12"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True" Width="6" HorizontalAlignment="Center" Margin="0,3">
                <Track.Resources><s:Double xmlns:s="clr-namespace:System;assembly=mscorlib" x:Key="{x:Static SystemParameters.VerticalScrollBarButtonHeightKey}">72</s:Double></Track.Resources>
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource BuThumb}"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Height" Value="12"/><Setter Property="MinHeight" Value="12"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" Height="6" VerticalAlignment="Center" Margin="3,0">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource BuThumb}"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ToolTip">
      <Setter Property="Foreground" Value="{Page}"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToolTip">
        <Border Background="{Ink}" CornerRadius="9" Padding="11,7" MaxWidth="360">
          <ContentPresenter><ContentPresenter.Resources><Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style></ContentPresenter.Resources></ContentPresenter>
        </Border>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{Field}"/><Setter Property="Foreground" Value="{Ink}"/><Setter Property="BorderBrush" Value="{Field}"/>
      <Setter Property="CaretBrush" Value="{Ink}"/><Setter Property="SelectionBrush" Value="{Accent}"/>
      <Setter Property="Padding" Value="10,7"/><Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox">
        <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1.5" CornerRadius="11">
          <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" Focusable="False"/>
        </Border>
        <ControlTemplate.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{Accent}"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
'@

#region MESSAGES
# ---------------------------------------------------------------------------
#  Messages and questions in the app's own look (not Windows' grey MessageBox)
# ---------------------------------------------------------------------------
$script:MessageXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="Height" Width="460" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Bahnschrift, Segoe UI" FontSize="13.5" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <StackPanel Margin="22,8,22,18">
    <TextBlock x:Name="MsgText" TextWrapping="Wrap" LineHeight="20"/>
    <TextBox x:Name="MsgInput" Margin="0,12,0,0" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
      <Button x:Name="MsgYes" Style="{StaticResource Accent}" MinWidth="80" IsDefault="True"/>
      <Button x:Name="MsgNo" MinWidth="80" Margin="0" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@.Replace('STYLES', $script:Styles)

function Show-AppChoice([string]$Text, [string]$First, [string]$Second, [string]$Title = $script:AppName, [string]$Third) {
    <# Two (or three) choices: 1 for the first button, 2 for the second, 3 for the third, $null when the window is closed. #>
    $w = New-XamlWindow $script:MessageXaml $script:Window
    $w.Title = $Title
    $w.FindName('MsgText').Text = $Text
    $one = $w.FindName('MsgYes'); $two = $w.FindName('MsgNo')
    $one.Content = $First; $two.Content = $Second; $two.IsCancel = $false
    $script:ChoiceAnswer = $null
    $one.Add_Click({ $script:ChoiceAnswer = 1; $w.Close() })
    $two.Add_Click({ $script:ChoiceAnswer = 2; $w.Close() })
    if ($Third) {
        $two.Margin = '0,0,8,0'
        $three = New-Object Windows.Controls.Button
        $three.Content = $Third; $three.MinWidth = 80; $three.Margin = '0'
        $three.Add_Click({ $script:ChoiceAnswer = 3; $w.Close() })
        [void]$one.Parent.Children.Add($three)
    }
    [void]$w.ShowDialog()
    return $script:ChoiceAnswer
}

function Show-AppMessage {
    <# A message, a question (with -NoText: $true for the first button) or, with -Ask,
       a question with a text box (returns the text, or $null when cancelled). #>
    param([Parameter(Mandatory)][string]$Text, [string]$Title = $script:AppName, [string]$YesText = 'OK', [string]$NoText,
          [switch]$Ask, [string]$Default = '', [Windows.Window]$Owner = $script:Window)
    $w = New-XamlWindow $script:MessageXaml $Owner
    $w.Title = $Title
    $w.FindName('MsgText').Text = $Text
    $yes = $w.FindName('MsgYes'); $no = $w.FindName('MsgNo'); $box = $w.FindName('MsgInput')
    $yes.Content = $YesText
    if ($NoText) { $no.Content = $NoText } else { $no.Visibility = 'Collapsed'; $yes.Margin = '0'; $yes.IsCancel = $true }
    if ($Ask) { $box.Visibility = 'Visible'; $box.Text = $Default; $w.Add_ContentRendered({ $box.Focus(); $box.SelectAll() }) }
    $script:MsgAnswer = $false
    $yes.Add_Click({ $script:MsgAnswer = $true; $w.Close() })
    $no.Add_Click({ $w.Close() })
    [void]$w.ShowDialog()
    if ($Ask) { if ($script:MsgAnswer) { return $box.Text.Trim() } else { return $null } }
    return $script:MsgAnswer
}
#endregion MESSAGES

#region ABOUT-BOX
# ---------------------------------------------------------------------------
#  About box (house style): logo, name, version, the one-line description,
#  the copyright and MIT licence, the repo link and where settings live.
# ---------------------------------------------------------------------------
$script:AboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="486" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Bahnschrift, Segoe UI" FontSize="13.5" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <StackPanel Margin="22,8,22,20" Width="440">
    <StackPanel Orientation="Horizontal">
      <Image x:Name="AboutLogo" Width="64" Height="64" Margin="0,0,16,0" RenderOptions.BitmapScalingMode="HighQuality"/>
      <StackPanel VerticalAlignment="Center">
        <TextBlock x:Name="AboutName" FontSize="20" FontWeight="SemiBold"/>
        <TextBlock x:Name="AboutVersion" Foreground="{Soft}"/>
      </StackPanel>
    </StackPanel>
    <TextBlock x:Name="AboutDescription" TextWrapping="Wrap" Margin="0,14,0,0"/>
    <TextBlock x:Name="AboutData" TextWrapping="Wrap" Margin="0,10,0,0" Foreground="{Soft}"/>
    <TextBlock Margin="0,10,0,0"><Hyperlink x:Name="AboutRepo" Foreground="{Accent}"><Run x:Name="AboutRepoText"/></Hyperlink></TextBlock>
    <TextBlock x:Name="AboutCopyright" Margin="0,4,0,0" Foreground="{Soft}"/>
    <Button x:Name="AboutClose" Content="Close" HorizontalAlignment="Right" MinWidth="80" Margin="0,16,0,0" IsDefault="True" IsCancel="True"/>
  </StackPanel>
</Window>
'@.Replace('STYLES', $script:Styles)

function Show-About {
    param([Windows.Window]$Owner)
    $w = New-XamlWindow $script:AboutXaml $Owner
    $w.Title = "About $script:AppName"
    $w.FindName('AboutLogo').Source       = Get-AssetImage 'CD-Catalogue.png'
    $w.FindName('AboutName').Text         = $script:AppName
    $w.FindName('AboutVersion').Text      = "Version $script:AppVersion"
    $w.FindName('AboutDescription').Text  = $script:Description
    $w.FindName('AboutData').Text         = "Settings and data: $script:DataDir"
    $w.FindName('AboutRepoText').Text     = $script:RepoUrl
    $w.FindName('AboutRepo').NavigateUri  = [Uri]$script:RepoUrl
    $w.FindName('AboutRepo').Add_RequestNavigate({ param($s, $e) Start-Process $e.Uri.AbsoluteUri; $e.Handled = $true })
    $w.FindName('AboutCopyright').Text    = "$script:Copyright  ·  MIT licence"
    $w.FindName('AboutClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}
#endregion ABOUT-BOX

#region CATALOGUE
# ---------------------------------------------------------------------------
#  The catalogue: one line per physical CD, kept in catalogue.json in the data
#  folder. A CD is added by its barcode (a USB or Bluetooth barcode scanner
#  types it in, or type the number under the bars): MusicBrainz gives the
#  artist, album, year, label and tracks, and the Cover Art Archive the cover
#  (both free, no account needed). CDs without a barcode can be added by hand.
# ---------------------------------------------------------------------------
if (-not ('CdItem' -as [type])) {
    $wpf = @([Windows.Window], [Windows.Media.Visual], [Windows.DependencyObject], [Windows.Markup.XamlReader]) | ForEach-Object { $_.Assembly.Location }
    $wpf += [System.Xaml.XamlReader].Assembly.Location
    Add-Type -ReferencedAssemblies ($wpf | Select-Object -Unique) -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Specialized;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;

public class ArtistRow {
    public string Key { get; set; }
    public string Name { get; set; }
    public string Meta { get; set; }
    public string Sort { get; set; }
    public int Count { get; set; }
}

public class CdItem {
    public string YearText { get { return string.IsNullOrEmpty(Year) ? "Year unknown" : Year; } }
    static readonly ConcurrentDictionary<string, ImageSource> Small = new ConcurrentDictionary<string, ImageSource>();

    public string Id { get; set; }
    public string Barcode { get; set; }
    public string Artist { get; set; }
    public string Album { get; set; }
    public string Year { get; set; }
    public string Genre { get; set; }
    public string Label { get; set; }
    public string Country { get; set; }
    public int Tracks { get; set; }
    public int Discs { get; set; }
    public string Cover { get; set; }      // picture file saved in the app's Covers folder (or one you chose)
    public string Notes { get; set; }
    public string Shelf { get; set; }      // where the CD is kept: a shelf, box or room
    public string TrackText { get; set; }  // its track titles, one a line (kept in Tracks\, not in catalogue.json)
    public string Disc { get; set; }       // a photo of the disc itself (its label), or '-' when the Cover Art Archive has none
    public string DiscOf { get; set; }     // the MusicBrainz release that Disc was looked for (so a new version is looked again)
    public string DiscWhen { get; set; }   // when it was looked for: a CD with no photo is looked again a week later
    public string Added { get; set; }
    public string Mbid { get; set; }       // MusicBrainz release ('-' once looked up and not found)
    // For putting CDs in artist order: "The" skipped, and CDs with no artist last.
    public int NoArtist { get { return string.IsNullOrWhiteSpace(Artist) ? 1 : 0; } }
    public string ArtistSort { get { var a = (Artist ?? "").Trim().ToLowerInvariant();
        return a.StartsWith("the ", StringComparison.OrdinalIgnoreCase) ? a.Substring(4).TrimStart() : a; } }
    public bool FromMb { get { return !string.IsNullOrEmpty(Mbid) && Mbid != "-"; } }   // details from MusicBrainz, else typed in
    public string Source { get { return FromMb ? "MusicBrainz" : "By hand"; } }
    public string Shown { get { return Cover != null && Cover != "" && System.IO.File.Exists(Cover) ? Cover : null; } }
    public string Title { get { return Album != null && Album != "" ? Album : "(not found) " + Barcode; } }

    // The cover at tile size, kept: thousands of full-size covers would take gigabytes of memory.
    public ImageSource Thumb {
        get {
            string f = Shown;
            if (f == null) return null;
            try {
                string key = f + "|" + System.IO.File.GetLastWriteTimeUtc(f).Ticks;
                return Small.GetOrAdd(key, k => {
                    var b = new BitmapImage();
                    using (var s = System.IO.File.OpenRead(f)) {
                        b.BeginInit(); b.CacheOption = BitmapCacheOption.OnLoad; b.DecodePixelWidth = 260; b.StreamSource = s; b.EndInit();
                    }
                    b.Freeze();
                    return b;
                });
            } catch (Exception) { return null; }   // an unreadable picture shows as a plain disc
        }
    }
}

// The wall of covers: a grid that only makes the tiles on screen, so thousands of CDs stay quick.
// (WPF's WrapPanel makes every tile, and again after each scan.)
public class CdWallPanel : VirtualizingPanel, IScrollInfo {
    const double TileWidth = 166, TextHeight = 46;
    int cols = 1;
    double cellW = TileWidth, cellH = TileWidth + TextHeight, top;
    Size view, extent;

    protected override Size MeasureOverride(Size avail) {
        UIElementCollection kids = InternalChildren;   // has to be touched before the generator is used
        IItemContainerGenerator gen = ItemContainerGenerator;
        int n = ItemsControl.GetItemsOwner(this).Items.Count;
        double w = double.IsInfinity(avail.Width) ? TileWidth * 4 : avail.Width;
        double h = double.IsInfinity(avail.Height) ? 600 : avail.Height;
        cols = Math.Max(1, (int)(w / TileWidth));
        cellW = w / cols; cellH = cellW + TextHeight;
        double all = Math.Ceiling(n / (double)cols) * cellH;
        top = Math.Max(0, Math.Min(top, all - h));
        int first = Math.Max(0, (int)(top / cellH) - 1) * cols;
        int last = Math.Min(n - 1, ((int)((top + h) / cellH) + 2) * cols - 1);

        for (int i = kids.Count - 1; i >= 0; i--) {
            var pos = new GeneratorPosition(i, 0);
            int at = gen.IndexFromGeneratorPosition(pos);
            if (at < first || at > last) { gen.Remove(pos, 1); RemoveInternalChildRange(i, 1); }
        }
        if (n > 0 && last >= first) {
            GeneratorPosition start = gen.GeneratorPositionFromIndex(first);
            int c = start.Offset == 0 ? start.Index : start.Index + 1;
            using (gen.StartAt(start, GeneratorDirection.Forward, true)) {
                for (int i = first; i <= last; i++, c++) {
                    bool made;
                    var el = gen.GenerateNext(out made) as UIElement;
                    if (el == null) break;
                    if (made) {
                        if (c >= kids.Count) AddInternalChild(el); else InsertInternalChild(c, el);
                        gen.PrepareItemContainer(el);
                    }
                    el.Measure(new Size(cellW, cellH));
                }
            }
        }
        var nowView = new Size(w, h); var nowExtent = new Size(w, all);
        if (nowView != view || nowExtent != extent) {
            view = nowView; extent = nowExtent;
            if (ScrollOwner != null) ScrollOwner.InvalidateScrollInfo();
        }
        return nowView;
    }

    protected override Size ArrangeOverride(Size size) {
        IItemContainerGenerator gen = ItemContainerGenerator;
        for (int i = 0; i < InternalChildren.Count; i++) {
            int at = gen.IndexFromGeneratorPosition(new GeneratorPosition(i, 0));
            if (at >= 0) InternalChildren[i].Arrange(new Rect((at % cols) * cellW, (at / cols) * cellH - top, cellW, cellH));
        }
        return size;
    }

    protected override void OnItemsChanged(object sender, ItemsChangedEventArgs e) {
        if (e.Action == NotifyCollectionChangedAction.Remove || e.Action == NotifyCollectionChangedAction.Replace) {
            if (e.ItemUICount > 0) RemoveInternalChildRange(e.Position.Index, e.ItemUICount);
        } else if (e.Action == NotifyCollectionChangedAction.Move) {
            if (e.ItemUICount > 0) RemoveInternalChildRange(e.OldPosition.Index, e.ItemUICount);
        }
        InvalidateMeasure();
    }

    void Show(int index) {
        double y = (index / cols) * cellH;
        if (y < top) SetVerticalOffset(y);
        else if (y + cellH > top + view.Height) SetVerticalOffset(y + cellH - view.Height);
    }

    protected override void BringIndexIntoView(int index) {
        UpdateLayout(); Show(index); UpdateLayout();
    }

    public Rect MakeVisible(Visual v, Rect r) {
        for (int i = 0; i < InternalChildren.Count; i++) {
            UIElement el = InternalChildren[i];
            if (el == v || el.IsAncestorOf(v)) {
                int at = ItemContainerGenerator == null ? -1 : ((IItemContainerGenerator)ItemContainerGenerator).IndexFromGeneratorPosition(new GeneratorPosition(i, 0));
                if (at >= 0) { Show(at); return new Rect((at % cols) * cellW, (at / cols) * cellH - top, cellW, cellH); }
            }
        }
        return r;
    }

    public void SetVerticalOffset(double y) {
        y = Math.Max(0, Math.Min(y, extent.Height - view.Height));
        if (y == top) return;
        top = y;
        if (ScrollOwner != null) ScrollOwner.InvalidateScrollInfo();
        InvalidateMeasure(); InvalidateArrange();
    }
    public void SetHorizontalOffset(double x) { }
    public bool CanVerticallyScroll { get; set; }
    public bool CanHorizontallyScroll { get; set; }
    public ScrollViewer ScrollOwner { get; set; }
    public double ExtentWidth { get { return extent.Width; } }
    public double ExtentHeight { get { return extent.Height; } }
    public double ViewportWidth { get { return view.Width; } }
    public double ViewportHeight { get { return view.Height; } }
    public double HorizontalOffset { get { return 0; } }
    public double VerticalOffset { get { return top; } }
    public void LineUp() { SetVerticalOffset(top - 48); }
    public void LineDown() { SetVerticalOffset(top + 48); }
    public void PageUp() { SetVerticalOffset(top - view.Height); }
    public void PageDown() { SetVerticalOffset(top + view.Height); }
    public void MouseWheelUp() { SetVerticalOffset(top - 96); }
    public void MouseWheelDown() { SetVerticalOffset(top + 96); }
    public void LineLeft() { }
    public void LineRight() { }
    public void PageLeft() { }
    public void PageRight() { }
    public void MouseWheelLeft() { }
    public void MouseWheelRight() { }
}
'@
}

$script:CatalogPath = Join-Path $script:DataDir 'catalogue.json'
$script:CoverDir = Join-Path $script:DataDir 'Covers'
$script:Items = New-Object Collections.ObjectModel.ObservableCollection[CdItem]
$script:Fields = 'Id', 'Barcode', 'Artist', 'Album', 'Year', 'Genre', 'Label', 'Country', 'Cover', 'Notes', 'Added', 'Mbid', 'Disc', 'DiscOf', 'DiscWhen', 'Shelf'

function Save-Catalogue {
    try {
        @($script:Items | Select-Object ($script:Fields + 'Tracks', 'Discs')) | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $script:CatalogPath -Encoding UTF8
    } catch { Write-AppLog "catalogue.json couldn't be saved: $($_.Exception.Message)" }
}

$script:TrackDir = Join-Path $script:DataDir 'Tracks'   # each CD's track titles, for searching by song
function Read-Catalogue {
    if (-not (Test-Path -LiteralPath $script:CatalogPath)) { return }
    try {
        $saved = Get-Content -LiteralPath $script:CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json   # kept in a variable: Windows PowerShell passes a JSON array on as one item
        foreach ($r in $saved) {
            $i = New-Object CdItem
            foreach ($p in $script:Fields) { $i.$p = [string]$r.$p }
            $i.Tracks = [int]$r.Tracks; $i.Discs = [int]$r.Discs
            foreach ($p in 'Cover', 'Disc') { if ($i.$p -and $i.$p -ne '-' -and -not [IO.Path]::IsPathRooted($i.$p)) { $i.$p = Join-Path $script:DataDir $i.$p } }
            if ($i.Mbid -and $i.Mbid -ne '-') {
                $tf = Join-Path $script:TrackDir "$($i.Mbid).txt"
                if (Test-Path -LiteralPath $tf) { $i.TrackText = [IO.File]::ReadAllText($tf) }
            }
            $script:Items.Add($i)
        }
    } catch { Write-AppLog "catalogue.json couldn't be read: $($_.Exception.Message)" }
}

# Look-ups run in the background (a runspace), one a second or so: MusicBrainz asks for at most one
# request a second and a name for the app, and answers 503 when it's busy (then we wait and retry).
# A job is a barcode ({ Barcode }, or { Barcode; ListOnly } for just its versions), one version to switch
# a CD to ({ Id; ReleaseId }) or a CD to complete ({ Id; Artist; Album; NeedCover }).
$script:LookupScan = {
    param($Sync, [string]$CoverDir, [string]$Agent)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Test-Path -LiteralPath $CoverDir)) { New-Item -ItemType Directory -Path $CoverDir -Force | Out-Null }
    function Get-Mb([string]$Url) {
        for ($try = 1; ; $try++) {
            try { return Invoke-RestMethod -Uri $Url -UserAgent $Agent -TimeoutSec 20 }
            catch { if ($try -ge 6 -or "$($_.Exception.Message)" -notmatch '503') { throw }; Start-Sleep -Seconds (4 * $try) }
        }
    }
    function Get-Cover([string]$Release, [string]$Group) {
        foreach ($u in @("https://coverartarchive.org/release/$Release/front-500", "https://coverartarchive.org/release-group/$Group/front-500")) {
            if ($u -match '/$|//front') { continue }
            $file = Join-Path $CoverDir "$Release.jpg"
            try { Invoke-WebRequest -Uri $u -UserAgent $Agent -OutFile $file -UseBasicParsing -TimeoutSec 30; return $file }
            catch { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
        }
        return ''
    }
    # One version (pressing) of a CD, for the "Which version is yours?" window.
    function ConvertTo-Version($R) {
        $fmt = @($R.media | ForEach-Object { [string]$_.format } | Where-Object { $_ } | Group-Object | ForEach-Object { if ($_.Count -gt 1) { "$($_.Count) x $($_.Name)" } else { $_.Name } }) -join ' + '
        $tracks = [int]$R.'track-count'; if (-not $tracks) { $tracks = [int](@($R.media | ForEach-Object { [int]$_.'track-count' }) | Measure-Object -Sum).Sum }
        return @{ Id = [string]$R.id; Title = [string]$R.title; Date = [string]$R.date; Country = [string]$R.country
                  Artist = (@($R.'artist-credit' | ForEach-Object { [string]$_.name + [string]$_.joinphrase }) -join '').Trim()
                  Label = (@($R.'label-info' | ForEach-Object { [string]$_.label.name } | Where-Object { $_ }) | Select-Object -Unique) -join ', '
                  CatNo = (@($R.'label-info' | ForEach-Object { [string]$_.'catalog-number' } | Where-Object { $_ }) | Select-Object -Unique) -join ', '
                  Format = $fmt; Tracks = $tracks; Status = [string]$R.status; Packaging = [string]$R.packaging; Note = [string]$R.disambiguation }
    }
    try {
        while (-not $Sync.Cancel) {
            $j = $null
            if (-not $Sync.Queue.TryDequeue([ref]$j)) { if ($Sync.StopWhenEmpty) { break }; Start-Sleep -Milliseconds 250; continue }
            $Sync.Now = if ($j.Barcode) { "barcode $($j.Barcode)" } else { "$($j.Artist) - $($j.Album)" }
            $res = @{ Job = $j; Found = $false; Failed = $false; Matches = 0 }
            try {
                if ($j.Barcode -or $j.ReleaseId) {
                    if ($j.ReleaseId) {
                        # The version you picked.
                        $rel = Get-Mb ("https://musicbrainz.org/ws/2/release/$($j.ReleaseId)?inc=artist-credits+labels+media+release-groups&fmt=json")
                        $res.Matches = 1
                    } else {
                        $r = Get-Mb ('https://musicbrainz.org/ws/2/release/?fmt=json&limit=25&query=barcode:' + [Uri]::EscapeDataString($j.Barcode))
                        $all = @($r.releases | Where-Object { [int]$_.score -ge 90 })
                        $res.Matches = $all.Count
                        # Several versions (pressings) can share a barcode: start with a CD one, and offer the others.
                        $cds = @($all | Where-Object { @($_.media | Where-Object { $_.format -match 'CD' }).Count })
                        $rel = @($cds + $all) | Select-Object -First 1
                        if ($all.Count -gt 1 -or $j.ListOnly) { $res.Versions = @(@($cds + @($all | Where-Object { $cds -notcontains $_ })) | ForEach-Object { ConvertTo-Version $_ }) }
                        if ($j.ListOnly) { $res.Found = [bool]$all.Count; $rel = $null }
                    }
                    if ($rel) {
                        $res.Found = $true
                        $res.Mbid = [string]$rel.id
                        $res.Album = [string]$rel.title
                        $res.Artist = (@($rel.'artist-credit' | ForEach-Object { [string]$_.name + [string]$_.joinphrase }) -join '').Trim()
                        if ([string]$rel.date -match '^(\d{4})') { $res.Year = $Matches[1] }
                        elseif ($rel.'release-group'.id) {
                            # This pressing has no date: take the album's first release.
                            Start-Sleep -Milliseconds 1600
                            try { $g = Get-Mb ("https://musicbrainz.org/ws/2/release-group/$($rel.'release-group'.id)?fmt=json"); if ([string]$g.'first-release-date' -match '^(\d{4})') { $res.Year = $Matches[1] } } catch { Write-Verbose 'no group date' }
                        }
                        $res.Country = [string]$rel.country
                        $res.Label = (@($rel.'label-info' | ForEach-Object { [string]$_.label.name } | Where-Object { $_ }) | Select-Object -Unique) -join ', '
                        $res.Tracks = [int]$rel.'track-count'
                        if (-not $res.Tracks) { $res.Tracks = [int](@($rel.media | ForEach-Object { [int]$_.'track-count' }) | Measure-Object -Sum).Sum }
                        $res.Discs = @($rel.media).Count
                        $res.Cover = Get-Cover $res.Mbid ([string]$rel.'release-group'.id)
                    }
                } else {
                    $q = 'release:"' + ($j.Album -replace '"', '') + '"' + $(if ($j.Artist) { ' AND artist:"' + ($j.Artist -replace '"', '') + '"' } else { '' }) + ' AND format:CD'
                    $r = Get-Mb ('https://musicbrainz.org/ws/2/release/?fmt=json&limit=1&query=' + [Uri]::EscapeDataString($q))
                    $rel = @($r.releases) | Where-Object { [int]$_.score -ge 90 } | Select-Object -First 1
                    if ($rel) {
                        $res.Found = $true
                        $res.Mbid = [string]$rel.id
                        if ([string]$rel.date -match '^(\d{4})') { $res.Year = $Matches[1] }
                        $res.Label = (@($rel.'label-info' | ForEach-Object { [string]$_.label.name } | Where-Object { $_ }) | Select-Object -Unique) -join ', '
                        $res.Tracks = [int]$rel.'track-count'
                        if ($j.NeedCover) { $res.Cover = Get-Cover $res.Mbid ([string]$rel.'release-group'.id) }
                    }
                }
            } catch { $res.Failed = $true; $res.Error = $_.Exception.Message }
            [void]$Sync.Items.Add($res)
            $Sync.Done++
            Start-Sleep -Milliseconds 1600
        }
    } finally { $Sync.Finished = $true }
}
# "More about this CD": one look-up in the background for the CD's track listing and release
# details (MusicBrainz), the album and the artist (MusicBrainz, then Wikipedia through Wikidata).
# Kept in the Info folder so it opens at once next time, and works offline.
$script:InfoScan = {
    param($Sync, [string]$Mbid, [string]$ArtistName, [string]$Agent, [string]$Lang)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    function Get-Json([string]$Url) {
        for ($try = 1; ; $try++) {
            try { return Invoke-RestMethod -Uri $Url -UserAgent $Agent -TimeoutSec 20 }
            catch { if ($try -ge 5 -or "$($_.Exception.Message)" -notmatch '503') { throw }; Start-Sleep -Seconds (3 * $try) }
        }
    }
    function Get-Mb([string]$Path) { Start-Sleep -Milliseconds 1100; return Get-Json ("https://musicbrainz.org/ws/2/$Path" + $(if ($Path -match '\?') { '&' } else { '?' }) + 'fmt=json') }
    function Get-Link($Rels, [string]$Type) { return [string](@($Rels | Where-Object { $_.type -eq $Type -and $_.url.resource }) | Select-Object -First 1).url.resource }
    function Get-Genres($Obj) { return @(@($Obj.genres) | Where-Object { $_.name } | Sort-Object { [int]$_.count } -Descending | Select-Object -First 5 | ForEach-Object { [string]$_.name }) }
    function Get-Wiki($Rels) {
        # The Wikipedia introduction, in the language Windows uses when there is a page in it, else English.
        try {
            $title = ''; $site = ''
            $wd = Get-Link $Rels 'wikidata'
            if ($wd -match '(Q\d+)$') {
                $q = $Matches[1]
                $e = Get-Json "https://www.wikidata.org/wiki/Special:EntityData/$q.json"
                foreach ($l in @($Lang, 'en') | Select-Object -Unique) {
                    $sl = $e.entities.$q.sitelinks."${l}wiki"
                    if ($sl.title) { $title = [string]$sl.title; $site = $l; break }
                }
            }
            if (-not $title) {
                $wp = Get-Link $Rels 'wikipedia'
                if ($wp -match '^https?://(\w+)\.wikipedia\.org/wiki/(.+)$') { $site = $Matches[1]; $title = [Uri]::UnescapeDataString($Matches[2]) }
            }
            if (-not $title) { return $null }
            $s = Get-Json ("https://$site.wikipedia.org/api/rest_v1/page/summary/" + [Uri]::EscapeDataString($title.Replace(' ', '_')))
            if (-not $s.extract) { return $null }
            # The summary drops pronunciations and the like, leaving gaps such as "Yorke ;": close them up.
            $text = ([string]$s.extract -replace '\(\s*[;,]?\s*\)', '' -replace '\s+([;,.])', '$1' -replace '\s{2,}', ' ').Trim()
            return @{ Text = $text; Url = [string]$s.content_urls.desktop.page }
        } catch { return $null }
    }
    try {
        $res = @{ Cd = $null; Artist = $null; Fetched = (Get-Date).ToString('s') }
        $artistId = ''
        if ($Mbid -and $Mbid -ne '-') {
            $Sync.Now = 'Getting the track listing from MusicBrainz...'
            $r = Get-Mb "release/$($Mbid)?inc=artist-credits+recordings+labels+release-groups+url-rels"
            $rg = $r.'release-group'
            $artistId = [string](@($r.'artist-credit')[0].artist.id)
            $cd = @{ Title = [string]$r.title; Date = [string]$r.date; Country = [string]$r.country; Status = [string]$r.status; Packaging = [string]$r.packaging
                     Barcode = [string]$r.barcode; Disambiguation = [string]$r.disambiguation; Url = "https://musicbrainz.org/release/$Mbid"
                     Artist = (@($r.'artist-credit' | ForEach-Object { [string]$_.name + [string]$_.joinphrase }) -join '').Trim()
                     Labels = @(@($r.'label-info') | Where-Object { $_.label.name } | ForEach-Object { ([string]$_.label.name + $(if ($_.'catalog-number') { " ($($_.'catalog-number'))" })) } | Select-Object -Unique)
                     Discs = @(); Type = ''; First = ''; Genres = @(); Wiki = $null; Discogs = '' }
            $media = @($r.media)
            $fmt = @($media | ForEach-Object { [string]$_.format } | Where-Object { $_ })
            $cd.Format = (@($fmt | Group-Object | ForEach-Object { if ($_.Count -gt 1) { "$($_.Count) x $($_.Name)" } else { $_.Name } })) -join ' + '
            foreach ($m in $media) {
                $tracks = @(@($m.tracks) | ForEach-Object {
                    $ms = [int64]$_.length
                    @{ No = [string]$_.number; Title = [string]$_.title; Length = $(if ($ms -gt 0) { '{0}:{1:00}' -f [math]::Floor($ms / 60000), [math]::Floor(($ms % 60000) / 1000) } else { '' })
                       Artist = (@($_.'artist-credit' | ForEach-Object { [string]$_.name + [string]$_.joinphrase }) -join '').Trim() }
                })
                $cd.Discs += , @{ Name = $(if ($media.Count -gt 1) { "Disc $($m.position)$(if ($m.title) { ": $($m.title)" })" } else { [string]$m.title }); Tracks = $tracks }
            }
            $cd.Discogs = Get-Link $r.relations 'discogs'
            if ($rg.id) {
                $Sync.Now = 'Getting the album from MusicBrainz...'
                $g = Get-Mb "release-group/$($rg.id)?inc=url-rels+genres"
                $cd.First = [string]$g.'first-release-date'
                $cd.Type = (@([string]$g.'primary-type') + @($g.'secondary-types') | Where-Object { $_ }) -join ', '
                $cd.Genres = Get-Genres $g
                if (-not $cd.Discogs) { $cd.Discogs = Get-Link $g.relations 'discogs' }
                $Sync.Now = 'Getting the album from Wikipedia...'
                $cd.Wiki = Get-Wiki $g.relations
            }
            $res.Cd = $cd
        }
        if (-not $artistId -and $ArtistName) {
            $Sync.Now = 'Finding the artist in MusicBrainz...'
            $a = Get-Mb ('artist/?limit=1&query=' + [Uri]::EscapeDataString('artist:"' + ($ArtistName -replace '"', '') + '"'))
            $artistId = [string](@($a.artists | Where-Object { [int]$_.score -ge 95 }) | Select-Object -First 1).id
        }
        if ($artistId -and $artistId -ne '89ad4ac3-39f7-470e-963a-56509c546377') {   # not "Various Artists"
            $Sync.Now = 'Getting the artist from MusicBrainz...'
            $a = Get-Mb "artist/$($artistId)?inc=url-rels+artist-rels+genres"
            $span = $a.'life-span'
            $art = @{ Name = [string]$a.name; Type = [string]$a.type; Disambiguation = [string]$a.disambiguation; Country = [string]$a.area.name; From = [string]$a.'begin-area'.name
                      Begin = [string]$span.begin; End = [string]$span.end; Ended = [bool]$span.ended; Genres = (Get-Genres $a)
                      Url = "https://musicbrainz.org/artist/$artistId"; Home = (Get-Link $a.relations 'official homepage'); Discogs = (Get-Link $a.relations 'discogs')
                      Members = @(); MemberOf = @(); Wiki = $null }
            $year = { param($d) if ([string]$d -match '^(\d{4})') { $Matches[1] } else { '' } }
            # One line per person (or band), with each spell: "Christine McVie (1970-1995, 1997-2022)".
            foreach ($dir in 'backward', 'forward') {
                $names = [ordered]@{}
                foreach ($rel in @($a.relations | Where-Object { $_.type -eq 'member of band' -and $_.direction -eq $dir -and $_.artist.name })) {
                    $b = & $year $rel.begin; $e = if ($rel.ended) { & $year $rel.end } else { 'now' }
                    $spell = if (-not $b -and $e -eq 'now') { '' } elseif ($b -eq $e) { $b } else { "$b-$e" }
                    $n = [string]$rel.artist.name
                    if (-not $names.Contains($n)) { $names[$n] = @() }
                    if ($spell -and $spell -ne '-') { $names[$n] += $spell }
                }
                $lines = @($names.Keys | ForEach-Object { $_ + $(if ($names[$_].Count) { " ($((@($names[$_] | Select-Object -Unique)) -join ', '))" }) })
                if ($dir -eq 'backward') { $art.Members = $lines } else { $art.MemberOf = $lines }
            }
            $Sync.Now = 'Getting the artist from Wikipedia...'
            $art.Wiki = Get-Wiki $a.relations
            $res.Artist = $art
        }
        $Sync.Result = $res
    } catch { $Sync.Error = $_.Exception.Message }
    finally { $Sync.Finished = $true }
}
#endregion CATALOGUE

# ---------------------------------------------------------------------------
#  Help
# ---------------------------------------------------------------------------
$script:HelpText = @'
WHAT IT DOES
CD Catalogue keeps a searchable list of your CDs: artist, album, year, label, number of tracks and discs, the barcode, the cover and your own notes.

ADDING CDS BY BARCODE
Click in the barcode box at the top and scan the barcode on the back of the CD with a USB or Bluetooth barcode scanner (it types the number and presses Enter for you), or type the number under the bars and press Enter. The details come from MusicBrainz and the cover from the Cover Art Archive (both free, no account). You can scan one CD after another: each is looked up in turn, about one a second. A CD already in the list is pointed out instead of being added twice. A barcode MusicBrainz doesn't know is still added, as "(not found)", so you can fill it in with Edit.

WHICH VERSION IS YOURS?
MusicBrainz often has several versions of a CD with the same barcode: other countries, reissues, different labels or box sets. When a barcode has more than one, the CD is added with the most likely one and, once the look-ups have finished, the app asks which is yours: each version shows its cover, date, country, label, catalogue number, format and tracks (See on MusicBrainz opens its page there, with its track list and photos of the sleeve). Pick yours, or Keep the current one. Choose the version, under a CD's details, shows them again at any time.

SCANNING SEVERAL CDS FIRST
Scan several lets you scan a pile of CDs before anything is looked up. Press Scan several, scan the first CD, then the next, and so on: each barcode goes on a waiting list (the status line shows them, and the Search button how many). When you've scanned them all, press Search (or press Enter in the empty barcode box, or type search). They're then looked up one after another, about one a second, and each appears in the list as it's found. A CD already in your catalogue, or already on the list, is pointed out as you scan it. Cancel (or Esc) leaves Scan several and forgets the list.

CDS WITHOUT A BARCODE
Add by hand adds one by hand. Look up in the edit box (or Look up online for all of them) finds the year, label, tracks and cover by artist and album.

THE LIST
Covers shows your CDs as a wall of covers, List as a list, and Artists by artist; the app remembers which. In List, click a column heading to sort (Covers follows the same order). Click a CD to see its cover and details in the panel at the bottom right; Edit changes it (or double-click the CD), Remove takes it off the list, and MusicBrainz opens its page there. Export CSV saves the list (or just the CDs your search found) as a CSV file for Excel and other spreadsheets, as listed, by artist or by place. HTML report saves it as a page with the covers, to open in any browser, print or share: as listed, by artist (a heading for each artist, their CDs oldest first) or by place (a heading for each place where CDs are kept: print it and keep it with them); hover over a cover there to see it bigger, or over an album for its details (with the tracks, once More about the CD and artist has been opened for it).


THE KEY: MB AND HAND
Every CD has a mark on its cover (and in List's From column): MB when its details came from MusicBrainz (scanned, or found with Look up), Hand when they were entered by hand (added by hand, or a barcode MusicBrainz didn't know, filled in with Edit). The key at the top right shows how many of each; click one to show only those CDs, and click it again to show them all. You can also search source:mb or source:hand. A hand-entered CD becomes MB once Look up (or Look up online) finds it.
ARTISTS
Artists lists every artist on the left, with how many CDs you have and the years they span. It opens on All artists (every CD, in artist order and then by year); pick an artist to see them like a discography: all their CDs together, oldest first, with their genres and labels. The search box works here too. Names count as the same artist whatever their capitals, "The" is skipped when they're put in order, and CDs with no artist are listed last. Click a cover to see its details; double-click it to edit it.

SEARCHING
Type in the search box to find CDs; the search runs a moment after you stop typing. It looks through everything: artist, album, label, genre, barcode, notes, and the year when you type one. The button at its right (All) picks one thing to search instead: Artist, Album, Year, Label, Genre, Barcode or Notes.
You can also type what to search in the box, and mix them: artist:harbours  year:1997  label:attic  genre:folk  barcode:5000  notes:signed  kept:loft  source:hand. Put a name with spaces in quotes, such as label:"little wheel". Everything you type has to match, so artist:harbours year:1990-1999 finds that artist's CDs from the 1990s.
A year can be one year (1997), a range (1990-1999, or 1990 to 1999) or a decade (1990s). The status line says how many CDs match.
To find which CD has a song, pick Track on the button (or type track:harbour lights). Track lists come from MusicBrainz in the background, about one CD a second, for the CDs found there; Everything searches them too.


WHERE IT'S KEPT
Kept, in the edit window, is where the CD lives: pick one of your places (or Not set). Places... changes the list, such as In Front Room; In Loft. It shows in the CD's details and in List, the search finds it (or type kept:loft), and it's in the CSV, the report and Stats.


PICK FOR ME
Can't decide what to play? Pick for me (in the side bar) picks a CD at random and shows it. It picks from the CDs shown, so search first to pick from one place (kept:loft), genre or decade. Press it again for another.

WHAT'S MISSING?
In Artists, pick an artist and press What's missing? to see their studio albums on MusicBrainz (no singles, live albums or compilations), oldest first, with the ones you have marked and See on MusicBrainz for each. It needs at least one of their CDs to have come from MusicBrainz, and takes a second or two for each of their CDs.
STATS
Stats shows your collection in numbers: how many CDs, artists, discs and tracks, the years they span, how many came from MusicBrainz, and bars for each decade, the artists you have most of, the top labels and genres, and where they're kept.

BACKUP AND RESTORE
Backup saves your whole catalogue (the CDs, your notes, covers, disc photos and what More about found) in one .zip file: keep it on another drive or in the cloud. Restore puts a backup back on this PC or another one, replacing the CDs there; the catalogue as it was is saved first in the Backups folder in the data folder, so a restore can be undone. Settings and the MusicBrainz sign-in aren't in a backup.
CSV FILES AND EXCEL
The CSV opens correctly in Excel with a double-click: barcodes keep every digit, and titles such as 007 or 3/4 stay as typed. To do that such values are written as ="007" in the file, which is what you'll see in a plain text editor, or in a program other than a spreadsheet that reads the CSV.

THE DISC
The disc beside the cover shows the CD's own label when the Cover Art Archive has a photo of it (people add these to MusicBrainz, so popular CDs often have one and others don't). They're found in the background, a CD at a time, for each CD from MusicBrainz; when its own version has none, the other versions with the same barcode are tried, as they usually share the disc print. A CD with no photo is looked at again a week later, in case someone has added one. Photos are kept in the Covers folder. With no photo, it shows a blank CD.

MORE ABOUT THE CD AND ARTIST
More about the CD and artist shows the cover and the disc (its label, or a blank CD), and side by side:
- the CD: its track listing with times, when the album first came out, this pressing's date, country, label and catalogue number, the format and packaging, genres, and the album's Wikipedia introduction;
- the artist: where they're from, when they formed or were born (and split up or died), genres, the band's members (or the bands a person was in), and the artist's Wikipedia introduction.
The links open the pages on MusicBrainz, Wikipedia, Discogs and the artist's own site. It's kept, so it opens at once next time (Look up again gets the latest). A CD with no genre gets one from MusicBrainz. Wikipedia is in the language Windows uses when there's a page in it, else English.

MUSICBRAINZ ACCOUNT (OPTIONAL)
Looking CDs up never needs an account. If you have a MusicBrainz account, two more things are possible:
- Add to MusicBrainz: a CD whose barcode MusicBrainz doesn't know shows Add to MusicBrainz instead of MusicBrainz. It opens MusicBrainz's Add release page with the barcode (and any artist, album, label and year you typed in) filled in. Sign in there, add the tracks and enter the edit. Once MusicBrainz has it, Edit and Look up here fill in the rest and the cover, and anyone else who scans that CD will find it.
- MB collection: sends your CDs to a collection in your account, so the CDs you own are listed on musicbrainz.org. The first time, register an application in your MusicBrainz account (type Installed application), paste its client ID and secret, press Sign in, allow it in the browser and paste the code it shows. The sign-in is kept for next time, encrypted for your Windows account; your MusicBrainz password is never seen or kept by the app. Pick a collection (make one on MusicBrainz first if you have none) and press Send my CDs. Sending again is safe: CDs already there stay as they are. Sign out forgets it all on this PC.

WINDOW SIZE
The window opens big, filling most of the screen, so you see as many covers as will fit. Make it bigger or smaller (or maximise it) and it opens that way next time.

LOOK
The Look button switches between Light, Dark and Auto (the same as Windows), from the next start.

WHERE YOUR CATALOGUE IS KEPT
In %APPDATA%\CD Catalogue: catalogue.json (your CDs), settings.json, the Covers and Info folders, and a log. Nothing is kept in the program's own folder, so a new version finds your CDs as they are.
'@

# ---------------------------------------------------------------------------
#  MusicBrainz account: add a missing CD, and send your CDs to a collection
# ---------------------------------------------------------------------------
function Open-MbAddRelease([CdItem]$Item) {
    <# MusicBrainz's release editor takes its first values from a form posted to /release/add, so a small
       page with that form is saved to the temp folder and opened: it sends itself on to MusicBrainz. #>
    $go = Show-AppMessage ("This opens MusicBrainz's Add release page in your browser, with the barcode$(if ($Item.Album) { ', artist and album' }) filled in. " +
        "Sign in there with your MusicBrainz account, check the details, add the tracks and press Enter edit.`n`n" +
        "Once MusicBrainz has it (that can take a little while), Edit and Look up here fill in the rest and the cover.") -YesText 'Open MusicBrainz' -NoText 'Cancel'
    if (-not $go) { return }
    $fields = [ordered]@{ barcode = $Item.Barcode; 'mediums.0.format' = 'CD'; status = 'official'
                          edit_note = "Added from a CD in hand (barcode scanned with CD Catalogue: $script:RepoUrl)." }
    if ($Item.Album)  { $fields.name = $Item.Album }
    if ($Item.Artist) { $fields['artist_credit.names.0.name'] = $Item.Artist; $fields['artist_credit.names.0.artist.name'] = $Item.Artist }
    if ($Item.Label)  { $fields['labels.0.name'] = $Item.Label }
    if ($Item.Year -match '^\d{4}$') { $fields['events.0.date.year'] = $Item.Year }
    if ($Item.Discs -gt 1) { for ($d = 1; $d -lt $Item.Discs; $d++) { $fields["mediums.$d.format"] = 'CD' } }
    $inputs = ($fields.Keys | ForEach-Object { '<input type="hidden" name="{0}" value="{1}">' -f [Net.WebUtility]::HtmlEncode($_), [Net.WebUtility]::HtmlEncode([string]$fields[$_]) }) -join "`n"
    $html = @"
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Opening MusicBrainz</title></head>
<body onload="document.forms[0].submit()" style="font-family:sans-serif">
<p>Opening MusicBrainz's Add release page...</p>
<form method="post" action="https://musicbrainz.org/release/add">
$inputs
<noscript><button type="submit">Open MusicBrainz</button></noscript>
</form></body></html>
"@
    $file = Join-Path $env:TEMP 'CD Catalogue - add to MusicBrainz.html'
    [IO.File]::WriteAllText($file, $html, (New-Object Text.UTF8Encoding $false))
    Start-Process $file
    Set-Status "Opened MusicBrainz's Add release page for $($Item.Barcode)."
}

# Sign-in uses MusicBrainz's OAuth for installed applications: you register the app once in your
# MusicBrainz account and paste its client ID and secret here. Secrets and tokens are kept in
# settings.json encrypted for your Windows account (DPAPI); your MusicBrainz password never is.
Add-Type -AssemblyName System.Security
$script:MbAuth = 'https://musicbrainz.org/oauth2'
$script:MbOob = 'urn:ietf:wg:oauth:2.0:oob'
function Protect-Text([string]$Text) {
    if (-not $Text) { return '' }
    return [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Text), $null, 'CurrentUser'))
}
function Unprotect-Text([string]$Text) {
    if (-not $Text) { return '' }
    try { return [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Text), $null, 'CurrentUser')) }
    catch { Write-AppLog "A saved MusicBrainz sign-in couldn't be read: $($_.Exception.Message)"; return '' }
}

function Save-MbToken($Res) {
    $s = $script:Settings
    $s.MbAccess = Protect-Text ([string]$Res.access_token)
    if ($Res.refresh_token) { $s.MbRefresh = Protect-Text ([string]$Res.refresh_token) }
    $s.MbExpires = (Get-Date).AddSeconds([int]$Res.expires_in - 60).ToString('o')
    Save-AppSetting
}

function Get-MbToken {
    <# A current access token, refreshed when it has run out, or '' when not signed in. #>
    $s = $script:Settings
    $access = Unprotect-Text $s.MbAccess
    $until = [datetime]::MinValue; [void][datetime]::TryParse([string]$s.MbExpires, [ref]$until)
    if ($access -and $until -gt (Get-Date)) { return $access }
    $refresh = Unprotect-Text $s.MbRefresh
    if (-not $refresh) { return '' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $res = Invoke-RestMethod -Method Post -Uri "$script:MbAuth/token" -UserAgent $script:Agent -TimeoutSec 20 -Body @{
        grant_type = 'refresh_token'; refresh_token = $refresh; client_id = $s.MbClientId; client_secret = (Unprotect-Text $s.MbClientSecret) }
    Save-MbToken $res
    return [string]$res.access_token
}

function Invoke-MbAccount([string]$Uri, [string]$Method = 'Get') {
    $tok = Get-MbToken
    if (-not $tok) { throw 'Not signed in to MusicBrainz.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $h = @{ Authorization = "Bearer $tok" }
    if ($Method -eq 'Get') { return Invoke-RestMethod -Uri $Uri -Headers $h -UserAgent $script:Agent -TimeoutSec 20 }
    return Invoke-WebRequest -Method $Method -Uri $Uri -Headers $h -UserAgent $script:Agent -TimeoutSec 30 -UseBasicParsing
}

function Show-Collection {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="600" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Bahnschrift, Segoe UI" FontSize="13.5" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <StackPanel Margin="22,8,22,18">
    <TextBlock TextWrapping="Wrap" LineHeight="20" Text="Send your CDs to a collection in your MusicBrainz account, so the CDs you own are listed on musicbrainz.org too. CDs MusicBrainz knows are sent; ones added by hand need Look up online first."/>

    <StackPanel x:Name="CSetup" Margin="0,16,0,0">
      <TextBlock FontWeight="SemiBold" Text="Connect your MusicBrainz account (once)"/>
      <TextBlock TextWrapping="Wrap" LineHeight="20" Margin="0,6,0,0">
        <Run Text="1. On MusicBrainz, sign in and "/><Hyperlink x:Name="CRegister" NavigateUri="https://musicbrainz.org/account/applications/register" Foreground="{Accent}">register an application</Hyperlink><Run Text=": any name (such as CD Catalogue), type Installed application. Then paste its OAuth client ID and secret here."/>
      </TextBlock>
      <Grid Margin="0,8,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Text="Client ID" VerticalAlignment="Center"/><TextBox x:Name="CId" Grid.Column="1" Margin="0,3"/>
        <TextBlock Grid.Row="1" Text="Client secret" VerticalAlignment="Center"/><TextBox x:Name="CSecret" Grid.Row="1" Grid.Column="1" Margin="0,3"/>
      </Grid>
      <TextBlock TextWrapping="Wrap" LineHeight="20" Margin="0,10,0,0" Text="2. Press Sign in. MusicBrainz asks in your browser whether CD Catalogue may use your collections, then shows a code: paste it below and press Finish."/>
      <DockPanel Margin="0,8,0,0">
        <Button x:Name="CSignIn" Content="Sign in" DockPanel.Dock="Left"/>
        <Button x:Name="CFinish" Content="Finish" Style="{StaticResource Accent}" DockPanel.Dock="Right" Margin="8,0,0,0" MinWidth="80"/>
        <TextBox x:Name="CCode" ToolTip="The code MusicBrainz shows after you allow it"/>
      </DockPanel>
    </StackPanel>

    <StackPanel x:Name="CReady" Margin="0,16,0,0" Visibility="Collapsed">
      <DockPanel>
        <Button x:Name="CSignOut" Content="Sign out" DockPanel.Dock="Right" Margin="0" ToolTip="Forget the sign-in (and the client ID and secret) on this PC"/>
        <TextBlock x:Name="CUser" FontWeight="SemiBold" VerticalAlignment="Center"/>
      </DockPanel>
      <TextBlock Text="Your release collections: pick one" Foreground="{Soft}" Margin="0,12,0,4"/>
      <WrapPanel x:Name="CList"/>
      <TextBlock x:Name="CNone" TextWrapping="Wrap" Foreground="{Soft}" Visibility="Collapsed" Margin="0,4,0,0">
        <Run Text="You have no release collections yet."/>
        <Hyperlink x:Name="CMake" NavigateUri="https://musicbrainz.org/collection/create" Foreground="{Accent}">Make one on MusicBrainz</Hyperlink><Run Text=" (type Release), then press Refresh."/>
      </TextBlock>
    </StackPanel>

    <TextBlock x:Name="CNote" TextWrapping="Wrap" Foreground="{Soft}" Margin="0,14,0,0"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="CRefresh" Content="Refresh" Visibility="Collapsed"/>
      <Button x:Name="CSend" Content="Send my CDs" Style="{StaticResource Accent}" Visibility="Collapsed" IsEnabled="False"/>
      <Button x:Name="CClose" Content="Close" MinWidth="80" Margin="0" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    $w.Title = 'MusicBrainz collection'
    $c = @{}
    foreach ($n in 'CSetup', 'CReady', 'CId', 'CSecret', 'CSignIn', 'CCode', 'CFinish', 'CSignOut', 'CUser', 'CList', 'CNone', 'CNote', 'CRefresh', 'CSend', 'CClose', 'CRegister', 'CMake') { $c[$n] = $w.FindName($n) }
    $s = $script:Settings
    $render = { $w.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render) }
    foreach ($l in 'CRegister', 'CMake') { $c[$l].Add_RequestNavigate({ param($o, $e) Start-Process $e.Uri.AbsoluteUri; $e.Handled = $true }) }
    $c.CId.Text = [string]$s.MbClientId
    $c.CSecret.Text = Unprotect-Text $s.MbClientSecret

    $pick = {
        param([string]$Id)
        foreach ($b in $c.CList.Children) { $b.Style = if ($b.Tag -eq $Id) { $w.FindResource('Accent') } else { $null } }
    }
    $loadLists = {
        $c.CList.Children.Clear(); $c.CNone.Visibility = 'Collapsed'; $c.CSend.IsEnabled = $false
        $c.CNote.Text = 'Getting your collections...'; & $render
        try {
            $res = Invoke-MbAccount "https://musicbrainz.org/ws/2/collection?editor=$([uri]::EscapeDataString([string]$s.MbUser))&limit=100&fmt=json"
            $lists = @($res.collections | Where-Object { $_.'entity-type' -eq 'release' })
        } catch { $c.CNote.Text = "Couldn't get your collections: $($_.Exception.Message)"; Write-AppLog "Collections: $($_.Exception.Message)"; return }
        foreach ($l in $lists) {
            $b = New-Object Windows.Controls.Button
            $b.Content = "$($l.name)  ($($l.'release-count'))"; $b.Tag = [string]$l.id; $b.Margin = '0,0,8,8'
            $b.Add_Click({ $s.MbCollection = [string]$this.Tag; $s.MbCollectionName = [string]$this.Content; Save-AppSetting; & $pick $this.Tag; $c.CSend.IsEnabled = $true })
            [void]$c.CList.Children.Add($b)
        }
        if (-not $lists.Count) { $c.CNone.Visibility = 'Visible' }
        if ($s.MbCollection -and @($lists | Where-Object { $_.id -eq $s.MbCollection }).Count) { & $pick $s.MbCollection; $c.CSend.IsEnabled = $true }
        elseif ($lists.Count -eq 1) { $s.MbCollection = [string]$lists[0].id; Save-AppSetting; & $pick $s.MbCollection; $c.CSend.IsEnabled = $true }
        $known = @($script:Items | Where-Object { $_.Mbid -and $_.Mbid -ne '-' }).Count
        $c.CNote.Text = "$known of your $($script:Items.Count) CDs are in MusicBrainz and can be sent. CDs already in the collection stay as they are."
    }
    $showState = {
        $signed = [bool](Unprotect-Text $s.MbRefresh) -and $s.MbUser
        $c.CSetup.Visibility = if ($signed) { 'Collapsed' } else { 'Visible' }
        foreach ($n in 'CReady', 'CRefresh', 'CSend') { $c[$n].Visibility = if ($signed) { 'Visible' } else { 'Collapsed' } }
        if ($signed) { $c.CUser.Text = "Signed in as $($s.MbUser)"; & $loadLists } else { $c.CNote.Text = '' }
    }

    $c.CSignIn.Add_Click({
        $id = $c.CId.Text.Trim(); $secret = $c.CSecret.Text.Trim()
        if (-not $id -or -not $secret) { $c.CNote.Text = 'Paste the client ID and secret from MusicBrainz first.'; return }
        $s.MbClientId = $id; $s.MbClientSecret = Protect-Text $secret; Save-AppSetting
        Start-Process ("$script:MbAuth/authorize?response_type=code&client_id=$([uri]::EscapeDataString($id))&redirect_uri=$([uri]::EscapeDataString($script:MbOob))" +
                       '&scope=profile%20collection&access_type=offline')
        $c.CNote.Text = 'Allow it in your browser, then paste the code MusicBrainz shows into the box and press Finish.'
        $c.CCode.Focus() | Out-Null
    })
    $c.CFinish.Add_Click({
        $code = $c.CCode.Text.Trim()
        if (-not $code) { $c.CNote.Text = 'Paste the code MusicBrainz showed, then press Finish.'; return }
        $c.CNote.Text = 'Signing in...'; & $render
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $res = Invoke-RestMethod -Method Post -Uri "$script:MbAuth/token" -UserAgent $script:Agent -TimeoutSec 20 -Body @{
                grant_type = 'authorization_code'; code = $code; redirect_uri = $script:MbOob; client_id = $s.MbClientId; client_secret = (Unprotect-Text $s.MbClientSecret) }
            Save-MbToken $res
            $me = Invoke-MbAccount "$script:MbAuth/userinfo"
            $s.MbUser = [string]$me.sub; Save-AppSetting
            Write-AppLog "Signed in to MusicBrainz as $($s.MbUser)"
            $c.CCode.Text = ''
            & $showState
        } catch {
            $c.CNote.Text = "Sign-in didn't work: $($_.Exception.Message). Check the client ID and secret, and use a fresh code (each one works once)."
            Write-AppLog "MusicBrainz sign-in: $($_.Exception.Message)"
        }
    })
    $c.CSignOut.Add_Click({
        if (-not (Show-AppMessage 'Forget the MusicBrainz sign-in on this PC? Your collection on MusicBrainz is not changed.' -YesText 'Sign out' -NoText 'Cancel' -Owner $w)) { return }
        foreach ($k in 'MbAccess', 'MbRefresh', 'MbExpires', 'MbUser', 'MbCollection', 'MbCollectionName', 'MbClientId', 'MbClientSecret') { $s.Remove($k) }
        Save-AppSetting
        $c.CId.Text = ''; $c.CSecret.Text = ''
        & $showState
    })
    $c.CRefresh.Add_Click({ & $loadLists })
    $c.CSend.Add_Click({
        $ids = @($script:Items | Where-Object { $_.Mbid -and $_.Mbid -ne '-' } | ForEach-Object { $_.Mbid } | Sort-Object -Unique)
        if (-not $ids.Count -or -not $s.MbCollection) { $c.CNote.Text = 'Pick a collection first (and look up your CDs, so MusicBrainz knows them).'; return }
        $c.CSend.IsEnabled = $false
        $sent = 0
        try {
            # MusicBrainz takes up to about 100 releases a time, and one request a second.
            for ($n = 0; $n -lt $ids.Count; $n += 100) {
                $chunk = $ids[$n..([math]::Min($n + 99, $ids.Count - 1))]
                $c.CNote.Text = "Sending $($n + 1) to $($n + $chunk.Count) of $($ids.Count)..."; & $render
                [void](Invoke-MbAccount "https://musicbrainz.org/ws/2/collection/$($s.MbCollection)/releases/$($chunk -join ';')?client=CD-Catalogue-$script:AppVersion" 'Put')
                $sent += $chunk.Count
                Start-Sleep -Milliseconds 1100
            }
            Write-AppLog "Sent $sent CDs to MusicBrainz collection $($s.MbCollection)"
            & $loadLists
            $c.CNote.Text = "Done: $sent CD$(if ($sent -ne 1) { 's' }) sent to your collection."
            Set-Status "Sent $sent CDs to your MusicBrainz collection." 'Good'
        } catch {
            $c.CNote.Text = "Sending stopped after ${sent}: $($_.Exception.Message)"
            Write-AppLog "Collection send: $($_.Exception.Message)"
        } finally { $c.CSend.IsEnabled = $true }
    })
    $c.CClose.Add_Click({ $w.Close() })
    $w.Add_ContentRendered({ & $showState })
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------------------
#  Which version is yours? MusicBrainz often has several releases (pressings,
#  countries, reissues, box sets) with the same barcode.
# ---------------------------------------------------------------------------
function Show-Versions([CdItem]$Item) {
    $script:Choosing = $true
    try {
        $vers = $script:Versions[$Item.Id]
        if (-not $vers) {
            if (-not $Item.Barcode) { return }
            Set-Status "Getting the versions of $($Item.Barcode) from MusicBrainz..."
            $script:Window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
            $sync = New-LookupSync; $sync.StopWhenEmpty = $true; $sync.Queue.Enqueue(@{ Barcode = $Item.Barcode; ListOnly = $true })
            & $script:LookupScan $sync $script:CoverDir $script:Agent
            $r = @($sync.Items)[0]
            if (-not $r -or $r.Failed) { Set-Status "Couldn't get the versions just now (MusicBrainz is busy). Try again in a moment." 'Warn'; return }
            $vers = @($r.Versions)
            if (-not $vers.Count) { Set-Status "MusicBrainz has no version with barcode $($Item.Barcode)." 'Warn'; return }
            $script:Versions[$Item.Id] = $vers
            Set-Status "MusicBrainz has $($vers.Count) version$(if ($vers.Count -ne 1) { 's' }) of $($Item.Barcode)."
        }
        $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="720" Height="600" MinWidth="520" MinHeight="360" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Bahnschrift, Segoe UI" FontSize="13.5" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <DockPanel Margin="22,8,22,18">
    <TextBlock x:Name="VIntro" DockPanel.Dock="Top" TextWrapping="Wrap" LineHeight="20" Margin="0,0,0,12"/>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,14,0,0">
      <TextBlock DockPanel.Dock="Left" Foreground="{Soft}" VerticalAlignment="Center" TextWrapping="Wrap" MaxWidth="440"
                 Text="Check the label, catalogue number and country printed on your CD's back or spine."/>
      <Button x:Name="VKeep" Content="Keep the current one" HorizontalAlignment="Right" Margin="0" IsCancel="True"/>
    </DockPanel>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="VList"/></ScrollViewer>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
        $w = New-XamlWindow $x $script:Window
        $w.Title = 'Which version is yours?'
        $w.FindName('VIntro').Text = "MusicBrainz has $($vers.Count) version$(if ($vers.Count -ne 1) { 's' }) with barcode $($Item.Barcode). Pick the one you have: its details and cover are used for $($Item.Artist) - $($Item.Title)."
        $list = $w.FindName('VList')
        $pickedRef = @{ Id = $null }
        foreach ($v in $vers) {
            $row = New-Object Windows.Controls.Grid
            $row.Margin = '0,0,0,8'
            foreach ($cw in 'Auto', '*', 'Auto') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = (New-Object Windows.GridLengthConverter).ConvertFromString($cw); $row.ColumnDefinitions.Add($cd) }
            $cur = $Item.Mbid -eq $v.Id
            $b = New-Object Windows.Controls.Button
            if ($cur) { $b.Style = $w.FindResource('Accent') }
            $b.HorizontalContentAlignment = 'Stretch'; $b.Padding = '10,8'; $b.Margin = '0'; $b.Tag = $v.Id
            $b.ToolTip = if ($cur) { 'The version you have now' } else { 'Use this version' }
            [Windows.Controls.Grid]::SetColumnSpan($b, 2)
            $inner = New-Object Windows.Controls.DockPanel
            $pic = New-Object Windows.Controls.Border
            $pic.Width = 72; $pic.Height = 72; $pic.CornerRadius = 8; $pic.Margin = '0,0,12,0'; $pic.Background = Get-Brush 'Sleeve'
            try {
                $img = New-Object Windows.Media.Imaging.BitmapImage
                $img.BeginInit(); $img.UriSource = [uri]"https://coverartarchive.org/release/$($v.Id)/front-250"; $img.DecodePixelWidth = 144; $img.EndInit()
                $ib = New-Object Windows.Media.ImageBrush $img; $ib.Stretch = 'UniformToFill'
                $pic.Background = $ib
            } catch { Write-Verbose 'no cover' }
            [Windows.Controls.DockPanel]::SetDock($pic, 'Left'); [void]$inner.Children.Add($pic)
            $txt = New-Object Windows.Controls.StackPanel
            $txt.VerticalAlignment = 'Center'
            $t1 = New-Object Windows.Controls.TextBlock
            $t1.Text = "$($v.Title)$(if ($v.Artist) { "  -  $($v.Artist)" })$(if ($cur) { '   (current)' })"; $t1.FontWeight = 'SemiBold'; $t1.TextTrimming = 'CharacterEllipsis'
            $t2 = New-Object Windows.Controls.TextBlock
            $t2.Text = (@($v.Date, $(if ($v.Country) { Get-CountryName $v.Country }), $v.Label, $(if ($v.CatNo) { "cat. $($v.CatNo)" })) | Where-Object { $_ }) -join '  ·  '
            $t2.TextWrapping = 'Wrap'; $t2.Margin = '0,3,0,0'
            $t3 = New-Object Windows.Controls.TextBlock
            $t3.Text = (@($v.Format, $(if ($v.Tracks) { "$($v.Tracks) tracks" }), $v.Packaging, $(if ($v.Status -and $v.Status -ne 'Official') { $v.Status }), $v.Note) | Where-Object { $_ }) -join '  ·  '
            $t3.TextWrapping = 'Wrap'; $t3.Margin = '0,2,0,0'; $t3.Opacity = 0.75
            foreach ($tb in $t1, $t2, $t3) { [void]$txt.Children.Add($tb) }
            [void]$inner.Children.Add($txt)
            $b.Content = $inner
            $b.Add_Click({ $pickedRef.Id = [string]$this.Tag; [Windows.Window]::GetWindow($this).Close() })
            [void]$row.Children.Add($b)
            $page = New-Object Windows.Controls.Button
            $page.Content = 'See on MusicBrainz'; $page.Tag = $v.Id; $page.Margin = '8,0,0,0'; $page.Padding = '12,7'; $page.VerticalAlignment = 'Center'
            $page.ToolTip = 'See this version on musicbrainz.org (track list, photos of the sleeve)'
            [Windows.Controls.Grid]::SetColumn($page, 2)
            $page.Add_Click({ Start-Process "https://musicbrainz.org/release/$($this.Tag)" })
            [void]$row.Children.Add($page)
            [void]$list.Children.Add($row)
        }
        $w.FindName('VKeep').Add_Click({ $w.Close() })
        [void]$w.ShowDialog()
        if ($pickedRef.Id -and $pickedRef.Id -ne $Item.Mbid) {
            Send-Lookup @{ Id = $Item.Id; ReleaseId = $pickedRef.Id }
            Set-Status "Getting the version you picked for $($Item.Artist) - $($Item.Title)..."
        }
    } finally { $script:Choosing = $false }
}

function Show-Help {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="620" Height="560" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Bahnschrift, Segoe UI" FontSize="13.5" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <DockPanel Margin="22,8,22,18">
    <Button x:Name="HelpClose" DockPanel.Dock="Bottom" Content="Close" HorizontalAlignment="Right" MinWidth="80" Margin="0,14,0,0" IsCancel="True" IsDefault="True"/>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><TextBlock x:Name="HelpText" TextWrapping="Wrap" LineHeight="20"/></ScrollViewer>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    $w.Title = "$script:AppName Help"
    $w.FindName('HelpText').Text = $script:HelpText
    $w.FindName('HelpClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------------------
#  Add / edit one CD
# ---------------------------------------------------------------------------
function Edit-Cd([CdItem]$Item) {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="680" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Bahnschrift, Segoe UI" FontSize="13.5" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <DockPanel Margin="22,8,22,18">
    <DockPanel DockPanel.Dock="Bottom" Margin="0,16,0,0">
      <Button x:Name="ELook" Content="Look up" DockPanel.Dock="Left" ToolTip="Fill in the details and cover from MusicBrainz (by barcode, else by artist and album)"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="EOk" Content="Save" Style="{StaticResource Accent}" MinWidth="90" IsDefault="True"/>
        <Button x:Name="ECancel" Content="Cancel" MinWidth="80" Margin="0" IsCancel="True"/>
      </StackPanel>
    </DockPanel>
    <TextBlock x:Name="ENote" DockPanel.Dock="Bottom" Foreground="{Soft}" TextWrapping="Wrap" Margin="0,10,0,0"/>
    <Border DockPanel.Dock="Right" Width="170" Height="170" Margin="18,0,0,0" Background="{Sleeve}" CornerRadius="14" VerticalAlignment="Top">
      <Grid>
        <TextBlock Text="No cover" Foreground="{Soft}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        <Image x:Name="ECoverImg" Stretch="Uniform"/>
      </Grid>
    </Border>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
      <TextBlock Text="Barcode" VerticalAlignment="Center"/><TextBox x:Name="EBarcode" Grid.Column="1" Margin="0,3" Width="160" HorizontalAlignment="Left"/>
      <TextBlock Grid.Row="1" Text="Artist" VerticalAlignment="Center"/><TextBox x:Name="EArtist" Grid.Row="1" Grid.Column="1" Margin="0,3"/>
      <TextBlock Grid.Row="2" Text="Album" VerticalAlignment="Center"/><TextBox x:Name="EAlbum" Grid.Row="2" Grid.Column="1" Margin="0,3"/>
      <TextBlock Grid.Row="3" Text="Year" VerticalAlignment="Center"/><TextBox x:Name="EYear" Grid.Row="3" Grid.Column="1" Margin="0,3" Width="80" HorizontalAlignment="Left"/>
      <TextBlock Grid.Row="4" Text="Label" VerticalAlignment="Center"/><TextBox x:Name="ELabel" Grid.Row="4" Grid.Column="1" Margin="0,3"/>
      <TextBlock Grid.Row="5" Text="Genre" VerticalAlignment="Center"/><TextBox x:Name="EGenre" Grid.Row="5" Grid.Column="1" Margin="0,3"/>
      <TextBlock Grid.Row="6" Text="Tracks" VerticalAlignment="Center"/><TextBox x:Name="ETracks" Grid.Row="6" Grid.Column="1" Margin="0,3" Width="80" HorizontalAlignment="Left"/>
      <TextBlock Grid.Row="7" Text="Kept" VerticalAlignment="Center"/>
      <TextBox x:Name="EShelf" Grid.Row="7" Grid.Column="1" Visibility="Collapsed"/>
      <WrapPanel x:Name="EShelfChips" Grid.Row="7" Grid.Column="1" Margin="0,3" ToolTip="Where the CD is kept. Places... changes the list."/>
      <TextBlock Grid.Row="8" Text="Cover" VerticalAlignment="Center"/>
      <DockPanel Grid.Row="8" Grid.Column="1" Margin="0,3"><Button x:Name="ECoverPick" Content="Choose" DockPanel.Dock="Right" Margin="6,0,0,0" Padding="12,7"/><TextBox x:Name="ECover"/></DockPanel>
      <TextBlock Grid.Row="9" Text="Notes" VerticalAlignment="Top" Margin="0,8,0,0"/><TextBox x:Name="ENotes" Grid.Row="9" Grid.Column="1" Margin="0,3" Height="64" AcceptsReturn="True" TextWrapping="Wrap" VerticalContentAlignment="Top"/>
    </Grid>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    $w.Title = if ($Item) { 'Edit CD' } else { 'Add CD' }
    $f = @{}; foreach ($n in 'EBarcode', 'EArtist', 'EAlbum', 'EYear', 'ELabel', 'EGenre', 'ETracks', 'EShelf', 'EShelfChips', 'ECover', 'ENotes', 'ENote', 'ECoverImg') { $f[$n] = $w.FindName($n) }
    if ($Item) {
        $f.EBarcode.Text = $Item.Barcode; $f.EArtist.Text = $Item.Artist; $f.EAlbum.Text = $Item.Album; $f.EYear.Text = $Item.Year; $f.ELabel.Text = $Item.Label
        $f.EGenre.Text = $Item.Genre; $f.ETracks.Text = if ($Item.Tracks) { [string]$Item.Tracks } else { '' }; $f.ECover.Text = $Item.Cover; $f.ENotes.Text = $Item.Notes; $f.EShelf.Text = $Item.Shelf
    }
    $state = @{ Mbid = $(if ($Item) { $Item.Mbid } else { '' }); Country = $(if ($Item) { $Item.Country } else { '' }); Discs = $(if ($Item) { $Item.Discs } else { 0 }) }
    # Kept: one of your places (or none), as buttons; Places... changes the list.
    $fillPlaces = {
        $chips = $f.EShelfChips; $chips.Children.Clear()
        $places = @(Get-Places)
        if ($f.EShelf.Text -and $places -notcontains $f.EShelf.Text) { $places += $f.EShelf.Text }   # a place no longer on the list
        foreach ($p in @('') + $places) {
            $bt = New-Object Windows.Controls.Button
            $bt.Content = if ($p) { $p } else { 'Not set' }; $bt.Tag = $p; $bt.Padding = '12,6'; $bt.Margin = '0,0,6,4'
            if ($p -eq $f.EShelf.Text) { $bt.Style = $w.FindResource('Accent') }
            $bt.Add_Click({ $f.EShelf.Text = [string]$this.Tag; & $fillPlaces })
            [void]$chips.Children.Add($bt)
        }
        $ed = New-Object Windows.Controls.Button
        $ed.Content = 'Places...'; $ed.Padding = '12,6'; $ed.Margin = '0,0,0,4'; $ed.Background = [Windows.Media.Brushes]::Transparent
        $ed.ToolTip = 'Change the list of places, such as In Front Room; In Loft'
        $ed.Add_Click({
            $now = (@(Get-Places) -join '; ')
            $new = Show-AppMessage "Where you keep your CDs, separated by semicolons (;). For example: In Front Room; In Loft; Car" -Ask -Default $now -YesText 'Save' -NoText 'Cancel' -Owner $w
            if ($null -ne $new) { $script:Settings.Places = (@($new -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique) -join '; '); Save-AppSetting; & $fillPlaces }
        })
        [void]$chips.Children.Add($ed)
    }
    & $fillPlaces
    $showCover = { $f.ECoverImg.Source = Get-Picture $f.ECover.Text 300 }
    & $showCover
    $f.ECover.Add_TextChanged({ & $showCover })
    $w.FindName('ECoverPick').Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'Pictures (*.jpg;*.jpeg;*.png)|*.jpg;*.jpeg;*.png'
        if ($dlg.ShowDialog($w)) { $f.ECover.Text = $dlg.FileName }
    })
    $w.FindName('ELook').Add_Click({
        $f.ENote.Text = 'Looking it up...'
        $w.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
        $bc = ($f.EBarcode.Text -replace '\D', '')
        $job = if ($bc) { @{ Barcode = $bc } } else { @{ Id = 'x'; Artist = $f.EArtist.Text.Trim(); Album = $f.EAlbum.Text.Trim(); NeedCover = $true } }
        $sync = New-LookupSync; $sync.StopWhenEmpty = $true; $sync.Queue.Enqueue($job)
        & $script:LookupScan $sync $script:CoverDir $script:Agent
        $r = @($sync.Items)[0]
        if ($r -and $r.Found) {
            foreach ($pair in @(@('EArtist', 'Artist'), @('EAlbum', 'Album'), @('EYear', 'Year'), @('ELabel', 'Label'), @('ECover', 'Cover'))) { if ($r[$pair[1]]) { $f[$pair[0]].Text = $r[$pair[1]] } }
            if ($r.Tracks) { $f.ETracks.Text = [string]$r.Tracks }
            $state.Mbid = $r.Mbid; if ($r.Country) { $state.Country = $r.Country }; if ($r.Discs) { $state.Discs = $r.Discs }
            $f.ENote.Text = "Found in MusicBrainz$(if ($r.Matches -gt 1) { " (one of $($r.Matches) pressings with this barcode)" })$(if (-not $r.Cover) { '; no cover there' })."
        } elseif ($r -and $r.Failed) { $f.ENote.Text = "Couldn't look it up: $($r.Error)" }
        else { $f.ENote.Text = if ($bc) { 'That barcode is not in MusicBrainz. Type the details in by hand.' } else { 'Not found in MusicBrainz. Check the spelling of the artist and album.' } }
    })
    $script:EditSaved = $false
    $w.FindName('EOk').Add_Click({
        if (-not $f.EAlbum.Text.Trim() -and -not $f.EBarcode.Text.Trim()) { $f.ENote.Text = 'Type the album name (or a barcode) first.'; return }
        $script:EditSaved = $true; $w.Close()
    })
    $w.FindName('ECancel').Add_Click({ $w.Close() })
    [void]$w.ShowDialog()
    if (-not $script:EditSaved) { return }
    $new = -not $Item
    if ($new) { $Item = New-Object CdItem; $Item.Id = [guid]::NewGuid().ToString('N'); $Item.Added = (Get-Date).ToString('s') }
    $Item.Barcode = ($f.EBarcode.Text -replace '\D', ''); $Item.Artist = $f.EArtist.Text.Trim(); $Item.Album = $f.EAlbum.Text.Trim(); $Item.Year = $f.EYear.Text.Trim()
    $Item.Label = $f.ELabel.Text.Trim(); $Item.Genre = $f.EGenre.Text.Trim()
    $t = 0; [void][int]::TryParse($f.ETracks.Text.Trim(), [ref]$t); $Item.Tracks = $t
    $Item.Cover = $f.ECover.Text.Trim(); $Item.Notes = $f.ENotes.Text.Trim(); $Item.Shelf = $f.EShelf.Text.Trim(); $Item.Mbid = $state.Mbid; $Item.Country = $state.Country; $Item.Discs = [int]$state.Discs
    if ($new) { $script:Items.Add($Item) }
    Save-Catalogue
    [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items).Refresh()
    $script:UI.Grid.SelectedItem = $Item; $script:UI.Grid.ScrollIntoView($Item)
    Update-Summary; Show-Details
    Set-Status $(if ($new) { "Added $($Item.Artist) - $($Item.Title)." } else { "Saved $($Item.Artist) - $($Item.Title)." })
}

function Get-Picture([string]$Path, [int]$Width = 400) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $img = New-Object Windows.Media.Imaging.BitmapImage
        $img.BeginInit(); $img.StreamSource = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($Path)); $img.CacheOption = 'OnLoad'; $img.DecodePixelWidth = $Width; $img.EndInit(); $img.Freeze()
        return $img
    } catch { return $null }
}

# ---------------------------------------------------------------------------
#  More about this CD: the CD (track listing, release details, the album on
#  Wikipedia) and the artist (where from, formed or born, members, genres,
#  Wikipedia), side by side.
# ---------------------------------------------------------------------------
function Format-InfoDate([string]$Date) {
    try {
        if ($Date -match '^\d{4}-\d{2}-\d{2}$') { return ([datetime]::ParseExact($Date, 'yyyy-MM-dd', $null)).ToString('d MMMM yyyy') }
        if ($Date -match '^\d{4}-\d{2}$') { return ([datetime]::ParseExact($Date, 'yyyy-MM', $null)).ToString('MMMM yyyy') }
    } catch { Write-Verbose 'odd date' }
    return $Date
}

function Get-CountryName([string]$Code) {
    switch ($Code) { '' { return '' } 'XE' { return 'Europe' } 'XW' { return 'Worldwide' } 'XU' { return '' } }
    try { return (New-Object Globalization.RegionInfo $Code).DisplayName } catch { return $Code }
}

function Add-InfoText($Panel, [string]$Text, [string]$Kind = 'Body') {
    if (-not $Text) { return }
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text; $t.TextWrapping = 'Wrap'
    switch ($Kind) {
        'Title' { $t.FontSize = 22; $t.FontWeight = 'SemiBold' }
        'Sub'   { $t.FontSize = 14; $t.Margin = '0,2,0,0' }
        'Head'  { $t.FontWeight = 'SemiBold'; $t.Foreground = Get-Brush 'Accent'; $t.Margin = '0,18,0,4' }
        'Soft'  { $t.Foreground = Get-Brush 'Soft'; $t.Margin = '0,4,0,0' }
        default { $t.Margin = '0,3,0,0'; $t.LineHeight = 19 }
    }
    [void]$Panel.Children.Add($t)
}

function Add-InfoFact($Panel, [string]$Label, [string]$Value) {
    if (-not $Value) { return }
    $d = New-Object Windows.Controls.DockPanel
    $d.Margin = '0,3,0,0'
    $l = New-Object Windows.Controls.TextBlock
    $l.Text = $Label; $l.Width = 100; $l.Foreground = Get-Brush 'Soft'
    [Windows.Controls.DockPanel]::SetDock($l, 'Left')
    $v = New-Object Windows.Controls.TextBlock
    $v.Text = $Value; $v.TextWrapping = 'Wrap'
    [void]$d.Children.Add($l); [void]$d.Children.Add($v)
    [void]$Panel.Children.Add($d)
}

function Add-InfoLinks($Panel, [array]$Links) {
    $Links = @($Links | Where-Object { $_[1] })
    if (-not $Links.Count) { return }
    $t = New-Object Windows.Controls.TextBlock
    $t.Margin = '0,16,0,0'; $t.TextWrapping = 'Wrap'
    $first = $true
    foreach ($l in $Links) {
        if (-not $first) { $t.Inlines.Add((New-Object Windows.Documents.Run '     ')) }
        $first = $false
        $h = New-Object Windows.Documents.Hyperlink (New-Object Windows.Documents.Run $l[0])
        $h.Foreground = Get-Brush 'Accent'; $h.Tag = $l[1]; $h.ToolTip = $l[1]
        $h.Add_Click({ try { Start-Process $this.Tag } catch { Write-AppLog "Link: $($_.Exception.Message)" } })
        $t.Inlines.Add($h)
    }
    [void]$Panel.Children.Add($t)
}

function Show-InfoResult($Win, [CdItem]$Item, $Res) {
    $p = $Win.FindName('ICd'); $p.Children.Clear()
    $cd = $Res.Cd
    $top = New-Object Windows.Controls.DockPanel
    $pic = Get-Picture $Item.Shown 220
    if ($pic) {
        $img = New-Object Windows.Controls.Image
        $img.Width = 110; $img.Height = 110; $img.Margin = '0,0,14,0'; $img.VerticalAlignment = 'Top'; $img.Source = $pic
        [Windows.Controls.DockPanel]::SetDock($img, 'Left'); [void]$top.Children.Add($img)
    }
    # The disc beside the cover: the CD's own label when there's a photo of it, else a blank CD.
    $disc = New-Object Windows.Controls.Grid
    $disc.Width = 110; $disc.Height = 110; $disc.Margin = '0,0,16,0'; $disc.VerticalAlignment = 'Top'
    $label = if ($Item.Disc -and $Item.Disc -ne '-' -and $Item.DiscOf -eq $Item.Mbid) { Get-Picture $Item.Disc 220 } else { $null }
    $face = New-Object Windows.Shapes.Ellipse
    if ($label) { $lb = New-Object Windows.Media.ImageBrush $label; $lb.Stretch = 'UniformToFill'; $face.Fill = $lb } else { $face.Fill = Get-BlankDisc }
    [void]$disc.Children.Add($face)
    if ($label) {
        foreach ($h in @(@(32, 0.65), @(13, 1.0))) {
            $e = New-Object Windows.Shapes.Ellipse; $e.Width = $h[0]; $e.Height = $h[0]; $e.Fill = Get-Brush 'Card'; $e.Opacity = $h[1]
            [void]$disc.Children.Add($e)
        }
        $disc.ToolTip = "The CD's label, from the Cover Art Archive"
    } else { $disc.ToolTip = 'No photo of this CD''s label yet' }
    [Windows.Controls.DockPanel]::SetDock($disc, 'Left'); [void]$top.Children.Add($disc)
    $tp = New-Object Windows.Controls.StackPanel; $tp.VerticalAlignment = 'Center'; [void]$top.Children.Add($tp)
    [void]$p.Children.Add($top)
    Add-InfoText $tp $(if ($cd) { $cd.Title } else { $Item.Title }) 'Title'
    Add-InfoText $tp $(if ($cd) { $cd.Artist } else { $Item.Artist }) 'Sub'
    if ($cd) { Add-InfoText $tp $cd.Disambiguation 'Soft' }
    Add-InfoText $p 'THE CD' 'Head'
    if ($cd) {
        Add-InfoFact $p 'Type' $cd.Type
        Add-InfoFact $p 'First out' (Format-InfoDate $cd.First)
        Add-InfoFact $p 'This pressing' ((@((Format-InfoDate $cd.Date), (Get-CountryName $cd.Country)) | Where-Object { $_ }) -join ', ')
        Add-InfoFact $p 'Label' (@($cd.Labels) -join '; ')
        Add-InfoFact $p 'Format' ((@($cd.Format, $cd.Packaging) | Where-Object { $_ -and $_ -ne 'None' }) -join ', ')
        Add-InfoFact $p 'Barcode' $cd.Barcode
        Add-InfoFact $p 'Genres' ((Get-Culture).TextInfo.ToTitleCase((@($cd.Genres) -join ', ')))
        if ($cd.Wiki.Text) { Add-InfoText $p 'ABOUT THE ALBUM' 'Head'; Add-InfoText $p $cd.Wiki.Text }
        foreach ($disc in @($cd.Discs)) {
            $n = @($disc.Tracks).Count
            Add-InfoText $p $(if ($disc.Name) { "$(([string]$disc.Name).ToUpper())  ·  $n TRACKS" } else { "TRACKS  ·  $n" }) 'Head'
            foreach ($tr in @($disc.Tracks)) {
                $d = New-Object Windows.Controls.DockPanel
                $d.Margin = '0,2,0,0'
                $no = New-Object Windows.Controls.TextBlock; $no.Text = $tr.No; $no.Width = 30; $no.Foreground = Get-Brush 'Soft'
                $len = New-Object Windows.Controls.TextBlock; $len.Text = $tr.Length; $len.Foreground = Get-Brush 'Soft'; $len.Margin = '10,0,0,0'
                [Windows.Controls.DockPanel]::SetDock($no, 'Left'); [Windows.Controls.DockPanel]::SetDock($len, 'Right')
                $ti = New-Object Windows.Controls.TextBlock; $ti.TextWrapping = 'Wrap'
                $ti.Text = [string]$tr.Title + $(if ($tr.Artist -and $cd.Artist -and $tr.Artist -ne $cd.Artist) { "  ($($tr.Artist))" })
                [void]$d.Children.Add($no); [void]$d.Children.Add($len); [void]$d.Children.Add($ti)
                [void]$p.Children.Add($d)
            }
        }
        Add-InfoLinks $p @(@('MusicBrainz', $cd.Url), @('Wikipedia', $cd.Wiki.Url), @('Discogs', $cd.Discogs))
    } else {
        Add-InfoFact $p 'Year' $Item.Year
        Add-InfoFact $p 'Label' $Item.Label
        Add-InfoFact $p 'Barcode' $Item.Barcode
        Add-InfoText $p "This CD isn't linked to MusicBrainz, so there's no track listing. Edit and Look up links it." 'Soft'
    }

    $p = $Win.FindName('IArtist'); $p.Children.Clear()
    $a = $Res.Artist
    if (-not $a) {
        Add-InfoText $p $(if ($Item.Artist) { $Item.Artist } else { 'The artist' }) 'Title'
        Add-InfoText $p $(if ($Item.Artist -match '^various') { 'A compilation by various artists.' } else { "This artist wasn't found in MusicBrainz." }) 'Soft'
        return
    }
    Add-InfoText $p $a.Name 'Title'
    Add-InfoText $p ((@($a.Type, $a.Disambiguation) | Where-Object { $_ }) -join '  ·  ') 'Soft'
    Add-InfoText $p 'THE ARTIST' 'Head'
    Add-InfoFact $p 'From' ((@($a.From, $a.Country) | Where-Object { $_ } | Select-Object -Unique) -join ', ')
    $isGroup = $a.Type -match 'Group|Orchestra|Choir'
    $isPerson = $a.Type -eq 'Person'
    Add-InfoFact $p $(if ($isGroup) { 'Formed' } elseif ($isPerson) { 'Born' } else { 'Started' }) (Format-InfoDate $a.Begin)
    if ($a.Ended) { Add-InfoFact $p $(if ($isGroup) { 'Split up' } elseif ($isPerson) { 'Died' } else { 'Ended' }) $(if ($a.End) { Format-InfoDate $a.End } else { 'Yes' }) }
    Add-InfoFact $p 'Genres' ((Get-Culture).TextInfo.ToTitleCase((@($a.Genres) -join ', ')))
    if ($a.Wiki.Text) { Add-InfoText $p 'ABOUT THE ARTIST' 'Head'; Add-InfoText $p $a.Wiki.Text }
    if (@($a.Members).Count) { Add-InfoText $p 'MEMBERS' 'Head'; foreach ($m in @($a.Members)) { Add-InfoText $p $m } }
    if (@($a.MemberOf).Count) { Add-InfoText $p 'MEMBER OF' 'Head'; foreach ($m in @($a.MemberOf)) { Add-InfoText $p $m } }
    Add-InfoLinks $p @(@('MusicBrainz', $a.Url), @('Wikipedia', $a.Wiki.Url), @('Official site', $a.Home), @('Discogs', $a.Discogs))
}

function Show-Info([CdItem]$Item) {
    if (-not $Item) { return }
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1000" Height="700" MinWidth="720" MinHeight="420" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Bahnschrift, Segoe UI" FontSize="13.5" Background="{Page}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <DockPanel Margin="18,8,18,14">
    <DockPanel DockPanel.Dock="Bottom" Margin="0,12,0,0">
      <StackPanel Orientation="Horizontal" DockPanel.Dock="Right">
        <Button x:Name="IRefresh" Content="Look up again" ToolTip="Get the latest from MusicBrainz and Wikipedia"/>
        <Button x:Name="IClose" Content="Close" Style="{StaticResource Accent}" MinWidth="80" Margin="0" IsCancel="True"/>
      </StackPanel>
      <TextBlock x:Name="IStatus" Foreground="{Soft}" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,12,0"/>
    </DockPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="12"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <Border Background="{Card}" CornerRadius="22">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="22,18,14,18"><StackPanel x:Name="ICd"/></ScrollViewer>
      </Border>
      <Border Grid.Column="2" Background="{Card}" CornerRadius="22">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="22,18,14,18"><StackPanel x:Name="IArtist"/></ScrollViewer>
      </Border>
    </Grid>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    $w.Title = "More about $($Item.Artist) - $($Item.Title)"
    $status = $w.FindName('IStatus')
    $infoDir = Join-Path $script:DataDir 'Info'
    $key = if ($Item.Mbid -and $Item.Mbid -ne '-') { $Item.Mbid } else { 'artist-' + (($Item.Artist -replace '[^\w]', '_').ToLower()) }
    $cache = Join-Path $infoDir "$key.json"
    $st = @{ Sync = $null; PS = $null; Handle = $null }
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $start = {
        $w.FindName('IRefresh').IsEnabled = $false
        foreach ($n in 'ICd', 'IArtist') { $w.FindName($n).Children.Clear() }
        Add-InfoText $w.FindName('ICd') 'Looking it up...' 'Soft'
        $sync = [hashtable]::Synchronized(@{ Now = 'Starting...'; Finished = $false; Result = $null; Error = '' })
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($script:InfoScan).AddArgument($sync).AddArgument([string]$Item.Mbid).AddArgument([string]$Item.Artist).AddArgument($script:Agent).AddArgument((Get-Culture).TwoLetterISOLanguageName)
        $st.Sync = $sync; $st.PS = $ps; $st.Handle = $ps.BeginInvoke()
        $timer.Start()
    }
    $timer.Add_Tick({
        $s = $st.Sync
        if (-not $s.Finished) { $status.Text = $s.Now; return }
        $timer.Stop()
        try { $st.PS.EndInvoke($st.Handle) } catch { Write-AppLog "Info: $($_.Exception.Message)" }
        $st.PS.Dispose(); $st.PS = $null
        $w.FindName('IRefresh').IsEnabled = $true
        if (-not $s.Result) {
            $status.Text = "Couldn't look it up: $($s.Error)"; Write-AppLog "Info for $($Item.Artist) - $($Item.Title): $($s.Error)"
            $w.FindName('ICd').Children.Clear(); Add-InfoText $w.FindName('ICd') "Couldn't reach MusicBrainz. Check the internet connection and press Look up again." 'Soft'
            return
        }
        $res = $s.Result
        try {
            if (-not (Test-Path -LiteralPath $infoDir)) { New-Item -ItemType Directory -Path $infoDir -Force | Out-Null }
            $res | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $cache -Encoding UTF8
            $res = Get-Content -LiteralPath $cache -Raw -Encoding UTF8 | ConvertFrom-Json   # the same shape as when it's read back next time
        } catch { Write-AppLog "Info cache: $($_.Exception.Message)" }
        Invoke-Safely { Show-InfoResult $w $Item $res }
        $status.Text = 'From MusicBrainz and Wikipedia.'
        Write-AppLog "Info looked up for $($Item.Artist) - $($Item.Title)"
        # A CD with no genre gets one from MusicBrainz.
        $g = @(@($res.Cd.Genres) | Where-Object { $_ } | Select-Object -First 2)
        if (-not $Item.Genre -and $g.Count) {
            $Item.Genre = (Get-Culture).TextInfo.ToTitleCase(($g -join ', '))
            Save-Catalogue; [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items).Refresh(); Show-Details
        }
    })
    $w.FindName('IRefresh').Add_Click({ & $start })
    $w.FindName('IClose').Add_Click({ $w.Close() })
    $w.Add_Closing({ $timer.Stop(); if ($st.PS) { try { $st.PS.Stop(); $st.PS.Dispose() } catch { Write-Verbose 'stopped' } } })
    $w.Add_ContentRendered({
        $res = $null
        if (Test-Path -LiteralPath $cache) { try { $res = Get-Content -LiteralPath $cache -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $res = $null } }
        if ($res) {
            Invoke-Safely { Show-InfoResult $w $Item $res }
            $when = try { ([datetime]$res.Fetched).ToString('d MMMM yyyy') } catch { '' }
            $status.Text = "From MusicBrainz and Wikipedia$(if ($when) { ", looked up $when" }). Look up again for the latest."
        } else { & $start }
    })
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------------------
#  Main window
# ---------------------------------------------------------------------------
$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Tag="bare" Width="1280" Height="720" MinWidth="960" MinHeight="560" WindowStartupLocation="CenterScreen"
        FontFamily="Bahnschrift, Segoe UI" FontSize="13.5" Background="{Page}" Foreground="{Ink}">
  <Window.Resources>
STYLES
    <Style x:Key="PillField" TargetType="TextBox" BasedOn="{StaticResource {x:Type TextBox}}">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Padding" Value="10,9"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox">
        <Border Background="{TemplateBinding Background}"><ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center" Focusable="False"/></Border>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Rail" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Foreground" Value="{RailInk}"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Margin" Value="0,1"/><Setter Property="Padding" Value="14,7"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="16" Padding="{TemplateBinding Padding}">
          <StackPanel Orientation="Horizontal">
            <Path x:Name="P" Data="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" Stroke="{RailMark}" StrokeThickness="1.6"
                  StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Width="16" Height="16" Stretch="Uniform" VerticalAlignment="Center"/>
            <ContentPresenter Margin="12,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{RailHover}"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.7"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="RailView" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{RailInk}"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="0,1"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
        <Border x:Name="B" Background="Transparent" CornerRadius="16" Padding="14,7">
          <StackPanel Orientation="Horizontal">
            <Path x:Name="P" Data="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" Stroke="{RailMark}" StrokeThickness="1.6"
                  StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Width="16" Height="16" Stretch="Uniform" VerticalAlignment="Center"/>
            <ContentPresenter x:Name="C" Margin="12,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{RailHover}"/></Trigger>
          <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="B" Property="Background" Value="{RailMark}"/><Setter TargetName="P" Property="Stroke" Value="{Rail}"/>
            <Setter TargetName="C" Property="TextElement.Foreground" Value="{Rail}"/>
          </Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>

    <Style x:Key="WallTile" TargetType="ListBoxItem">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem">
        <Border x:Name="T" CornerRadius="16" Padding="8" Margin="2" Background="Transparent">
          <DockPanel>
            <StackPanel DockPanel.Dock="Bottom" Height="38" Margin="3,5,3,0">
              <TextBlock Text="{Binding Title}" FontSize="14" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
              <TextBlock Text="{Binding Artist}" FontSize="12" Foreground="{Soft}" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
            </StackPanel>
            <Grid>
              <Border CornerRadius="10" Background="{Sleeve}">
                <Viewbox Margin="26">
                  <Grid Width="100" Height="100">
                    <Ellipse Fill="{Disc}"/><Ellipse Width="36" Height="36" Fill="{Sleeve}" Opacity="0.7"/><Ellipse Width="13" Height="13" Fill="{Sleeve}"/>
                  </Grid>
                </Viewbox>
              </Border>
              <Border CornerRadius="10">
                <Border.Background><ImageBrush ImageSource="{Binding Thumb, IsAsync=True}" Stretch="UniformToFill"/></Border.Background>
              </Border>
              <Border x:Name="Src" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,7,7,0" CornerRadius="8" Padding="7,1,7,2"
                      Background="#0C6663" BorderBrush="#40FFFFFF" BorderThickness="1" ToolTip="Details from MusicBrainz">
                <TextBlock x:Name="SrcText" Text="MB" FontSize="11" FontWeight="SemiBold" Foreground="#FFFFFF"/>
              </Border>
            </Grid>
          </DockPanel>
        </Border>
        <ControlTemplate.Triggers>
          <DataTrigger Binding="{Binding FromMb}" Value="False">
            <Setter TargetName="Src" Property="Background" Value="#F4B740"/><Setter TargetName="Src" Property="ToolTip" Value="Entered by hand"/>
            <Setter TargetName="SrcText" Property="Text" Value="Hand"/><Setter TargetName="SrcText" Property="Foreground" Value="#2A2210"/>
          </DataTrigger>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="{Hover}"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="T" Property="Background" Value="{Select}"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="DiscoTile" TargetType="ListBoxItem">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem">
        <Border x:Name="T" CornerRadius="16" Padding="8" Margin="2" Background="Transparent">
          <DockPanel>
            <StackPanel DockPanel.Dock="Bottom" Height="38" Margin="3,5,3,0">
              <TextBlock Text="{Binding Title}" FontSize="14" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
              <TextBlock Text="{Binding YearText}" FontSize="12" Foreground="{Soft}" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
            </StackPanel>
            <Grid>
              <Border CornerRadius="10" Background="{Sleeve}">
                <Viewbox Margin="26">
                  <Grid Width="100" Height="100">
                    <Ellipse Fill="{Disc}"/><Ellipse Width="36" Height="36" Fill="{Sleeve}" Opacity="0.7"/><Ellipse Width="13" Height="13" Fill="{Sleeve}"/>
                  </Grid>
                </Viewbox>
              </Border>
              <Border CornerRadius="10">
                <Border.Background><ImageBrush ImageSource="{Binding Thumb, IsAsync=True}" Stretch="UniformToFill"/></Border.Background>
              </Border>
              <Border x:Name="Src" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,7,7,0" CornerRadius="8" Padding="7,1,7,2"
                      Background="#0C6663" BorderBrush="#40FFFFFF" BorderThickness="1" ToolTip="Details from MusicBrainz">
                <TextBlock x:Name="SrcText" Text="MB" FontSize="11" FontWeight="SemiBold" Foreground="#FFFFFF"/>
              </Border>
            </Grid>
          </DockPanel>
        </Border>
        <ControlTemplate.Triggers>
          <DataTrigger Binding="{Binding FromMb}" Value="False">
            <Setter TargetName="Src" Property="Background" Value="#F4B740"/><Setter TargetName="Src" Property="ToolTip" Value="Entered by hand"/>
            <Setter TargetName="SrcText" Property="Text" Value="Hand"/><Setter TargetName="SrcText" Property="Foreground" Value="#2A2210"/>
          </DataTrigger>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="{Hover}"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="T" Property="Background" Value="{Select}"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="ArtistRow" TargetType="ListBoxItem">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem">
        <Border x:Name="T" CornerRadius="12" Padding="12,7" Margin="0,1" Background="Transparent">
          <StackPanel>
            <TextBlock Text="{Binding Name}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
            <TextBlock Text="{Binding Meta}" FontSize="12" Foreground="{Soft}" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
          </StackPanel>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="{Hover}"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="T" Property="Background" Value="{Select}"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>

    <Style x:Key="Cell" TargetType="TextBlock"><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style>
    <Style x:Key="AlbumCell" TargetType="TextBlock"><Setter Property="TextTrimming" Value="CharacterEllipsis"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
    <Style x:Key="Grip" TargetType="Thumb">
      <Setter Property="Width" Value="7"/><Setter Property="Cursor" Value="SizeWE"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Foreground" Value="{Soft}"/><Setter Property="FontSize" Value="12"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="DataGridColumnHeader">
        <Grid Background="Transparent">
          <StackPanel Orientation="Horizontal" Margin="8,8,8,10">
            <ContentPresenter/>
            <Path x:Name="Arrow" Data="M0,4 L4,0 L8,4" Stroke="{Accent}" StrokeThickness="1.5" Margin="6,0,0,0" VerticalAlignment="Center" Visibility="Collapsed"/>
          </StackPanel>
          <Thumb x:Name="PART_RightHeaderGripper" HorizontalAlignment="Right" Style="{StaticResource Grip}"/>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="SortDirection" Value="Ascending"><Setter TargetName="Arrow" Property="Visibility" Value="Visible"/></Trigger>
          <Trigger Property="SortDirection" Value="Descending"><Setter TargetName="Arrow" Property="Visibility" Value="Visible"/><Setter TargetName="Arrow" Property="Data" Value="M0,0 L4,4 L8,0"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="{Ink}"/>
      <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{Hover}"/></Trigger></Style.Triggers>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Padding" Value="8,5"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="DataGridCell">
        <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"><ContentPresenter VerticalAlignment="Center"/></Border>
      </ControlTemplate></Setter.Value></Setter>
      <Style.Triggers><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{Select}"/><Setter Property="Foreground" Value="{Ink}"/></Trigger></Style.Triggers>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ProgressBar">
        <Grid ClipToBounds="True">
          <Border x:Name="Run" Width="180" HorizontalAlignment="Left" CornerRadius="2" Background="{Accent}">
            <Border.RenderTransform><TranslateTransform X="-180"/></Border.RenderTransform>
          </Border>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="IsVisible" Value="True">
            <Trigger.EnterActions><BeginStoryboard x:Name="Go"><Storyboard RepeatBehavior="Forever">
              <DoubleAnimation Storyboard.TargetName="Run" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" From="-180" To="1000" Duration="0:0:1.8"/>
            </Storyboard></BeginStoryboard></Trigger.EnterActions>
            <Trigger.ExitActions><StopStoryboard BeginStoryboardName="Go"/></Trigger.ExitActions>
          </Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="208"/><ColumnDefinition/></Grid.ColumnDefinitions>

    <Border Background="{Rail}" Padding="14,22,14,16">
      <DockPanel LastChildFill="False">
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="8,0,0,22">
          <Grid Width="44" Height="44">
            <Ellipse Fill="{RailMark}"/>
            <Ellipse Width="34" Height="34" Stroke="{Rail}" StrokeThickness="1" Opacity="0.45"/>
            <Ellipse Width="24" Height="24" Stroke="{Rail}" StrokeThickness="1" Opacity="0.45"/>
            <Ellipse Width="11" Height="11" Fill="{Rail}"/>
          </Grid>
          <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="CD" FontSize="20" FontWeight="Bold" Foreground="{RailMark}"/>
            <TextBlock Text="Catalogue" FontSize="18" Foreground="{RailInk}" Margin="0,-3,0,0"/>
          </StackPanel>
        </StackPanel>
        <StackPanel DockPanel.Dock="Top">
          <RadioButton x:Name="ViewCovers" GroupName="View" Style="{StaticResource RailView}" Content="Covers" IsChecked="True"
                       Tag="M0,0 H7 V7 H0 Z M9,0 H16 V7 H9 Z M0,9 H7 V16 H0 Z M9,9 H16 V16 H9 Z" ToolTip="Your CDs as a wall of covers"/>
          <RadioButton x:Name="ViewList" GroupName="View" Style="{StaticResource RailView}" Content="List"
                       Tag="M0,1 H1 M5,1 H16 M0,8 H1 M5,8 H16 M0,15 H1 M5,15 H16" ToolTip="Your CDs as a list: click a heading to sort"/>
          <RadioButton x:Name="ViewArtists" GroupName="View" Style="{StaticResource RailView}" Content="Artists"
                       Tag="M8,4 A3,3 0 1 1 2,4 A3,3 0 1 1 8,4 M0,16 C0,9 10,9 10,16 M12,3 H16 M12,8 H16 M12,13 H16"
                       ToolTip="Your CDs by artist: pick an artist to see all their albums together, in year order"/>
          <Border Height="1" Background="{RailHover}" Margin="10,12"/>
          <Button x:Name="BtnAdd" Style="{StaticResource Rail}" Content="Add by hand" Tag="M8,0 V16 M0,8 H16" ToolTip="Add a CD by hand (one with no barcode)"/>
          <Button x:Name="BtnLookup" Style="{StaticResource Rail}" Content="Look up online" Tag="M13,6.5 A6.5,6.5 0 1 1 0,6.5 A6.5,6.5 0 1 1 13,6.5 M11,11 L16,16" ToolTip="Fill in missing details and covers for CDs added by hand"/>
          <Button x:Name="BtnCsv" Style="{StaticResource Rail}" Content="Export CSV" Tag="M0,0 H16 V16 H0 Z M0,5.5 H16 M0,10.5 H16 M6,0 V16" ToolTip="Save your CDs (or what your search found) as a CSV file for Excel and other spreadsheets"/>
          <Button x:Name="BtnReport" Style="{StaticResource Rail}" Content="HTML report" Tag="M8,11 V0 M4,4 L8,0 L12,4 M0,9 V16 H16 V9" ToolTip="Save your CDs (or what your search found) as a web page with the covers, to open, print or share"/>
          <Button x:Name="BtnPick" Style="{StaticResource Rail}" Content="Pick for me" Tag="M1,1 H15 V15 H1 Z M5,5 V5.1 M11,5 V5.1 M8,8 V8.1 M5,11 V11.1 M11,11 V11.1" ToolTip="Can't decide what to play? Picks a CD at random from the ones shown (search first to pick from one place, genre or decade)"/>
          <Button x:Name="BtnStats" Style="{StaticResource Rail}" Content="Stats" Tag="M0,16 H16 M2,16 V9 M6,16 V3 M10,16 V7 M14,16 V11" ToolTip="Your collection in numbers: decades, top artists, labels and genres"/>
          <Button x:Name="BtnBackup" Style="{StaticResource Rail}" Content="Backup" Tag="M2,0 H11 L14,3 V16 H2 Z M5,0 V5 H10 V0 M5,10 H11 M5,13 H11" ToolTip="Back up your whole catalogue to one file, or restore a backup"/>
          <Button x:Name="BtnCollection" Style="{StaticResource Rail}" Content="MB collection" Tag="M2,0 H14 V16 L8,11 L2,16 Z" ToolTip="Send your CDs to a collection in your MusicBrainz account"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom">
          <Button x:Name="BtnLook" Style="{StaticResource Rail}" Tag="M16,8 A8,8 0 1 1 0,8 A8,8 0 1 1 16,8 M8,0 V16 M10,4 H14 M10,8 H16 M10,12 H14"/>
          <Button x:Name="BtnHelp" Style="{StaticResource Rail}" Content="Help" Tag="M16,8 A8,8 0 1 1 0,8 A8,8 0 1 1 16,8 M5.5,6 C5.5,2.5 10.5,2.5 10.5,6 C10.5,8 8,8 8,10 M8,12.8 V13"/>
          <Button x:Name="BtnAbout" Style="{StaticResource Rail}" Content="About" Tag="M16,8 A8,8 0 1 1 0,8 A8,8 0 1 1 16,8 M8,7 V12 M8,4 V4.2"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <DockPanel Grid.Column="1" Margin="24,0,18,0">
      <DockPanel DockPanel.Dock="Top" Margin="0,20,130,0" MinHeight="52">
        <StackPanel x:Name="Key" DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center" Margin="12,0,0,0">
          <Button x:Name="KeyMb" Padding="8,5,12,5" ToolTip="Details from MusicBrainz (scanned or looked up). Click to show only these; click again to show all.">
            <StackPanel Orientation="Horizontal">
              <Border CornerRadius="8" Padding="7,1,7,2" Background="#0C6663" VerticalAlignment="Center"><TextBlock Text="MB" FontSize="11" FontWeight="SemiBold" Foreground="#FFFFFF"/></Border>
              <TextBlock x:Name="KeyMbText" Text="from MusicBrainz" Margin="7,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
          <Button x:Name="KeyHand" Padding="8,5,12,5" Margin="0" ToolTip="Entered by hand (added by hand, or not found in MusicBrainz and filled in). Click to show only these; click again to show all.">
            <StackPanel Orientation="Horizontal">
              <Border CornerRadius="8" Padding="7,1,7,2" Background="#F4B740" VerticalAlignment="Center"><TextBlock Text="Hand" FontSize="11" FontWeight="SemiBold" Foreground="#2A2210"/></Border>
              <TextBlock x:Name="KeyHandText" Text="entered by hand" Margin="7,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
        </StackPanel>
        <StackPanel VerticalAlignment="Center">
          <TextBlock x:Name="TxtSummary" FontSize="28" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
          <TextBlock x:Name="TxtTotals" Foreground="{Soft}" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
      </DockPanel>

      <Grid DockPanel.Dock="Top" Margin="0,14,0,14">
        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="14"/><ColumnDefinition Width="300"/></Grid.ColumnDefinitions>
        <Border Background="{Card}" CornerRadius="24" Padding="17,6,6,6">
          <DockPanel>
            <Path DockPanel.Dock="Left" Width="26" Height="20" VerticalAlignment="Center" Margin="0,0,11,0" Stroke="{Ink}" StrokeThickness="1.8"
                  Data="M1,0 V20 M5,0 V20 M8,0 V20 M13,0 V20 M16,0 V20 M19,0 V20 M25,0 V20"/>
            <Button x:Name="BtnScan" DockPanel.Dock="Right" Content="Add CD" Style="{StaticResource Accent}" Margin="8,0,0,0" MinWidth="86"/>
            <Button x:Name="BtnBatch" DockPanel.Dock="Right" Content="Scan several" Margin="8,0,0,0" Padding="13,7"
                    ToolTip="Scan a pile of CDs first, then press Search to look them all up, one after another"/>
            <Grid>
              <TextBlock x:Name="TxtScanNote" Text="Scan or type a barcode" FontSize="15" Foreground="{Soft}" VerticalAlignment="Center" Margin="14,0,0,0" TextTrimming="CharacterEllipsis" IsHitTestVisible="False"/>
              <TextBox x:Name="TxtBarcode" FontSize="16" Style="{StaticResource PillField}"
                       ToolTip="Scan the barcode on the back of the CD, or type the number and press Enter. Scan as many as you like."/>
            </Grid>
          </DockPanel>
        </Border>
        <Border Grid.Column="2" Background="{Card}" CornerRadius="24" Padding="17,6,8,6">
          <DockPanel>
            <Path DockPanel.Dock="Left" Width="16" Height="16" Stretch="Uniform" VerticalAlignment="Center" Margin="0,0,6,0" Stroke="{Soft}" StrokeThickness="1.6"
                  Data="M13,6.5 A6.5,6.5 0 1 1 0,6.5 A6.5,6.5 0 1 1 13,6.5 M11,11 L16,16"/>
            <Button x:Name="BtnField" DockPanel.Dock="Right" Content="All" Padding="12,5" Margin="6,0,0,0" VerticalAlignment="Center"
                    ToolTip="Search everything, or only the artist, album, year, label, genre, barcode or notes"/>
            <Grid>
              <TextBlock x:Name="TxtHint" Text="Search your CDs" Foreground="{Soft}" Margin="14,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
              <TextBox x:Name="TxtSearch" Style="{StaticResource PillField}" ToolTip="Type part of a name, or pick what to search with the button. You can also type artist: album: year: label: genre: barcode: or notes:, for example  year:1990-1999 label:attic"/>
            </Grid>
          </DockPanel>
        </Border>
      </Grid>

      <Grid DockPanel.Dock="Bottom" MinHeight="42">
        <TextBlock x:Name="TxtStatus" VerticalAlignment="Center" TextWrapping="Wrap" Foreground="{Soft}" Margin="4,6"/>
        <ProgressBar x:Name="Progress" Height="3" VerticalAlignment="Top" Visibility="Hidden" IsIndeterminate="True"/>
      </Grid>

      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <ListBox x:Name="Wall" Background="Transparent" BorderThickness="0" Padding="0" Foreground="{Ink}" IsSynchronizedWithCurrentItem="False"
                 ItemContainerStyle="{StaticResource WallTile}" ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.CanContentScroll="True">
          <ListBox.Template><ControlTemplate TargetType="ListBox">
            <ScrollViewer Focusable="False" CanContentScroll="True" HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer>
          </ControlTemplate></ListBox.Template>
        </ListBox>
        <Border x:Name="ListCard" Background="{Card}" CornerRadius="20" Padding="10,8" Visibility="Collapsed">
          <DataGrid x:Name="Grid" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single" HeadersVisibility="Column" RowHeaderWidth="0"
                    Background="Transparent" RowBackground="Transparent" Foreground="{Ink}" BorderThickness="0" IsSynchronizedWithCurrentItem="False"
                    GridLinesVisibility="None" CanUserResizeRows="False"
                    EnableRowVirtualization="True" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
            <DataGrid.Columns>
              <DataGridTemplateColumn Header="" Width="54" CanUserSort="False">
                <DataGridTemplateColumn.CellTemplate><DataTemplate>
                  <Grid Width="38" Height="38">
                    <Border CornerRadius="7" Background="{Sleeve}"/>
                    <Border CornerRadius="7"><Border.Background><ImageBrush ImageSource="{Binding Thumb, IsAsync=True}" Stretch="UniformToFill"/></Border.Background></Border>
                  </Grid>
                </DataTemplate></DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTemplateColumn Header="From" Width="70" SortMemberPath="Source" CanUserSort="True">
                <DataGridTemplateColumn.CellTemplate><DataTemplate>
                  <Border x:Name="Src" HorizontalAlignment="Left" VerticalAlignment="Center" CornerRadius="8" Padding="7,1,7,2" Background="#0C6663" ToolTip="Details from MusicBrainz">
                    <TextBlock x:Name="SrcText" Text="MB" FontSize="11" FontWeight="SemiBold" Foreground="#FFFFFF"/>
                  </Border>
                  <DataTemplate.Triggers>
                    <DataTrigger Binding="{Binding FromMb}" Value="False">
                      <Setter TargetName="Src" Property="Background" Value="#F4B740"/><Setter TargetName="Src" Property="ToolTip" Value="Entered by hand"/>
                      <Setter TargetName="SrcText" Property="Text" Value="Hand"/><Setter TargetName="SrcText" Property="Foreground" Value="#2A2210"/>
                    </DataTrigger>
                  </DataTemplate.Triggers>
                </DataTemplate></DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTextColumn Header="Album" Width="2*" MinWidth="80" Binding="{Binding Title}" ElementStyle="{StaticResource AlbumCell}" SortMemberPath="Album"/>
              <DataGridTextColumn Header="Artist" Width="1.5*" MinWidth="70" Binding="{Binding Artist}" ElementStyle="{StaticResource Cell}"/>
              <DataGridTextColumn Header="Year" Width="58" Binding="{Binding Year}"/>
              <DataGridTextColumn Header="Label" Width="1.1*" MinWidth="50" Binding="{Binding Label}" ElementStyle="{StaticResource Cell}"/>
              <DataGridTextColumn Header="Kept" Width="0.8*" MinWidth="50" Binding="{Binding Shelf}" ElementStyle="{StaticResource Cell}"/>
              <DataGridTextColumn Header="Tracks" Width="64" Binding="{Binding Tracks}"/>
              <DataGridTextColumn Header="Barcode" Width="118" Binding="{Binding Barcode}"/>
            </DataGrid.Columns>
          </DataGrid>
        </Border>

        <Grid x:Name="ArtistCard" Visibility="Collapsed">
          <Grid.ColumnDefinitions><ColumnDefinition Width="2*" MinWidth="160" MaxWidth="270"/><ColumnDefinition Width="5*"/></Grid.ColumnDefinitions>
          <Border Background="{Card}" CornerRadius="20" Padding="6,10">
            <DockPanel>
              <TextBlock x:Name="ArtCount" DockPanel.Dock="Top" Foreground="{Soft}" FontSize="12" Margin="12,0,0,6"/>
              <ListBox x:Name="ArtistList" Background="Transparent" BorderThickness="0" Foreground="{Ink}" ItemContainerStyle="{StaticResource ArtistRow}"
                       ScrollViewer.HorizontalScrollBarVisibility="Disabled" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
                <ListBox.Template><ControlTemplate TargetType="ListBox">
                  <ScrollViewer Focusable="False" CanContentScroll="True" HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer>
                </ControlTemplate></ListBox.Template>
              </ListBox>
            </DockPanel>
          </Border>
          <DockPanel Grid.Column="1" Margin="14,0,0,0">
            <DockPanel DockPanel.Dock="Top" Margin="10,0,0,8">
              <Button x:Name="BtnGaps" DockPanel.Dock="Right" Content="What's missing?" VerticalAlignment="Center" Padding="14,7" Margin="12,0,0,0" Visibility="Collapsed"
                      ToolTip="This artist's studio albums on MusicBrainz, with the ones you have marked"/>
              <StackPanel>
                <TextBlock x:Name="ArtName" FontSize="24" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                <TextBlock x:Name="ArtMeta" Foreground="{Soft}" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
              </StackPanel>
            </DockPanel>
            <ListBox x:Name="Disco" Background="Transparent" BorderThickness="0" Padding="0" Foreground="{Ink}" IsSynchronizedWithCurrentItem="False"
                 ItemContainerStyle="{StaticResource DiscoTile}" ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.CanContentScroll="True">
          <ListBox.Template><ControlTemplate TargetType="ListBox">
            <ScrollViewer Focusable="False" CanContentScroll="True" HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer>
          </ControlTemplate></ListBox.Template>
        </ListBox>
          </DockPanel>
        </Grid>

        <StackPanel x:Name="Empty" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed">
          <Grid Width="248" Height="184">
            <Grid Width="172" Height="172" HorizontalAlignment="Right">
              <Ellipse Fill="{Disc}"/>
              <Ellipse Width="150" Height="150" Stroke="{Page}" StrokeThickness="1" Opacity="0.4"/>
              <Ellipse Width="126" Height="126" Stroke="{Page}" StrokeThickness="1" Opacity="0.4"/>
              <Ellipse Width="64" Height="64" Fill="{RailMark}"/><Ellipse Width="22" Height="22" Fill="{Page}"/>
            </Grid>
            <Border Width="178" Height="178" CornerRadius="14" Background="{Rail}" HorizontalAlignment="Left">
              <Path Width="86" Height="54" Stroke="{RailMark}" StrokeThickness="4"
                    Data="M2,0 V54 M12,0 V54 M20,0 V54 M34,0 V54 M42,0 V54 M50,0 V54 M64,0 V54 M72,0 V54 M84,0 V54"/>
            </Border>
          </Grid>
          <TextBlock x:Name="EmptyTitle" FontSize="23" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,22,0,0"/>
          <TextBlock x:Name="EmptyText" Foreground="{Soft}" MaxWidth="390" TextWrapping="Wrap" TextAlignment="Center" Margin="0,6,0,0"/>
        </StackPanel>

        <Border x:Name="Details" Grid.Column="1" Width="300" Margin="14,0,0,0" Background="{Card}" CornerRadius="24" Padding="18,16,18,14" VerticalAlignment="Bottom">
          <DockPanel>
            <Grid DockPanel.Dock="Bottom" Margin="0,8,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <Button x:Name="BtnEdit" Content="Edit" Padding="13,7" Margin="0,0,6,0" IsEnabled="False"/>
              <Button x:Name="BtnRemove" Grid.Column="1" Content="Remove" Padding="13,7" Margin="0,0,6,0" IsEnabled="False"/>
              <Button x:Name="BtnMb" Grid.Column="2" Content="MusicBrainz" Padding="4,7" Margin="0" IsEnabled="False" ToolTip="Open its page on musicbrainz.org"/>
            </Grid>
            <Button x:Name="BtnInfo" DockPanel.Dock="Bottom" Content="More about the CD and artist" Style="{StaticResource Accent}" Margin="0,10,0,0" IsEnabled="False"
                    ToolTip="The track listing, the album and the artist, from MusicBrainz and Wikipedia"/>
            <Button x:Name="BtnVersions" DockPanel.Dock="Bottom" Content="Choose the version" Margin="0,10,0,0" IsEnabled="False"
                    ToolTip="MusicBrainz can have several versions (pressings) with the same barcode: see them all and pick yours"/>
            <ScrollViewer VerticalScrollBarVisibility="Auto" Focusable="False">
              <StackPanel>
                <Viewbox MaxHeight="210" HorizontalAlignment="Left">
                  <Grid Width="318" Height="200">   <!-- the disc slides out far enough to show its hole -->
                    <Grid Width="186" Height="186" HorizontalAlignment="Right">
                      <Ellipse x:Name="DDisc" Fill="{Disc}"/>
                      <Ellipse Width="178" Height="178" Stroke="{Card}" StrokeThickness="1" Opacity="0.5"/>
                      <Ellipse x:Name="DHub" Width="54" Height="54" Fill="{Card}" Opacity="0.65"/><Ellipse x:Name="DHole" Width="22" Height="22" Fill="{Card}"/>
                    </Grid>
                    <Border Width="200" Height="200" CornerRadius="12" Background="{Sleeve}" HorizontalAlignment="Left">
                      <Grid>
                        <TextBlock x:Name="DNoCover" Text="Pick a CD" Foreground="{Soft}" HorizontalAlignment="Center" VerticalAlignment="Center" TextWrapping="Wrap" TextAlignment="Center" Margin="22"/>
                        <Border x:Name="DCover" CornerRadius="12"/>
                      </Grid>
                    </Border>
                  </Grid>
                </Viewbox>
                <TextBlock x:Name="DAlbum" FontSize="22" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,14,0,0"/>
                <TextBlock x:Name="DArtist" FontSize="15" Foreground="{Accent}" TextWrapping="Wrap" Margin="0,3,0,0"/>
                <TextBlock x:Name="DMeta" Foreground="{Soft}" TextWrapping="Wrap" LineHeight="19" Margin="0,8,0,0"/>
                <TextBlock x:Name="DNotes" TextWrapping="Wrap" Margin="0,8,0,0"/>
              </StackPanel>
            </ScrollViewer>
          </DockPanel>
        </Border>
      </Grid>
    </DockPanel>
  </Grid>
</Window>
'@.Replace('STYLES', $script:Styles)

function Set-Status([string]$Text, [string]$Tone = 'Soft') {
    $script:UI.TxtStatus.Text = $Text
    $script:UI.TxtStatus.Foreground = Get-Brush $Tone
}

function Invoke-Safely([scriptblock]$Action) {
    try { & $Action }
    catch { Write-AppLog "Error: $($_.Exception.Message)"; [void](Show-AppMessage "Something went wrong:`n$($_.Exception.Message)`n`nDetails are in $script:LogPath") }
}

function Update-Summary {
    $all = @($script:Items)
    $ui = $script:UI
    $artists = @($all | Where-Object Artist | Select-Object -ExpandProperty Artist -Unique).Count
    $fromMb = @($all | Where-Object { $_.FromMb }).Count
    $ui.KeyMbText.Text = "from MusicBrainz ($fromMb)"
    $ui.KeyHandText.Text = "entered by hand ($($all.Count - $fromMb))"
    $ui.Key.Visibility = if ($all.Count) { 'Visible' } else { 'Collapsed' }
    $ui.TxtSummary.Text = if ($all.Count) { "$($all.Count) CD$(if ($all.Count -ne 1) { 's' }) by $artists artist$(if ($artists -ne 1) { 's' })" } else { 'Your collection' }
    if ($all.Count) {
        $notFound = @($all | Where-Object { -not $_.Album }).Count
        $noCover = @($all | Where-Object { -not $_.Shown }).Count
        $years = @($all | Where-Object { $_.Year -match '^\d{4}$' } | ForEach-Object { [int]$_.Year })
        $m = $years | Measure-Object -Minimum -Maximum
        $span = if (-not $years.Count) { '' } elseif ($m.Minimum -eq $m.Maximum) { "from $($m.Minimum)" } else { "from $($m.Minimum) to $($m.Maximum)" }
        $ui.TxtTotals.Text = (@($span, $(if ($notFound) { "$notFound not found in MusicBrainz" }), $(if ($noCover) { "$noCover with no cover" })) | Where-Object { $_ }) -join '  ·  '
    } else { $ui.TxtTotals.Text = '' }
    Update-Shelf
}

function Update-Shelf {
    <# Covers or list, or the empty picture when there are no CDs (or none match the search). #>
    $ui = $script:UI
    $none = -not $script:Items.Count
    $shown = if ($none) { 0 } else { @([Windows.Data.CollectionViewSource]::GetDefaultView($script:Items)).Count }
    $mode = if ($script:Settings.View -in 'List', 'Artists') { $script:Settings.View } else { 'Covers' }
    $ui.Wall.Visibility = if ($shown -and $mode -eq 'Covers') { 'Visible' } else { 'Collapsed' }
    $ui.ListCard.Visibility = if ($shown -and $mode -eq 'List') { 'Visible' } else { 'Collapsed' }
    $ui.ArtistCard.Visibility = if ($shown -and $mode -eq 'Artists') { 'Visible' } else { 'Collapsed' }
    $ui.Details.Visibility = if ($none) { 'Collapsed' } else { 'Visible' }
    $ui.Empty.Visibility = if ($shown) { 'Collapsed' } else { 'Visible' }
    $ui.EmptyTitle.Text = if ($none) { 'Start your wall of CDs' } else { 'Nothing matches' }
    $ui.EmptyText.Text = if ($none) { "Scan the barcode on the back of a CD and its cover lands here. No barcode? Use Add by hand." } else { 'Try part of the artist, album, label or barcode.' }
    if ($shown -and $mode -eq 'Artists') { Update-Artists }
}

# ---------------------------------------------------------------------------
#  Artists: every artist with their CDs together, in year order, like a discography.
#  Names are matched without regard to case or spaces round them; "The" is skipped when sorting.
# ---------------------------------------------------------------------------
function Get-ArtistKey($Item) {
    $a = ([string]$Item.Artist).Trim()
    if (-not $a) { return '' }
    return $a.ToLowerInvariant()
}

function Get-ArtistSort([string]$Name) {
    return ($Name -replace '^(?i)the\s+', '')
}

function Update-Artists {
    <# Fills the artist list from the CDs the search shows, keeping the artist you were on. #>
    $ui = $script:UI
    $groups = @{}
    foreach ($i in [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items)) {
        $k = ([string]$i.Artist).Trim().ToLowerInvariant()   # as Get-ArtistKey, written out: this runs for every CD
        $g = $groups[$k]
        if ($null -eq $g) { $g = New-Object 'Collections.Generic.HashSet[object]'; $groups[$k] = $g }
        [void]$g.Add($i)
    }
    $script:ArtistGroups = $groups
    $rows = foreach ($k in $groups.Keys) {
        $cds = $groups[$k]
        $first = $null; foreach ($c in $cds) { $first = $c; break }
        $name = if ($k) { ([string]$first.Artist).Trim() } else { '(no artist)' }
        $years = @($cds | ForEach-Object { $_.Year } | Where-Object { $_ -match '^\d{4}$' } | Sort-Object)
        $span = if (-not $years.Count) { '' } elseif ($years[0] -eq $years[-1]) { $years[0] } else { "$($years[0]) to $($years[-1])" }
        $meta = (@("$($cds.Count) CD$(if ($cds.Count -ne 1) { 's' })", $span) | Where-Object { $_ }) -join '  ·  '
        New-Object ArtistRow -Property @{ Key = $k; Name = $name; Meta = $meta; Count = $cds.Count; Sort = (Get-ArtistSort $name) }
    }
    $rows = @($rows | Sort-Object @{ Expression = { [int](-not $_.Key) } }, @{ Expression = { $_.Sort } })   # no artist last
    # "All artists" first: every CD the search shows, by artist and then year. Artists opens on it.
    $total = 0; foreach ($k in $groups.Keys) { $total += $groups[$k].Count }
    $namedCount = @($groups.Keys | Where-Object { $_ }).Count
    $all = New-Object ArtistRow -Property @{ Key = '*'; Name = 'All artists'; Count = $total; Sort = ''
        Meta = "$total CD$(if ($total -ne 1) { 's' }) by $namedCount artist$(if ($namedCount -ne 1) { 's' })" }
    $rows = @($all) + $rows
    $script:ArtistRows = $rows
    $script:ArtistFilling = $true
    try {
        $ui.ArtistList.ItemsSource = $rows
        $named = @($rows | Where-Object { $_.Key -and $_.Key -ne '*' }).Count
        $ui.ArtCount.Text = "$named artist$(if ($named -ne 1) { 's' })"
        # All artists when Artists opens; after that the artist you were on (or the selected CD's, when
        # one picked elsewhere is by someone else), unless you're on All artists.
        $want = if ($null -eq $script:DiscoKey) { '*' } else { $script:DiscoKey }
        $sel = $ui.Grid.SelectedItem
        if ($want -ne '*' -and $sel -and $groups.ContainsKey((Get-ArtistKey $sel))) { $want = Get-ArtistKey $sel }
        $row = @($rows | Where-Object { $_.Key -eq $want }) | Select-Object -First 1
        if (-not $row -and $rows.Count) { $row = $rows[0] }
        $ui.ArtistList.SelectedItem = $row
        if ($row) { $ui.ArtistList.ScrollIntoView($row) }
    } finally { $script:ArtistFilling = $false }
    Show-Artist $row
}

function Show-Artist($Row) {
    <# One artist's CDs, oldest first, with a line about them over the covers. #>
    $ui = $script:UI
    $script:DiscoKey = if ($Row) { $Row.Key } else { $null }
    $script:DiscoSet = $null
    if ($Row -and $Row.Key -ne '*' -and $script:ArtistGroups) { $script:DiscoSet = $script:ArtistGroups[$Row.Key] }   # assigned directly: an if would unroll the set
    $everyone = $Row -and $Row.Key -eq '*'
    $ui.BtnGaps.Visibility = if ($Row -and $Row.Key -and -not $everyone) { 'Visible' } else { 'Collapsed' }
    $sorts = if ($everyone) { @('NoArtist', 'ArtistSort', 'Year', 'Album') } else { @('Year', 'Album') }
    if ((@($script:DiscoView.SortDescriptions | ForEach-Object PropertyName) -join ',') -ne ($sorts -join ',')) {
        $script:DiscoView.SortDescriptions.Clear()
        foreach ($p in $sorts) { $script:DiscoView.SortDescriptions.Add((New-Object ComponentModel.SortDescription $p, 'Ascending')) }
    }
    # The covers say who it's by on All artists, and the year on one artist.
    $ui.Disco.ItemContainerStyle = $script:Window.FindResource($(if ($everyone) { 'WallTile' } else { 'DiscoTile' }))
    $script:DiscoView.Refresh()
    if (-not $Row) { $ui.ArtName.Text = ''; $ui.ArtMeta.Text = ''; return }
    $cds = @($script:DiscoView)
    $ui.ArtName.Text = $Row.Name
    $genres = @($cds | ForEach-Object { ([string]$_.Genre) -split '\s*,\s*' } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First 4 | ForEach-Object Name)
    $labels = @($cds | ForEach-Object { $_.Label } | Where-Object { $_ } | Select-Object -Unique)
    $ui.ArtMeta.Text = (@($Row.Meta, ($genres -join ', '), $(if ($labels.Count) { "on $(@($labels | Select-Object -First 3) -join ', ')$(if ($labels.Count -gt 3) { ' and others' })" })) | Where-Object { $_ }) -join '  ·  '
    $sel = $ui.Grid.SelectedItem
    $inView = $sel -and $(if ($everyone) { $cds -contains $sel } else { (Get-ArtistKey $sel) -eq $Row.Key })
    if (-not $inView) { if ($cds.Count) { $ui.Grid.SelectedItem = $cds[0] } }
    else { $ui.Disco.SelectedItem = $sel; $ui.Disco.ScrollIntoView($sel) }
}


# ---------------------------------------------------------------------------
#  Search: everything, or one field (the button in the search box), and
#  artist: album: year: label: genre: country: barcode: notes: typed in the box.
#  A year can be 1997, 1990-1999 (or 1990 to 1999) or 1990s. Everything typed has to match.
# ---------------------------------------------------------------------------
$script:SearchFields = [ordered]@{
    All     = @('All', 'Search your CDs')
    Artist  = @('Artist', 'Search by artist')
    Album   = @('Album', 'Search by album')
    Year    = @('Year', 'Year: 1997, 1990-1999 or 1990s')
    Label   = @('Label', 'Search by record label')
    Genre   = @('Genre', 'Search by genre')
    Barcode = @('Barcode', 'Search by barcode')
    Notes   = @('Notes', 'Search your notes')
    Shelf   = @('Kept', 'Search where CDs are kept')
    Track   = @('Track', 'Search for a song (track title)')
}
$script:SearchField = 'All'

function Get-SearchParts([string]$Text, [string]$Field) {
    <# The search as a list of { Field; Want }: each typed field:value, and the rest for the button's field. #>
    $parts = New-Object Collections.ArrayList
    $rx = '(?i)\b(artist|album|year|label|genre|country|barcode|notes?|source|from|shelf|kept|box|track|song)\s*:\s*("([^"]*)"?|\S*)'
    foreach ($m in [regex]::Matches($Text, $rx)) {
        $want = if ($m.Groups[3].Success) { $m.Groups[3].Value } else { $m.Groups[2].Value }
        $name = (Get-Culture).TextInfo.ToTitleCase($m.Groups[1].Value.ToLowerInvariant()) -replace '^Note$', 'Notes' -replace '^From$', 'Source' -replace '^(Kept|Box)$', 'Shelf' -replace '^Song$', 'Track'
        if ($want.Trim()) { [void]$parts.Add(@{ Field = $name; Want = $want.Trim() }) }
    }
    $rest = ([regex]::Replace($Text, $rx, ' ')).Trim()
    if ($rest) { [void]$parts.Add(@{ Field = $Field; Want = $rest }) }
    return , $parts
}

function Get-YearSpan([string]$Want) {
    <# 1997, 1990-1999 / 1990 to 1999, or 1990s as @(first, last); $null when it isn't a year. #>
    $Want = $Want.Trim()
    if ($Want -match '^(\d{4})\s*(?:-|to)\s*(\d{4})$') { $a = [int]$Matches[1]; $b = [int]$Matches[2]; if ($a -gt $b) { $a, $b = $b, $a }; return @($a, $b) }
    if ($Want -match "^(\d{3})0'?s$") { $a = [int]"$($Matches[1])0"; return @($a, ($a + 9)) }
    if ($Want -match '^\d{4}$') { return @([int]$Want, [int]$Want) }
    return $null
}

function Initialize-Search {
    <# Turns the search parts into what Test-CdSearch checks: the fields to look in, and any years. #>
    $script:SearchChecks = @(foreach ($c in $script:SearchParts) {
        $span = Get-YearSpan $c.Want
        $names = switch ($c.Field) {
            'All'  { @('Artist', 'Album', 'Label', 'Genre', 'Barcode', 'Notes', 'Shelf', 'TrackText') }
            'Track' { @('TrackText') }
            'Year' { if ($span) { @() } else { @('Year') } }
            default { @($c.Field) }
        }
        $mb = $null   # source: mb / musicbrainz, or hand / manual
        if ($c.Field -eq 'Source') { $names = @(); $span = $null; $mb = $c.Want -match '^(?i)m' }
        @{ Want = $c.Want; Names = $names; Span = $span; Country = ($c.Field -eq 'All'); Mb = $mb }
    })
}

function Test-CdSearch($Item) {
    foreach ($c in $script:SearchChecks) {
        $hit = $false
        foreach ($n in $c.Names) { if (([string]$Item.$n).IndexOf($c.Want, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break } }
        if (-not $hit -and $c.Span) { $y = 0; if ([int]::TryParse($Item.Year, [ref]$y) -and $y -ge $c.Span[0] -and $y -le $c.Span[1]) { $hit = $true } }
        if (-not $hit -and $c.Country -and $Item.Country -eq $c.Want) { $hit = $true }
        if ($null -ne $c.Mb) { $hit = ($Item.FromMb -eq $c.Mb) }
        if (-not $hit) { return $false }
    }
    return $true
}

function Show-FieldMenu {
    $ui = $script:UI
    # A menu in the app's own look (the Windows one has a grey strip for icons).
    $menu = [Windows.Markup.XamlReader]::Parse((Expand-Xaml @'
<ContextMenu xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
             FontFamily="Bahnschrift, Segoe UI" FontSize="13.5" HasDropShadow="False">
  <ContextMenu.Template><ControlTemplate TargetType="ContextMenu">
    <Border Background="{Card}" BorderBrush="{Thumb}" BorderThickness="1" CornerRadius="12" Padding="5"><StackPanel IsItemsHost="True"/></Border>
  </ControlTemplate></ContextMenu.Template>
  <ContextMenu.Resources>
    <Style TargetType="MenuItem">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="MenuItem">
        <Border x:Name="B" CornerRadius="8" Padding="14,6" MinWidth="120" Background="Transparent">
          <ContentPresenter ContentSource="Header" TextElement.Foreground="{Ink}"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="B" Property="Background" Value="{Select}"/></Trigger>
          <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="B" Property="Background" Value="{Hover}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
  </ContextMenu.Resources>
</ContextMenu>
'@))
    foreach ($k in $script:SearchFields.Keys) {
        $item = New-Object Windows.Controls.MenuItem
        $item.Header = if ($k -eq 'All') { 'Everything' } else { $k }
        $item.Tag = $k; $item.IsCheckable = $false; $item.IsChecked = ($k -eq $script:SearchField)
        $item.Foreground = Get-Brush 'Ink'
        $item.Add_Click({ Set-SearchField $this.Tag })
        [void]$menu.Items.Add($item)
    }
    $menu.PlacementTarget = $ui.BtnField; $menu.Placement = 'Bottom'; $menu.IsOpen = $true
}

function Set-SearchField([string]$Field) {
    $ui = $script:UI
    $script:SearchField = $Field
    $ui.BtnField.Content = $script:SearchFields[$Field][0]
    $ui.TxtHint.Text = $script:SearchFields[$Field][1]
    $ui.TxtSearch.Focus() | Out-Null
    Update-View
}

function Update-View {
    $q = $script:UI.TxtSearch.Text.Trim()
    $view = [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items)
    $script:SearchParts = Get-SearchParts $q $script:SearchField
    Initialize-Search
    $script:SearchTest = if ($script:SearchParts.Count) { { param($i) Test-CdSearch $i } } else { $null }
    $view.Filter = if ($script:SearchTest) { [Predicate[object]]$script:SearchTest } else { $null }
    $n = @($view).Count
    foreach ($k in @(@('KeyMb', 'source:mb'), @('KeyHand', 'source:hand'))) {
        $script:UI[$k[0]].Background = Get-Brush $(if ($q -eq $k[1]) { 'Select' } else { 'Chip' })
    }
    if ($script:SearchParts.Count) {
        $said = ($script:SearchParts | ForEach-Object { if ($_.Field -eq 'All') { '"{0}"' -f $_.Want } else { '{0} "{1}"' -f $_.Field.ToLowerInvariant(), $_.Want } }) -join ' and '
        Set-Status "$n CD$(if ($n -ne 1) { 's' }) match$(if ($n -eq 1) { 'es' }) $said."
    } else { Set-Status '' }
    if ($n -and -not $script:UI.Grid.SelectedItem) { $script:UI.Grid.SelectedItem = @($view)[0] }   # always a CD on the sleeve
    Update-Shelf
}

function Show-Details {
    $i = $script:UI.Grid.SelectedItem
    $ui = $script:UI
    $has = $i -is [CdItem]
    foreach ($b in 'BtnEdit', 'BtnRemove') { $ui[$b].IsEnabled = $has }
    $ui.BtnInfo.IsEnabled = $has -and ($i.Album -or $i.Artist)
    $ui.BtnVersions.IsEnabled = $has -and $i.Barcode
    # A barcode MusicBrainz didn't know can be added to MusicBrainz from here.
    $known = $has -and $i.Mbid -and $i.Mbid -ne '-'
    $canAdd = $has -and -not $known -and $i.Barcode
    $ui.BtnMb.Content = if ($canAdd) { 'Add to MusicBrainz' } else { 'MusicBrainz' }
    $ui.BtnMb.ToolTip = if ($canAdd) { "Open MusicBrainz's Add release page with this CD's details filled in, so the barcode is found next time" } else { 'Open its page on musicbrainz.org' }
    $ui.BtnMb.IsEnabled = $known -or $canAdd
    if (-not $has) {
        $ui.DCover.Background = $null; $ui.DDisc.Fill = Get-Brush 'Disc'; $ui.DNoCover.Text = 'Pick a CD'
        foreach ($t in 'DAlbum', 'DArtist', 'DMeta', 'DNotes') { $ui[$t].Text = '' }
        return
    }
    $pic = Get-Picture $i.Shown 600
    if ($pic) {
        $art = New-Object Windows.Media.ImageBrush $pic
        $art.Stretch = 'UniformToFill'
        $ui.DCover.Background = $art
    } else { $ui.DCover.Background = $null }
    # The CD's own label on the disc when the Cover Art Archive has a photo of it, else a plain blank CD.
    $label = if ($i.Disc -and $i.Disc -ne '-' -and $i.DiscOf -eq $i.Mbid) { Get-Picture $i.Disc 400 } else { $null }
    if ($label) { $lb = New-Object Windows.Media.ImageBrush $label; $lb.Stretch = 'UniformToFill'; $ui.DDisc.Fill = $lb }
    else { $ui.DDisc.Fill = Get-BlankDisc }
    # The drawing has its own hub and hole; a photo gets them drawn over it.
    $ui.DHub.Visibility = if ($label) { 'Visible' } else { 'Hidden' }
    $ui.DHole.Visibility = $ui.DHub.Visibility
    $ui.DDisc.ToolTip = if ($label) { "The CD's label, from the Cover Art Archive" } else { $null }
    $ui.DNoCover.Text = if ($pic) { '' } else { 'No cover. Edit to pick a picture, or look it up.' }
    $ui.DAlbum.Text = $i.Title
    $ui.DArtist.Text = $i.Artist
    $ui.DMeta.Text = (@($i.Year, $i.Label, $i.Country, $i.Genre,
        $(if ($i.Tracks) { "$($i.Tracks) track$(if ($i.Tracks -ne 1) { 's' })" }), $(if ($i.Discs -gt 1) { "$($i.Discs) discs" }),
        $(if ($i.Barcode) { "barcode $($i.Barcode)" }), $(if ($i.FromMb) { 'details from MusicBrainz' } else { 'entered by hand' }), $(if ($i.Shelf) { "kept: $($i.Shelf)" })) | Where-Object { $_ }) -join '  ·  '
    $ui.DNotes.Text = $i.Notes
}

# One background worker takes look-ups from a queue, so barcodes can be scanned one after another.
function New-LookupSync {
    return [hashtable]::Synchronized(@{ Items = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)); Queue = New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
                                         Done = 0; Now = ''; Finished = $false; Cancel = $false; StopWhenEmpty = $false })
}
$script:Worker = $null
function Send-Lookup($Job) {
    if (-not $script:Worker -or $script:Worker.Sync.Finished) {
        if ($script:Worker) { try { $script:Worker.PS.EndInvoke($script:Worker.Handle) } catch { Write-AppLog "Look-up: $($_.Exception.Message)" }; $script:Worker.PS.Dispose() }
        $sync = New-LookupSync; $sync.StopWhenEmpty = $true
        $sync.Queue.Enqueue($Job)
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($script:LookupScan).AddArgument($sync).AddArgument($script:CoverDir).AddArgument($script:Agent)
        $script:Worker = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Sync = $sync; Taken = 0; Sent = 1; Added = 0; Missing = 0; Filled = 0 }
    } else {
        $script:Worker.Sync.Queue.Enqueue($Job); $script:Worker.Sent++
    }
    $script:UI.Progress.Visibility = 'Visible'
}

# Checks a barcode before it's looked up or put on the Scan several list. Returns $true when it's fine.
function Test-NewBarcode([string]$Bc) {
    $ui = $script:UI
    if ($Bc.Length -lt 8 -or $Bc.Length -gt 14) { Set-Status "$Bc doesn't look like a CD barcode (they have 8 to 14 digits)." 'Warn'; return $false }
    $dup = @($script:Items | Where-Object { $_.Barcode -eq $Bc }) | Select-Object -First 1
    if ($dup) {
        $ui.Grid.SelectedItem = $dup; $ui.Grid.ScrollIntoView($dup)
        Set-Status "Already in your catalogue: $($dup.Artist) - $($dup.Title)." 'Warn'
        [Media.SystemSounds]::Exclamation.Play()
        return $false
    }
    if (@($script:Pending | Where-Object { $_ -eq $Bc }).Count) { Set-Status "$Bc is being looked up already."; return $false }
    return $true
}

function Send-Barcode([string]$Bc) {
    $script:Pending += $Bc
    Send-Lookup @{ Barcode = $Bc }
}

# Enter in the barcode box (or Add CD / Search). In Scan several, the barcode goes on the list
# instead, and Search (the button, Enter in an empty box, or typing "search") looks them all up.
function Add-Barcode {
    $ui = $script:UI
    $typed = $ui.TxtBarcode.Text.Trim()
    $bc = ($typed -replace '\D', '')
    $ui.TxtBarcode.Text = ''
    $ui.TxtBarcode.Focus() | Out-Null
    if ($script:Batching) {
        if ((-not $bc -and -not $typed) -or $typed -eq 'search') { Start-BatchSearch; return }
        if (-not $bc) { return }
        if (-not (Test-NewBarcode $bc)) { return }
        if ($script:Batch -contains $bc) { Set-Status "$bc is on the list already. Scan the next CD, or press Search." 'Warn'; [Media.SystemSounds]::Exclamation.Play(); return }
        $script:Batch += $bc
        Update-BatchUi
        Set-Status "$($script:Batch.Count) scanned, the last $bc. Scan the next CD, or press Search to look them all up."
        return
    }
    if (-not $bc) { return }
    if (-not (Test-NewBarcode $bc)) { return }
    Send-Barcode $bc
    Set-Status "Looking up $bc...$(if ($script:Pending.Count -gt 1) { " ($($script:Pending.Count) waiting)" })"
}
$script:Pending = @()
$script:Versions = @{}     # CD Id -> the versions MusicBrainz has for its barcode (this session only)
$script:ToChoose = @()     # CDs found with several versions, waiting for you to pick yours
$script:Choosing = $false

# Asks "Which version is yours?" for CDs found with several versions, one at a time, once the
# look-ups have finished (so scanning isn't interrupted) and no other window is open.
function Step-Choose {
    if ($script:Choosing -or $script:Batching -or $script:Worker -or -not $script:ToChoose.Count -or -not $script:Window.IsActive) { return }
    $id = $script:ToChoose[0]
    $script:ToChoose = @($script:ToChoose | Select-Object -Skip 1)
    $i = @($script:Items | Where-Object { $_.Id -eq $id }) | Select-Object -First 1
    if ($i) { Show-Versions $i }
}

# ---------------------------------------------------------------------------
#  The disc's label: the Cover Art Archive often has a photo of the CD itself
#  (its "Medium" picture) as well as the cover. It's looked for once per CD, one
#  at a time in the background, and shown on the disc beside the cover.
# ---------------------------------------------------------------------------
$script:DiscScan = {
    param([string]$Mbid, [string]$Barcode, [string]$Dir, [string]$Agent)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # The Medium (disc) picture of one release: its address, '' when it has none, $null when the archive couldn't be asked.
    function Get-MediumUrl([string]$Release) {
        try { $j = Invoke-RestMethod -Uri "https://coverartarchive.org/release/$Release" -UserAgent $Agent -TimeoutSec 20 }
        catch {
            $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 }
            if ($code -eq 404 -or $code -eq 400) { return '' }
            return $null
        }
        $img = @($j.images | Where-Object { @($_.types) -contains 'Medium' }) | Select-Object -First 1
        if (-not $img) { return '' }
        return (@([string]$img.thumbnails.'500', [string]$img.thumbnails.large, [string]$img.image) | Where-Object { $_ } | Select-Object -First 1) -replace '^http:', 'https:'
    }
    $u = Get-MediumUrl $Mbid
    if ($null -eq $u) { return '' }
    if (-not $u -and $Barcode) {
        # None for this version: other versions with the same barcode usually have the same disc print.
        try {
            Start-Sleep -Milliseconds 1100   # MusicBrainz asks for one request a second
            $r = Invoke-RestMethod -Uri ('https://musicbrainz.org/ws/2/release/?fmt=json&limit=10&query=barcode:' + [Uri]::EscapeDataString($Barcode)) -UserAgent $Agent -TimeoutSec 20
            foreach ($rel in @($r.releases | Where-Object { $_.id -ne $Mbid -and $_.barcode -eq $Barcode } | Select-Object -First 8)) {
                $u = Get-MediumUrl ([string]$rel.id)
                if ($u) { break }
                Start-Sleep -Milliseconds 300
            }
        } catch { return '' }
    }
    if (-not $u) { return '-' }
    $file = Join-Path $Dir "$Mbid-disc.jpg"
    try { Invoke-WebRequest -Uri $u -UserAgent $Agent -OutFile $file -UseBasicParsing -TimeoutSec 30; return $file }
    catch { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue; return '' }
}
$script:DiscJob = $null
# A blank CD (the app's own drawing, assets\blank-cd.png, with a real hole), for a disc with no photo of its label.
$script:BlankDisc = $null
function Get-BlankDisc {
    if ($null -eq $script:BlankDisc) {
        $img = Get-AssetImage 'blank-cd.png'
        $script:BlankDisc = if ($img) { $b = New-Object Windows.Media.ImageBrush $img; $b.Stretch = 'Uniform'; $b.Freeze(); $b } else { Get-Brush 'Disc' }
    }
    return $script:BlankDisc
}
$script:DiscTried = New-Object 'Collections.Generic.HashSet[string]'   # this session: don't keep retrying a failed one
$script:DiscFound = 0

function Step-Disc {
    <# Called by the timer: finishes a disc look-up, or starts the next one. #>
    $job = $script:DiscJob
    if ($job) {
        if (-not $job.Handle.IsCompleted) { return }
        $out = ''
        try { $out = [string](@($job.PS.EndInvoke($job.Handle)) | Select-Object -Last 1) } catch { Write-AppLog "Disc picture: $($_.Exception.Message)" }
        $job.PS.Dispose(); $script:DiscJob = $null
        $i = $job.Item
        if ($out -and $i.Mbid -eq $job.Mbid) {
            $i.Disc = $out; $i.DiscOf = $job.Mbid; $i.DiscWhen = (Get-Date).ToString('yyyy-MM-dd'); $script:DiscFound++
            if ($out -ne '-' -and [object]::ReferenceEquals($script:UI.Grid.SelectedItem, $i)) { Show-Details }
            if ($script:DiscFound % 10 -eq 0) { Save-Catalogue }
        }
        return
    }
    if ($script:Worker -or $script:GapsOpen) { return }   # MusicBrainz look-ups (and What's missing?) first
    $next = $null
    foreach ($i in $script:Items) {
        if (-not $i.FromMb -or $script:DiscTried.Contains($i.Mbid)) { continue }
        # Not looked for yet (or for another version), or none found over a week ago (someone may have added one).
        $when = [datetime]::MinValue; [void][datetime]::TryParse([string]$i.DiscWhen, [ref]$when)
        if ($i.DiscOf -ne $i.Mbid -or ($i.Disc -eq '-' -and $when -lt (Get-Date).AddDays(-7))) { $next = $i; break }
    }
    if (-not $next) { if ($script:DiscFound) { Save-Catalogue; $script:DiscFound = 0 }; return }
    [void]$script:DiscTried.Add($next.Mbid)
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:DiscScan).AddArgument($next.Mbid).AddArgument([string]$next.Barcode).AddArgument($script:CoverDir).AddArgument($script:Agent)
    $script:DiscJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Item = $next; Mbid = $next.Mbid }
}

# ---------------------------------------------------------------------------
#  Backup and restore: the whole catalogue (CDs, covers, disc photos and what
#  More about found) in one .zip, and back again. Settings (the look and the
#  MusicBrainz sign-in) aren't included: the sign-in only works on this PC.
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

function Get-StoredPath([string]$Path) {
    <# A picture's path as kept in a backup: Covers\name for the app's own, else $null. #>
    if (-not $Path) { return $null }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($script:DataDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($script:DataDir.TrimEnd('\').Length + 1) }
    return $null
}

function New-CatalogueBackup([string]$ZipPath) {
    <# Writes the backup and returns how many CDs and pictures it holds. #>
    Save-Catalogue
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $zip = [IO.Compression.ZipFile]::Open($ZipPath, 'Create')
    $pics = 0
    try {
        $added = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $rows = foreach ($i in $script:Items) {
            $r = [ordered]@{}; foreach ($p in $script:Fields) { $r[$p] = $i.$p }; $r.Tracks = $i.Tracks; $r.Discs = $i.Discs
            foreach ($p in 'Cover', 'Disc') {
                $v = [string]$i.$p
                if (-not $v -or $v -eq '-' -or -not (Test-Path -LiteralPath $v)) { continue }
                $rel = Get-StoredPath $v
                if (-not $rel) { $rel = "Covers\own-$($i.Id)-$p$([IO.Path]::GetExtension($v))" }   # a picture you chose from elsewhere
                if ($added.Add($rel)) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $v, ($rel -replace '\\', '/')); $pics++ }
                $r[$p] = $rel
            }
            [pscustomobject]$r
        }
        foreach ($sub in 'Info', 'Tracks') {
            $dir = Join-Path $script:DataDir $sub
            if (Test-Path -LiteralPath $dir) {
                foreach ($f in Get-ChildItem -LiteralPath $dir -File) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, "$sub/$($f.Name)") }
            }
        }
        $put = {
            param($Name, $Text)
            $en = $zip.CreateEntry($Name); $w = New-Object IO.StreamWriter ($en.Open(), (New-Object Text.UTF8Encoding $false)); $w.Write($Text); $w.Dispose()
        }
        & $put 'catalogue.json' (ConvertTo-Json @($rows) -Depth 3)
        & $put 'backup.json' (ConvertTo-Json ([ordered]@{ App = $script:AppName; Version = $script:AppVersion; Made = (Get-Date).ToString('s'); CDs = $script:Items.Count; Pictures = $pics }))
    } finally { $zip.Dispose() }
    return @{ CDs = $script:Items.Count; Pictures = $pics }
}

function Backup-Catalogue {
    if (-not $script:Items.Count) { [void](Show-AppMessage 'There are no CDs to back up yet.'); return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'CD Catalogue backup (*.zip)|*.zip'; $dlg.DefaultExt = '.zip'; $dlg.AddExtension = $true
    $dlg.FileName = "CD Catalogue backup $((Get-Date).ToString('yyyy-MM-dd')).zip"
    if (-not $dlg.ShowDialog($script:Window)) { return }
    $script:Window.Cursor = 'Wait'
    try { $n = New-CatalogueBackup $dlg.FileName } finally { $script:Window.Cursor = $null }
    Write-AppLog "Backed up $($n.CDs) CDs and $($n.Pictures) pictures to $($dlg.FileName)"
    Set-Status "Backed up $($n.CDs) CD$(if ($n.CDs -ne 1) { 's' }) and $($n.Pictures) picture$(if ($n.Pictures -ne 1) { 's' }) to $($dlg.FileName)" 'Good'
}

function Restore-Catalogue {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'CD Catalogue backup (*.zip)|*.zip'
    if (-not $dlg.ShowDialog($script:Window)) { return }
    $zip = $null
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($dlg.FileName)
        $about = $zip.GetEntry('backup.json'); $cat = $zip.GetEntry('catalogue.json')
        if (-not $about -or -not $cat) { [void](Show-AppMessage "That isn't a CD Catalogue backup (it has no catalogue in it)."); return }
        $r = New-Object IO.StreamReader ($about.Open()); $meta = $r.ReadToEnd() | ConvertFrom-Json; $r.Dispose()
        $made = [datetime]::MinValue; [void][datetime]::TryParse([string]$meta.Made, [ref]$made)
        $when = if ($made -gt [datetime]::MinValue) { $made.ToString('d MMMM yyyy, HH:mm') } else { 'an unknown date' }
        $ask = "Replace your $($script:Items.Count) CD$(if ($script:Items.Count -ne 1) { 's' }) with the $($meta.CDs) CD$(if ($meta.CDs -ne 1) { 's' }) in this backup from $($when)?`n`n" +
               "Your catalogue as it is now is saved first, in the Backups folder beside it, so this can be undone."
        if (-not (Show-AppMessage $ask -YesText 'Restore' -NoText 'Cancel')) { return }
        $script:Window.Cursor = 'Wait'
        # A safety copy of what's there now.
        $keep = Join-Path $script:DataDir 'Backups'
        if (-not (Test-Path -LiteralPath $keep)) { New-Item -ItemType Directory -Path $keep -Force | Out-Null }
        $safety = Join-Path $keep "Before restore $((Get-Date).ToString('yyyy-MM-dd HHmmss')).zip"
        if ($script:Items.Count) { [void](New-CatalogueBackup $safety) }
        foreach ($en in $zip.Entries) {
            if (-not $en.Name -or $en.FullName -eq 'backup.json') { continue }
            $rel = $en.FullName -replace '/', '\'
            if ($rel -notmatch '^(catalogue\.json|(Covers|Info|Tracks)\\[^\\]+)$') { continue }   # nothing outside the data folder
            $to = Join-Path $script:DataDir $rel
            $dir = Split-Path -Parent $to; if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($en, $to, $true)
        }
        $zip.Dispose(); $zip = $null
        $script:Items.Clear()
        Read-Catalogue
        $script:DiscTried.Clear(); $script:TrackTried.Clear()
        [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items).Refresh()
        Update-View; Update-Summary
        if ($script:Items.Count) { $script:UI.Grid.SelectedItem = @([Windows.Data.CollectionViewSource]::GetDefaultView($script:Items))[0] }
        Write-AppLog "Restored $($script:Items.Count) CDs from $($dlg.FileName) (the catalogue before it is in $safety)"
        Set-Status "Restored $($script:Items.Count) CD$(if ($script:Items.Count -ne 1) { 's' }) from the backup. Your catalogue as it was is in the Backups folder." 'Good'
    } catch {
        Write-AppLog "Restore: $($_.Exception.Message)"
        [void](Show-AppMessage "The backup couldn't be restored:`n$($_.Exception.Message)")
    } finally { if ($zip) { $zip.Dispose() }; $script:Window.Cursor = $null }
}

function Get-Places {
    <# Your places for Kept, from settings (Places, separated by semicolons). #>
    return @(([string]$script:Settings.Places) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Show-Backup {
    $c = Show-AppChoice ("Back up saves your whole catalogue (CDs, notes, covers and disc photos) in one .zip file. Keep it somewhere safe, such as another drive or the cloud.`n`n" +
        "Restore puts a backup back, replacing the CDs here.") 'Back up' 'Restore' 'Backup and restore'
    if ($c -eq 1) { Backup-Catalogue } elseif ($c -eq 2) { Restore-Catalogue }
}

# ---------------------------------------------------------------------------
#  Stats: the collection in numbers
# ---------------------------------------------------------------------------
function Show-Stats {
    $all = @($script:Items)
    if (-not $all.Count) { [void](Show-AppMessage 'There are no CDs yet, so there are no stats.'); return }
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="780" Height="640" MinWidth="560" MinHeight="400" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Bahnschrift, Segoe UI" FontSize="13.5" Background="{Page}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <DockPanel Margin="20,6,20,18">
    <Button x:Name="SClose" DockPanel.Dock="Bottom" Content="Close" HorizontalAlignment="Right" MinWidth="80" Margin="0,14,0,0" IsCancel="True" IsDefault="True"/>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="SBody"/></ScrollViewer>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    $w.Title = 'Your collection in numbers'
    $body = $w.FindName('SBody')
    $card = {
        param([string]$Title)
        $bd = New-Object Windows.Controls.Border
        $bd.Background = Get-Brush 'Card'; $bd.CornerRadius = 18; $bd.Padding = '18,14'; $bd.Margin = '0,0,0,12'
        $sp = New-Object Windows.Controls.StackPanel; $bd.Child = $sp
        $t = New-Object Windows.Controls.TextBlock; $t.Text = $Title.ToUpper(); $t.Foreground = Get-Brush 'Accent'; $t.FontWeight = 'SemiBold'; $t.Margin = '0,0,0,8'
        [void]$sp.Children.Add($t); [void]$body.Children.Add($bd)
        return $sp
    }
    $bars = {
        param($Panel, $Pairs)   # @(@(label, count), ...)
        $max = [Math]::Max(1, (@($Pairs | ForEach-Object { $_[1] }) | Measure-Object -Maximum).Maximum)
        foreach ($p in $Pairs) {
            $g = New-Object Windows.Controls.Grid; $g.Margin = '0,2'
            foreach ($cw in '170', '*', '44') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = (New-Object Windows.GridLengthConverter).ConvertFromString($cw); $g.ColumnDefinitions.Add($cd) }
            $l = New-Object Windows.Controls.TextBlock; $l.Text = $p[0]; $l.TextTrimming = 'CharacterEllipsis'; $l.VerticalAlignment = 'Center'; $l.ToolTip = $p[0]
            $bar = New-Object Windows.Controls.Border; $bar.Height = 14; $bar.CornerRadius = 7; $bar.Background = Get-Brush 'Accent'; $bar.HorizontalAlignment = 'Left'
            $bar.Width = [Math]::Max(6, 360.0 * $p[1] / $max); $bar.Margin = '8,0'
            $n = New-Object Windows.Controls.TextBlock; $n.Text = [string]$p[1]; $n.Foreground = Get-Brush 'Soft'; $n.HorizontalAlignment = 'Right'; $n.VerticalAlignment = 'Center'
            [Windows.Controls.Grid]::SetColumn($bar, 1); [Windows.Controls.Grid]::SetColumn($n, 2)
            foreach ($c in $l, $bar, $n) { [void]$g.Children.Add($c) }
            [void]$Panel.Children.Add($g)
        }
    }
    $top = {
        param($Values, [int]$Count = 10)
        @($Values | Where-Object { $_ } | Group-Object | Sort-Object @{ Expression = 'Count'; Descending = $true }, Name | Select-Object -First $Count | ForEach-Object { , @($_.Name, $_.Count) })
    }
    # The numbers
    $artists = @($all | Where-Object { ([string]$_.Artist).Trim() } | ForEach-Object { ([string]$_.Artist).Trim().ToLowerInvariant() } | Select-Object -Unique).Count
    $tracks = ($all | Measure-Object Tracks -Sum).Sum
    $discs = (@($all | ForEach-Object { [Math]::Max(1, [int]$_.Discs) }) | Measure-Object -Sum).Sum
    $mb = @($all | Where-Object { $_.FromMb }).Count
    $years = @($all | Where-Object { $_.Year -match '^\d{4}$' } | ForEach-Object { [int]$_.Year } | Sort-Object)
    $sp = & $card 'Your collection'
    $facts = [ordered]@{
        'CDs' = $all.Count; 'Artists' = $artists; 'Discs' = $discs; 'Tracks' = $tracks
        'Years' = $(if ($years.Count) { "$($years[0]) to $($years[-1])" } else { '' })
        'With a cover' = @($all | Where-Object { $_.Shown }).Count
        'Details from MusicBrainz' = $mb; 'Entered by hand' = $all.Count - $mb
        'With a place kept' = @($all | Where-Object { $_.Shelf }).Count
    }
    foreach ($k in $facts.Keys) {
        if ("$($facts[$k])" -eq '') { continue }
        $g = New-Object Windows.Controls.Grid; $g.Margin = '0,2'
        foreach ($cw in '200', '*') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = (New-Object Windows.GridLengthConverter).ConvertFromString($cw); $g.ColumnDefinitions.Add($cd) }
        $l = New-Object Windows.Controls.TextBlock; $l.Text = $k; $l.Foreground = Get-Brush 'Soft'
        $v = New-Object Windows.Controls.TextBlock; $v.Text = [string]$facts[$k]; $v.FontWeight = 'SemiBold'
        [Windows.Controls.Grid]::SetColumn($v, 1); [void]$g.Children.Add($l); [void]$g.Children.Add($v); [void]$sp.Children.Add($g)
    }
    # Decades
    if ($years.Count) {
        $sp = & $card 'By decade'
        & $bars $sp @($years | ForEach-Object { [int]([Math]::Floor($_ / 10) * 10) } | Group-Object | Sort-Object { [int]$_.Name } | ForEach-Object { , @("$($_.Name)s", $_.Count) })
    }
    $names = @{}; foreach ($i in $all) { $k = ([string]$i.Artist).Trim(); if ($k -and -not $names.ContainsKey($k.ToLowerInvariant())) { $names[$k.ToLowerInvariant()] = $k } }
    $a = & $top @($all | ForEach-Object { ([string]$_.Artist).Trim().ToLowerInvariant() } | Where-Object { $_ })
    if ($a.Count) { $sp = & $card 'Artists you have most of'; & $bars $sp @($a | ForEach-Object { , @($names[$_[0]], $_[1]) }) }
    $l = & $top @($all | ForEach-Object { ([string]$_.Label).Trim() })
    if ($l.Count) { $sp = & $card 'Top labels'; & $bars $sp $l }
    $gs = & $top @($all | ForEach-Object { ([string]$_.Genre) -split '\s*,\s*' } | ForEach-Object { (Get-Culture).TextInfo.ToTitleCase($_.Trim().ToLowerInvariant()) })
    if ($gs.Count) { $sp = & $card 'Top genres'; & $bars $sp $gs }
    $sh = & $top @($all | ForEach-Object { ([string]$_.Shelf).Trim() }) 20
    if ($sh.Count) { $sp = & $card 'Where they are kept'; & $bars $sp $sh }
    $w.FindName('SClose').Add_Click({ $w.Close() })
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------------------
#  Track lists, for searching by song: fetched from MusicBrainz in the
#  background, one CD a second, after the disc photos, and kept in Tracks\.
# ---------------------------------------------------------------------------
$script:TrackScan = {
    param([string]$Mbid, [string]$Agent)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    for ($try = 0; $try -lt 2; $try++) {
        Start-Sleep -Milliseconds (1100 + 2000 * $try)   # MusicBrainz asks for one request a second
        try {
            $r = Invoke-RestMethod -Uri "https://musicbrainz.org/ws/2/release/$($Mbid)?inc=recordings&fmt=json" -UserAgent $Agent -TimeoutSec 20
            return ((@($r.media) | ForEach-Object { @($_.tracks) | ForEach-Object { [string]$_.title } }) -join "`n") + "`n"
        } catch {
            $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 }
            if ($code -eq 404 -or $code -eq 400) { return "`n" }   # gone from MusicBrainz: nothing to search
        }
    }
    return $null
}
$script:TrackJob = $null
$script:GapsOpen = $false
$script:TrackTried = New-Object 'Collections.Generic.HashSet[string]'

function Step-Tracks {
    $job = $script:TrackJob
    if ($job) {
        if (-not $job.Handle.IsCompleted) { return }
        $out = $null
        try { $out = @($job.PS.EndInvoke($job.Handle)) | Select-Object -Last 1 } catch { Write-AppLog "Track list: $($_.Exception.Message)" }
        $job.PS.Dispose(); $script:TrackJob = $null
        if ($null -ne $out -and $job.Item.Mbid -eq $job.Mbid) {
            if (-not (Test-Path -LiteralPath $script:TrackDir)) { New-Item -ItemType Directory -Path $script:TrackDir -Force | Out-Null }
            [IO.File]::WriteAllText((Join-Path $script:TrackDir "$($job.Mbid).txt"), [string]$out, (New-Object Text.UTF8Encoding $false))
            $job.Item.TrackText = [string]$out
        }
        return
    }
    if ($script:Worker -or $script:DiscJob -or $script:GapsOpen) { return }   # look-ups, disc photos and What's missing? first
    $next = $null
    foreach ($i in $script:Items) {
        if ($i.FromMb -and $null -eq $i.TrackText -and -not $script:TrackTried.Contains($i.Mbid)) { $next = $i; break }
    }
    if (-not $next) { return }
    [void]$script:TrackTried.Add($next.Mbid)
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:TrackScan).AddArgument($next.Mbid).AddArgument($script:Agent)
    $script:TrackJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Item = $next; Mbid = $next.Mbid }
}

function Select-RandomCd {
    <# Pick for me: a CD at random from the ones shown, so a search narrows it down first. #>
    $shown = @([Windows.Data.CollectionViewSource]::GetDefaultView($script:Items))
    if (-not $shown.Count) { [void](Show-AppMessage $(if ($script:Items.Count) { 'No CDs match your search, so there is nothing to pick from.' } else { 'Add some CDs first.' })); return }
    $now = $script:UI.Grid.SelectedItem
    $pick = $shown | Get-Random
    if ($shown.Count -gt 1) { while ([object]::ReferenceEquals($pick, $now)) { $pick = $shown | Get-Random } }   # always a different one
    $script:UI.Grid.SelectedItem = $pick; $script:UI.Grid.ScrollIntoView($pick)
    if ($script:UI.Wall.IsVisible) { $script:UI.Wall.ScrollIntoView($pick) }
    Set-Status "How about $($pick.Artist) - $($pick.Title)$(if ($pick.Year) { " ($($pick.Year))" })$(if ($pick.Shelf) { ", $($pick.Shelf)" })? Press Pick for me again for another$(if ($shown.Count -lt $script:Items.Count) { " (picking from the $($shown.Count) your search shows)" })." 'Good'
}

# ---------------------------------------------------------------------------
#  What's missing? An artist's albums on MusicBrainz, and which of them you have.
# ---------------------------------------------------------------------------
$script:GapScan = {
    param([string[]]$Mbids, [string]$Agent)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    function Get-Mb([string]$Path) {
        for ($try = 0; $try -lt 3; $try++) {
            Start-Sleep -Milliseconds (1100 + 2000 * $try)
            try { return Invoke-RestMethod -Uri "https://musicbrainz.org/ws/2/$Path" -UserAgent $Agent -TimeoutSec 20 }
            catch {
                $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 }
                if ($try -eq 2 -or $code -eq 400 -or $code -eq 404) { throw }   # only "busy" is worth asking again
            }
        }
    }
    try {
        Start-Sleep -Milliseconds 1500   # let a background track or disc look-up finish first
        $owned = @{}; $artist = $null
        foreach ($m in @($Mbids | Select-Object -First 40)) {
            # Each of your CDs: which album it is (and, from the first that answers, who the artist is).
            try { $x = Get-Mb "release/$($m)?inc=artist-credits+release-groups&fmt=json" } catch { continue }   # a CD MusicBrainz no longer has
            if ($x.'release-group'.id) { $owned[[string]$x.'release-group'.id] = $true }
            if (-not $artist) { $artist = @($x.'artist-credit')[0].artist }
        }
        if (-not $artist) { throw "MusicBrainz didn't answer for any of these CDs" }
        $all = @(); $offset = 0
        do {
            $page = Get-Mb "release-group?artist=$($artist.id)&type=album&limit=100&offset=$offset&fmt=json"
            $all += @($page.'release-groups'); $offset += 100
        } while ($offset -lt [int]$page.'release-group-count' -and $offset -lt 500)
        $albums = @($all | Where-Object { $_.'primary-type' -eq 'Album' -and -not @($_.'secondary-types').Count } | ForEach-Object {
            @{ Id = [string]$_.id; Title = [string]$_.title; Date = [string]$_.'first-release-date'; Have = $owned.ContainsKey([string]$_.id) } })
        return @{ Artist = [string]$artist.name; ArtistId = [string]$artist.id; Albums = $albums }
    } catch { return @{ Error = $_.Exception.Message } }
}

function Show-Gaps {
    <# The selected artist's studio albums on MusicBrainz, with the ones you have marked. #>
    $row = $script:UI.ArtistList.SelectedItem
    if (-not $row -or -not $row.Key -or $row.Key -eq '*') { return }
    $mine = @($script:Items | Where-Object { (Get-ArtistKey $_) -eq $row.Key })
    $ids = @($mine | Where-Object { $_.FromMb } | ForEach-Object { $_.Mbid } | Select-Object -Unique)
    if (-not $ids.Count) { [void](Show-AppMessage "None of your $($row.Name) CDs came from MusicBrainz, so their albums can't be looked up. Look one up (Edit, then Look up) and try again."); return }
    $norm = { param($t) ([string]$t).ToLowerInvariant() -replace '[^\p{L}\p{N}]', '' }
    $titles = @($mine | ForEach-Object { & $norm $_.Album })
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="640" Height="620" MinWidth="460" MinHeight="360" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Bahnschrift, Segoe UI" FontSize="13.5" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <DockPanel Margin="22,6,22,18">
    <TextBlock x:Name="GIntro" DockPanel.Dock="Top" TextWrapping="Wrap" LineHeight="20" Margin="0,0,0,12" Text="Looking at MusicBrainz... this takes a second or two for each of your CDs by them."/>
    <DockPanel DockPanel.Dock="Bottom" Margin="0,14,0,0">
      <Button x:Name="GClose" Content="Close" DockPanel.Dock="Right" MinWidth="80" Margin="0" IsCancel="True" IsDefault="True"/>
      <TextBlock Foreground="{Soft}" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,12,0"
                 Text="Studio albums only (no singles, live albums or compilations), as MusicBrainz lists them."/>
    </DockPanel>
    <ProgressBar x:Name="GWait" DockPanel.Dock="Top" Height="3" IsIndeterminate="True" Margin="0,0,0,10"/>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="GList"/></ScrollViewer>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    $w.Title = "What's missing? $($row.Name)"
    $script:GapsOpen = $true   # background look-ups wait, so MusicBrainz isn't asked twice a second
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:GapScan).AddArgument([string[]]$ids).AddArgument($script:Agent)
    $st = @{ PS = $ps; Handle = $ps.BeginInvoke(); Done = $false }
    $tick = New-Object Windows.Threading.DispatcherTimer
    $tick.Interval = [TimeSpan]::FromMilliseconds(300)
    $tick.Add_Tick({
        if ($st.Done -or -not $st.Handle.IsCompleted) { return }
        $st.Done = $true; $tick.Stop()
        $res = $null; try { $res = @($st.PS.EndInvoke($st.Handle)) | Select-Object -Last 1 } catch { $res = @{ Error = $_.Exception.Message } }
        $st.PS.Dispose()
        $w.FindName('GWait').Visibility = 'Collapsed'
        $intro = $w.FindName('GIntro'); $list = $w.FindName('GList')
        if (-not $res -or $res.Error) { $intro.Text = "Couldn't ask MusicBrainz just now$(if ($res.Error) { " ($($res.Error))" }). Try again in a minute."; return }
        $albums = @($res.Albums | ForEach-Object { if (-not $_.Have -and $titles -contains (& $norm $_.Title)) { $_.Have = $true }; $_ } | Sort-Object { if ($_.Date) { $_.Date } else { '9999' } })
        $have = @($albums | Where-Object { $_.Have }).Count
        $intro.Text = if ($albums.Count) { "MusicBrainz lists $($albums.Count) studio album$(if ($albums.Count -ne 1) { 's' }) by $($res.Artist). You have $have of them, so $($albums.Count - $have) $(if ($albums.Count - $have -eq 1) { 'is' } else { 'are' }) missing." } else { "MusicBrainz doesn't list any studio albums by $($res.Artist)." }
        foreach ($a in $albums) {
            $g = New-Object Windows.Controls.Grid; $g.Margin = '0,3'
            foreach ($cw in '56', '*', 'Auto', 'Auto') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = (New-Object Windows.GridLengthConverter).ConvertFromString($cw); $g.ColumnDefinitions.Add($cd) }
            $yr = New-Object Windows.Controls.TextBlock; $yr.Text = if ($a.Date) { $a.Date.Substring(0, [Math]::Min(4, $a.Date.Length)) } else { '' }; $yr.Foreground = Get-Brush 'Soft'; $yr.VerticalAlignment = 'Center'
            $tt = New-Object Windows.Controls.TextBlock; $tt.Text = $a.Title; $tt.TextTrimming = 'CharacterEllipsis'; $tt.VerticalAlignment = 'Center'; $tt.ToolTip = $a.Title
            if ($a.Have) { $tt.FontWeight = 'SemiBold' }
            $chip = New-Object Windows.Controls.Border; $chip.CornerRadius = 8; $chip.Padding = '8,1,8,2'; $chip.Margin = '10,0'; $chip.VerticalAlignment = 'Center'
            $ct = New-Object Windows.Controls.TextBlock; $ct.FontSize = 11.5; $ct.FontWeight = 'SemiBold'; $chip.Child = $ct
            if ($a.Have) { $chip.Background = Get-Brush 'Accent'; $ct.Foreground = Get-Brush 'AccentInk'; $ct.Text = 'You have it' }
            else { $chip.Background = Get-Brush 'Chip'; $ct.Foreground = Get-Brush 'Soft'; $ct.Text = 'Missing' }
            $pg = New-Object Windows.Controls.Button; $pg.Content = 'See on MusicBrainz'; $pg.Padding = '12,5'; $pg.Margin = '0'; $pg.Tag = $a.Id
            $pg.Add_Click({ Start-Process "https://musicbrainz.org/release-group/$($this.Tag)" })
            [Windows.Controls.Grid]::SetColumn($tt, 1); [Windows.Controls.Grid]::SetColumn($chip, 2); [Windows.Controls.Grid]::SetColumn($pg, 3)
            foreach ($c in $yr, $tt, $chip, $pg) { [void]$g.Children.Add($c) }
            [void]$list.Children.Add($g)
        }
    })
    $tick.Start()
    $w.FindName('GClose').Add_Click({ $w.Close() })
    $w.Add_Closed({ $script:GapsOpen = $false; $tick.Stop(); if (-not $st.Done) { try { $st.PS.Stop() } catch { Write-Verbose 'stopped' }; $st.PS.Dispose() } })
    [void]$w.ShowDialog()
}

# Scan several: barcodes are collected first, then looked up one after another.
$script:Batching = $false
$script:Batch = @()
function Update-BatchUi {
    $ui = $script:UI
    if ($script:Batching) {
        $ui.BtnBatch.Content = 'Cancel'
        $ui.BtnBatch.ToolTip = 'Stop scanning several and forget the barcodes on the list'
        $ui.BtnScan.Content = "Search ($($script:Batch.Count))"
        $ui.TxtScanNote.Text = if ($script:Batch.Count) { 'Scan the next CD, or press Search' } else { 'Scan the first CD' }
    } else {
        $ui.BtnBatch.Content = 'Scan several'
        $ui.BtnBatch.ToolTip = 'Scan a pile of CDs first, then press Search to look them all up, one after another'
        $ui.BtnScan.Content = 'Add CD'
        $ui.TxtScanNote.Text = 'Scan or type a barcode'
    }
}

function Switch-Batch {
    if (-not $script:Batching) {
        $script:Batching = $true; $script:Batch = @()
        Update-BatchUi
        Set-Status 'Scan several: scan each CD in turn. They wait on a list until you press Search (or press Enter in the empty box).'
    } else {
        if ($script:Batch.Count -and -not (Show-AppMessage "Forget the $($script:Batch.Count) barcode$(if ($script:Batch.Count -ne 1) { 's' }) you've scanned? Nothing has been looked up yet." -YesText 'Forget them' -NoText 'Keep scanning')) { return }
        $script:Batching = $false; $script:Batch = @()
        Update-BatchUi
        Set-Status 'Back to adding one CD at a time.'
    }
    $script:UI.TxtBarcode.Focus() | Out-Null
}

function Start-BatchSearch {
    if (-not $script:Batch.Count) { Set-Status 'Scan a CD first, then press Search.' 'Warn'; return }
    # Anything added or being looked up since it was scanned is left out.
    $have = @($script:Items | ForEach-Object { $_.Barcode }) + @($script:Pending)
    $list = @($script:Batch | Where-Object { $have -notcontains $_ })
    foreach ($bc in $list) { Send-Barcode $bc }
    $script:Batching = $false; $script:Batch = @()
    Update-BatchUi
    $secs = [math]::Ceiling($list.Count * 1.8)
    Set-Status "Looking up $($list.Count) CD$(if ($list.Count -ne 1) { 's' }) one after another (about $(if ($secs -lt 60) { "$secs seconds" } else { "$([math]::Ceiling($secs / 60)) minutes" })). Each appears in the list as it's found."
    $script:UI.TxtBarcode.Focus() | Out-Null
}

function Start-LookupAll {
    $todo = @($script:Items | Where-Object { $_.Album -and -not $_.Barcode -and ((-not $_.Year) -or (-not $_.Shown)) -and -not $_.Mbid })
    if (-not $todo.Count) { Set-Status 'Every CD added by hand has its details and cover (or was looked up already).'; return }
    $mins = [math]::Ceiling($todo.Count * 1.8 / 60)
    if (-not (Show-AppMessage "Look up $($todo.Count) CD$(if ($todo.Count -ne 1) { 's' }) added by hand in MusicBrainz, for the missing year, label, tracks and cover?`n`nIt takes about $mins minute$(if ($mins -ne 1) { 's' }) (MusicBrainz allows one look-up a second)." -YesText 'Look up' -NoText 'Cancel')) { return }
    foreach ($i in $todo) { Send-Lookup @{ Id = $i.Id; Artist = $i.Artist; Album = $i.Album; NeedCover = (-not $i.Shown) } }
    Set-Status "Looking up $($todo.Count) CDs..."
}

function Update-Worker {
    $w = $script:Worker
    if (-not $w) { return }
    $s = $w.Sync
    $new = @()
    [Threading.Monitor]::Enter($s.Items.SyncRoot)
    try { if ($s.Items.Count -gt $w.Taken) { $new = $s.Items.GetRange($w.Taken, $s.Items.Count - $w.Taken).ToArray(); $w.Taken = $s.Items.Count } }
    finally { [Threading.Monitor]::Exit($s.Items.SyncRoot) }
    foreach ($r in $new) {
        $j = $r.Job
        if ($j.Barcode) {
            $script:Pending = @($script:Pending | Where-Object { $_ -ne $j.Barcode })
            if ($r.Failed) {
                Write-AppLog "Barcode $($j.Barcode): $($r.Error)"
                if (-not $j.Retry) {
                    # MusicBrainz was busy: try it once more after the others.
                    $script:Pending += $j.Barcode
                    Send-Lookup @{ Barcode = $j.Barcode; Retry = $true }
                    Set-Status "MusicBrainz is busy: $($j.Barcode) will be tried again in a moment."
                } else { Set-Status "Couldn't look up $($j.Barcode) (MusicBrainz is busy). Scan it again later." 'Warn' }
                continue
            }
            $i = New-Object CdItem
            $i.Id = [guid]::NewGuid().ToString('N'); $i.Added = (Get-Date).ToString('s'); $i.Barcode = $j.Barcode
            if ($r.Found) {
                $i.Artist = $r.Artist; $i.Album = $r.Album; $i.Year = $r.Year; $i.Label = $r.Label; $i.Country = $r.Country
                $i.Tracks = [int]$r.Tracks; $i.Discs = [int]$r.Discs; $i.Cover = $r.Cover; $i.Mbid = $r.Mbid
                $w.Added++
                Set-Status "Added $($i.Artist) - $($i.Album)$(if ($i.Year) { " ($($i.Year))" })$(if ($r.Matches -gt 1) { ". MusicBrainz has $($r.Matches) versions of it: you'll be asked which is yours" })." 'Good'
                if ($r.Versions) { $script:Versions[$i.Id] = $r.Versions; $script:ToChoose += $i.Id }
            } else {
                $i.Mbid = '-'; $i.Notes = 'Barcode not found in MusicBrainz.'
                $w.Missing++
                Set-Status "$($j.Barcode) isn't in MusicBrainz. It's in the list as (not found): use Edit to type in the details." 'Warn'
            }
            $script:Items.Add($i)
            $script:UI.Grid.SelectedItem = $i; $script:UI.Grid.ScrollIntoView($i)
        } else {
            $i = @($script:Items | Where-Object { $_.Id -eq $j.Id }) | Select-Object -First 1
            if ($j.ReleaseId) {
                # Switched to the version you picked.
                if (-not $i) { continue }
                if ($r.Failed -or -not $r.Found) { Set-Status "Couldn't get that version from MusicBrainz just now. Try Choose the version again in a moment." 'Warn'; continue }
                $i.Artist = $r.Artist; $i.Album = $r.Album; $i.Year = $r.Year; $i.Label = $r.Label; $i.Country = $r.Country
                $i.Tracks = [int]$r.Tracks; $i.Discs = [int]$r.Discs; $i.Mbid = $r.Mbid
                if ($r.Cover) { $i.Cover = $r.Cover }
                Set-Status "Changed $($i.Artist) - $($i.Album) to the version you picked." 'Good'
                continue
            }
            if (-not $i -or $r.Failed) { continue }
            $i.Mbid = if ($r.Mbid) { $r.Mbid } else { '-' }
            if ($r.Year -and -not $i.Year) { $i.Year = $r.Year }
            if ($r.Label -and -not $i.Label) { $i.Label = $r.Label }
            if ($r.Tracks -and -not $i.Tracks) { $i.Tracks = [int]$r.Tracks }
            if ($r.Cover -and -not $i.Shown) { $i.Cover = $r.Cover }
            if ($r.Found) { $w.Filled++ }
        }
    }
    if ($new.Count) { Save-Catalogue; [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items).Refresh(); Update-Summary; Show-Details }
    if (-not $s.Finished) { return }
    try { $w.PS.EndInvoke($w.Handle) } catch { Write-AppLog "Look-up: $($_.Exception.Message)" }
    $w.PS.Dispose(); $script:Worker = $null
    $script:UI.Progress.Visibility = 'Hidden'
    if ($w.Filled) { Set-Status "Look-up finished: details found for $($w.Filled) CD$(if ($w.Filled -ne 1) { 's' })." }
    Write-AppLog "Look-ups done: $($w.Added) added, $($w.Missing) not found, $($w.Filled) filled in"
}

function Get-HtmlText([string]$Text) { return [Net.WebUtility]::HtmlEncode($Text) }

function Get-ThumbData([string]$Path, [int]$Size = 300) {
    <# A JPEG of the cover as a data: address, so the report is one file that works anywhere. 300 px, so
       hovering over a cover can show it big as well as small in the table. #>
    $img = Get-Picture $Path $Size
    if (-not $img) { return '' }
    try {
        $enc = New-Object Windows.Media.Imaging.JpegBitmapEncoder
        $enc.QualityLevel = 82
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($img))
        $ms = New-Object IO.MemoryStream
        $enc.Save($ms)
        return 'data:image/jpeg;base64,' + [Convert]::ToBase64String($ms.ToArray())
    } catch { return '' }
}

function Get-HtmlCard([CdItem]$Item) {
    <# The card shown when you hover over an album in the report: its details, and the track listing
       when More about the CD and artist has been opened for it (kept in Info\; nothing is looked up here). #>
    $h = { param($t) [Net.WebUtility]::HtmlEncode([string]$t) }
    $facts = [ordered]@{
        'Year' = $Item.Year; 'Label' = $Item.Label; 'Country' = $(if ($Item.Country) { Get-CountryName $Item.Country })
        'Genre' = $Item.Genre
        'Tracks' = $(if ($Item.Tracks) { "$($Item.Tracks)$(if ($Item.Discs -gt 1) { " on $($Item.Discs) discs" })" })
        'Barcode' = $Item.Barcode; 'Kept' = $Item.Shelf; 'Details from' = $(if ($Item.FromMb) { 'MusicBrainz' } else { 'entered by hand' }); 'Notes' = $Item.Notes
    }
    $info = $null
    if ($Item.FromMb) {
        $cache = Join-Path (Join-Path $script:DataDir 'Info') "$($Item.Mbid).json"
        if (Test-Path -LiteralPath $cache) { try { $info = Get-Content -LiteralPath $cache -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $info = $null } }
    }
    if ($info -and $info.Cd) {
        if ($info.Cd.First -and $info.Cd.First -ne $info.Cd.Date) { $facts['First out'] = Format-InfoDate ([string]$info.Cd.First) }
        if (@($info.Cd.Labels).Count) { $facts['Label'] = (@($info.Cd.Labels) -join ', ') }
    }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<b>$(& $h $Item.Title)</b><i>$(& $h $Item.Artist)</i><dl>")
    foreach ($k in $facts.Keys) { if ($facts[$k]) { [void]$sb.Append("<dt>$k</dt><dd>$(& $h $facts[$k])</dd>") } }
    [void]$sb.Append('</dl>')
    if ($info -and $info.Cd -and @($info.Cd.Discs).Count) {
        $discs = @($info.Cd.Discs)
        [void]$sb.Append('<ol>')
        $d = 0
        foreach ($disc in $discs) {
            $d++
            if ($discs.Count -gt 1) { [void]$sb.Append("<li class=""dh"">Disc $d$(if ($disc.Name) { ': ' + (& $h $disc.Name) })</li>") }
            foreach ($t in @($disc.Tracks)) { [void]$sb.Append("<li><span>$(& $h $t.No)</span>$(& $h $t.Title)<em>$(& $h $t.Length)</em></li>") }
        }
        [void]$sb.Append('</ol>')
    }
    return $sb.ToString()
}

function Export-Html([string]$Path, [array]$Rows, [string]$GroupBy) {
    $artists = @($Rows | Where-Object Artist | Select-Object -ExpandProperty Artist -Unique).Count
    $sb = New-Object Text.StringBuilder
    $group = $null
    foreach ($i in $Rows) {
        if ($GroupBy) {
            # A heading row for each artist (or place): its name, how many CDs and the years.
            $keyOf = if ($GroupBy -eq 'Place') { { ([string]$args[0].Shelf).Trim().ToLowerInvariant() } } else { { ([string]$args[0].Artist).Trim().ToLowerInvariant() } }
            $k = & $keyOf $i
            if ($k -ne $group) {
                $group = $k
                $theirs = @($Rows | Where-Object { (& $keyOf $_) -eq $k })
                $ys = @($theirs | ForEach-Object { $_.Year } | Where-Object { $_ -match '^\d{4}$' } | Sort-Object)
                $span = if (-not $ys.Count) { '' } elseif ($ys[0] -eq $ys[-1]) { "  ·  $($ys[0])" } else { "  ·  $($ys[0]) to $($ys[-1])" }
                $name = if ($GroupBy -eq 'Place') { if ($k) { Get-HtmlText ([string]$i.Shelf).Trim() } else { 'Place not set' } }
                        elseif ($k) { Get-HtmlText ([string]$i.Artist).Trim() } else { '(no artist)' }
                [void]$sb.AppendLine("<tr class=""grp""><td colspan=""12""><b>$name</b><span>$($theirs.Count) CD$(if ($theirs.Count -ne 1) { 's' })$span</span></td></tr>")
            }
        }
        $thumb = Get-ThumbData $i.Shown
        $cover = if ($thumb) { "<img src=""$thumb"" alt="""">" } else { '<span class="none"></span>' }
        $mb = if ($i.Mbid -and $i.Mbid -ne '-') { "<a href=""https://musicbrainz.org/release/$($i.Mbid)"">$(Get-HtmlText $i.Title)</a>" } else { Get-HtmlText $i.Title }
        $tracks = if ($i.Tracks) { [string]$i.Tracks + $(if ($i.Discs -gt 1) { " ($($i.Discs) discs)" }) } else { '' }
        [void]$sb.AppendLine("<tr><td class=""c"">$cover</td><td>$(Get-HtmlText $i.Artist)</td><td class=""al"">$mb<div class=""card"">$(Get-HtmlCard $i)</div></td><td>$(Get-HtmlText $i.Year)</td><td>$(Get-HtmlText $i.Label)</td><td>$(Get-HtmlText $i.Country)</td><td>$(Get-HtmlText $i.Genre)</td><td class=""n"">$tracks</td><td class=""bc"">$(Get-HtmlText $i.Barcode)</td><td class=""nt"">$(Get-HtmlText $i.Notes)</td><td>$(Get-HtmlText $i.Shelf)</td><td>$(if ($i.FromMb) { '<span class=""k mb"">MB</span>' } else { '<span class=""k hand"">Hand</span>' })</td></tr>")
    }
    $title = "CD catalogue, $((Get-Date).ToString('d MMMM yyyy'))"
    $html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>
:root { --page:#F3F5F8; --card:#FFFFFF; --line:#D7DCE3; --ink:#1E2530; --soft:#5E6875; --accent:#1F6FBF; }
@media (prefers-color-scheme: dark) { :root { --page:#16191E; --card:#1F242B; --line:#343B45; --ink:#E6E9EE; --soft:#9AA3AE; --accent:#4C9BE8; } }
body { margin:0; padding:24px; background:var(--page); color:var(--ink); font:14px/1.4 "Segoe UI", system-ui, sans-serif; }
h1 { font-size:22px; margin:0 0 4px; } .sum { color:var(--soft); margin:0 0 16px; }
input { font:inherit; padding:7px 10px; width:min(360px, 100%); border:1px solid var(--line); border-radius:6px; background:var(--card); color:var(--ink); margin-bottom:12px; }
table { width:100%; border-collapse:collapse; background:var(--card); border:1px solid var(--line); border-radius:8px; overflow:hidden; }
th { text-align:left; color:var(--soft); font-weight:600; padding:9px 10px; border-bottom:1px solid var(--line); cursor:pointer; white-space:nowrap; user-select:none; }
td { padding:6px 10px; border-bottom:1px solid var(--line); vertical-align:middle; }
tr:last-child td { border-bottom:0; }
td.c { width:52px; } td.c img, td.c .none { width:44px; height:44px; object-fit:cover; border-radius:3px; display:block; background:var(--page); }
td.al { font-weight:600; } td.n, td.bc { white-space:nowrap; } td.nt { color:var(--soft); }
a { color:var(--accent); text-decoration:none; } a:hover { text-decoration:underline; }
.foot { color:var(--soft); margin-top:12px; font-size:12px; }
tr.grp td { background:var(--page); padding:14px 10px 6px; border-bottom:1px solid var(--line); } tr.grp b { font-size:16px; } tr.grp span { color:var(--soft); margin-left:10px; }
table.byartist th { cursor:default; }
td .card { display:none; }
#card { position:fixed; width:340px; max-height:80vh; overflow:hidden; background:var(--card); color:var(--ink); border:1px solid var(--line); border-radius:12px;
  box-shadow:0 10px 32px rgba(0,0,0,.3); padding:14px 16px; display:none; pointer-events:none; z-index:10; font-weight:400; }
#card img { float:left; width:84px; height:84px; object-fit:cover; border-radius:6px; margin:0 12px 8px 0; }
#card b { display:block; font-size:16px; } #card i { display:block; font-style:normal; color:var(--accent); margin-bottom:8px; }
#card dl { clear:both; display:grid; grid-template-columns:auto 1fr; gap:2px 12px; margin:0; } #card dt { color:var(--soft); } #card dd { margin:0; }
#card ol { list-style:none; margin:10px 0 0; padding:8px 0 0; border-top:1px solid var(--line); columns:1; font-size:13px; }
#card li { display:flex; gap:8px; } #card li span { color:var(--soft); min-width:18px; } #card li em { margin-left:auto; font-style:normal; color:var(--soft); }
#card li.dh { font-weight:600; margin-top:4px; }
#big { position:fixed; width:300px; height:300px; object-fit:cover; border-radius:10px; box-shadow:0 10px 32px rgba(0,0,0,.35); background:var(--card); display:none; pointer-events:none; z-index:9; }
td.c img { cursor:zoom-in; }
.k { display:inline-block; padding:1px 7px 2px; border-radius:8px; font-size:11px; font-weight:600; } .k.mb { background:#0C6663; color:#FFFFFF; } .k.hand { background:#F4B740; color:#2A2210; }
@media print { tr.grp { break-after:avoid; } tr.grp td { background:#eee; }
  body { padding:0; background:#fff; color:#000; } input, #big, #card { display:none !important; } table { border:0; } tr { break-inside:avoid; } }
</style></head><body>
<h1>$(Get-HtmlText $title)</h1>
<p class="sum">$($Rows.Count) CD$(if ($Rows.Count -ne 1) { 's' }) by $artists artist$(if ($artists -ne 1) { 's' })$(if ($GroupBy) { ', by ' + $GroupBy.ToLower() })</p>
<input id="q" type="search" placeholder="Search" aria-label="Search">
<table id="t"$(if ($GroupBy) { ' class="byartist"' })><thead><tr><th></th><th>Artist</th><th>Album</th><th>Year</th><th>Label</th><th>Country</th><th>Genre</th><th>Tracks</th><th>Barcode</th><th>Notes</th><th>Kept</th><th>From</th></tr></thead>
<tbody>
$($sb.ToString())</tbody></table>
<p class="foot">Made by CD Catalogue v$script:AppVersion. Details from MusicBrainz, covers from the Cover Art Archive.</p>
<script>
// Hovering over a cover shows it big beside the pointer.
var big = document.createElement('img'); big.id = 'big'; big.alt = ''; document.body.appendChild(big);
function placeBig(e) {
  var x = e.clientX + 20, y = e.clientY - 150;
  if (x + 310 > window.innerWidth) x = e.clientX - 320;
  big.style.left = Math.max(8, x) + 'px'; big.style.top = Math.max(8, Math.min(y, window.innerHeight - 310)) + 'px';
}
var tb = document.querySelector('#t tbody');
// Hovering over an album shows a card with its details (and tracks, when known).
var card = document.createElement('div'); card.id = 'card'; document.body.appendChild(card);
function placeCard(e) {
  var w = card.offsetWidth, h = card.offsetHeight, x = e.clientX + 20, y = e.clientY - 40;
  if (x + w + 10 > window.innerWidth) x = e.clientX - w - 20;
  card.style.left = Math.max(8, x) + 'px'; card.style.top = Math.max(8, Math.min(y, window.innerHeight - h - 8)) + 'px';
}
function albumCell(el) { while (el && el !== tb) { if (el.tagName === 'TD') return el.className === 'al' ? el : null; el = el.parentNode; } return null; }
tb.addEventListener('mouseover', function (e) {
  var td = albumCell(e.target); if (!td) return;
  var img = td.parentNode.querySelector('td.c img');
  card.innerHTML = (img ? '<img src="' + img.src + '" alt="">' : '') + td.querySelector('.card').innerHTML;
  card.style.display = 'block'; placeCard(e);
});
tb.addEventListener('mousemove', function (e) { if (card.style.display === 'block') { if (albumCell(e.target)) placeCard(e); else card.style.display = 'none'; } });
tb.addEventListener('mouseleave', function () { card.style.display = 'none'; big.style.display = 'none'; });
tb.addEventListener('mouseover', function (e) { if (e.target.tagName === 'IMG' && e.target.parentNode.className === 'c') { big.src = e.target.src; big.style.display = 'block'; placeBig(e); } });
tb.addEventListener('mousemove', function (e) { if (big.style.display === 'block') placeBig(e); });
tb.addEventListener('mouseout', function (e) { if (e.target.tagName === 'IMG') big.style.display = 'none'; });
var q = document.getElementById('q'), rows = Array.prototype.slice.call(document.querySelectorAll('#t tbody tr:not(.grp)'));
var grps = Array.prototype.slice.call(document.querySelectorAll('#t tbody tr.grp'));
function shownText(r) { var c = r.cloneNode(true); c.querySelectorAll('.card').forEach(function (x) { x.remove(); }); return c.textContent.toLowerCase(); }
rows.forEach(function (r) { r.dataset.find = shownText(r); });
q.addEventListener('input', function () {
  var s = q.value.toLowerCase(); rows.forEach(function (r) { r.style.display = r.dataset.find.indexOf(s) >= 0 ? '' : 'none'; });
  // By artist: an artist's heading shows while any of their CDs does.
  grps.forEach(function (g) { var n = g.nextElementSibling, any = false; while (n && !n.classList.contains('grp')) { if (n.style.display !== 'none') any = true; n = n.nextElementSibling; } g.style.display = any ? '' : 'none'; });
});
document.querySelectorAll('#t th').forEach(function (th, n) {
  if (!n || grps.length) return;   // a report by artist stays in artist order
  th.addEventListener('click', function () {
    var up = th.dataset.up !== '1'; th.dataset.up = up ? '1' : '0';
    var b = document.querySelector('#t tbody');
    rows.sort(function (x, y) { var a = x.cells[n].textContent, c = y.cells[n].textContent; return (up ? 1 : -1) * a.localeCompare(c, undefined, { numeric: true, sensitivity: 'base' }); });
    rows.forEach(function (r) { b.appendChild(r); });
  });
});
</script>
</body></html>
"@
    [IO.File]::WriteAllText($Path, $html, (New-Object Text.UTF8Encoding $false))
}

function Get-ExcelText([string]$Text, [switch]$Always) {
    <# A CSV value that Excel opens as typed. Left to itself it makes a barcode 5.02E+12, 007 a 7 and 3/4 a date, and
       runs text starting = + or - as a formula. ="..." is read as text. Excel allows 255 characters in one piece. #>
    if (-not $Text) { return '' }
    if (-not $Always -and $Text -notmatch '\d|^[\s=+\-@#]|^(true|false)$') { return $Text }
    if ($Text.Length -gt 7000) { return " $Text" }   # past Excel's limit for a formula: the space keeps it text
    $parts = for ($i = 0; $i -lt $Text.Length; $i += 255) { '"' + $Text.Substring($i, [math]::Min(255, $Text.Length - $i)).Replace('"', '""') + '"' }
    return '=' + (@($parts) -join '&')
}

function Export-List([ValidateSet('Csv', 'Html')][string]$Kind) {
    $rows = @([Windows.Data.CollectionViewSource]::GetDefaultView($script:Items))
    if (-not $rows.Count) {
        [void](Show-AppMessage $(if ($script:Items.Count) { 'No CDs match your search. Clear it to export them all.' } else { 'There are no CDs to export yet. Scan a barcode or use Add by hand first.' }))
        return
    }
    $what = if ($Kind -eq 'Csv') { 'the CSV file' } else { 'the report' }
    $how = Show-AppChoice ("Save $what with the CDs as listed (in the same order as the list), by artist (each artist's CDs together, oldest first), " +
        "or by place (where they're kept, each place's CDs by artist: a list to print and keep with them)?") 'As listed' 'By artist' $(if ($Kind -eq 'Csv') { 'Export CSV' } else { 'HTML report' }) 'By place'
    if (-not $how) { return }
    $group = @('', 'Artist', 'Place')[$how - 1]
    $byYear = @{ Expression = { if ($_.Year -match '^\d{4}$') { $_.Year } else { '9999' } } }
    if ($group -eq 'Artist') { $rows = @($rows | Sort-Object NoArtist, ArtistSort, $byYear, Album) }
    if ($group -eq 'Place') { $rows = @($rows | Sort-Object @{ Expression = { [int](-not $_.Shelf) } }, @{ Expression = { ([string]$_.Shelf).ToLowerInvariant() } }, NoArtist, ArtistSort, $byYear, Album) }
    $ext = $Kind.ToLower()
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = if ($Kind -eq 'Csv') { 'CSV file for Excel (*.csv)|*.csv' } else { 'HTML report (*.html)|*.html' }
    $dlg.DefaultExt = ".$ext"
    $dlg.AddExtension = $true
    $dlg.FileName = "CD catalogue$(if ($group) { ' by ' + $group.ToLower() }) $((Get-Date).ToString('yyyy-MM-dd')).$ext"
    if (-not $dlg.ShowDialog($script:Window)) { return }
    if ($Kind -eq 'Html') {
        $script:Window.Cursor = 'Wait'
        try { Export-Html $dlg.FileName $rows -GroupBy $group } finally { $script:Window.Cursor = $null }
        Set-Status "Saved the report of $($rows.Count) CD$(if ($rows.Count -ne 1) { 's' }): $($dlg.FileName)" 'Good'
        if (Show-AppMessage "Saved the report of $($rows.Count) CD$(if ($rows.Count -ne 1) { 's' }).`n`nOpen it now?" -YesText 'Open' -NoText 'Close') { Start-Process $dlg.FileName }
    } else {
        $rows | Select-Object @{ n = 'Artist'; e = { Get-ExcelText $_.Artist } }, @{ n = 'Album'; e = { Get-ExcelText $_.Album } },
            @{ n = 'Year'; e = { if ($_.Year -match '^[1-9]\d{3}$') { $_.Year } else { Get-ExcelText $_.Year } } },
            @{ n = 'Label'; e = { Get-ExcelText $_.Label } }, @{ n = 'Country'; e = { Get-ExcelText $_.Country } }, @{ n = 'Genre'; e = { Get-ExcelText $_.Genre } },
            Tracks, Discs, @{ n = 'Barcode'; e = { Get-ExcelText $_.Barcode -Always } }, @{ n = 'Notes'; e = { Get-ExcelText $_.Notes } }, @{ n = 'Kept'; e = { Get-ExcelText $_.Shelf } }, @{ n = 'Details from'; e = { $_.Source } }, @{ n = 'MusicBrainz'; e = { if ($_.Mbid -and $_.Mbid -ne '-') { "https://musicbrainz.org/release/$($_.Mbid)" } } } |
            Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
        Set-Status "Saved $($rows.Count) CD$(if ($rows.Count -ne 1) { 's' }) to $($dlg.FileName)" 'Good'
    }
}

$script:Agent = "CD Catalogue/$script:AppVersion ( $script:RepoUrl )"

try {
    $window = New-XamlWindow $mainXaml
    $script:Window = $window
    # Opens big, to show as many CDs as the screen holds: the size you left it at, else most of the
    # screen. A window that was maximised opens maximised again.
    $area = [Windows.SystemParameters]::WorkArea
    $ww = 0.0; $wh = 0.0
    [void][double]::TryParse([string]$script:Settings.WinWidth, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$ww)
    [void][double]::TryParse([string]$script:Settings.WinHeight, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$wh)
    if ($ww -lt $window.MinWidth -or $wh -lt $window.MinHeight) { $ww = $area.Width * 0.92; $wh = $area.Height * 0.92 }
    $window.Width = [math]::Max($window.MinWidth, [math]::Min($ww, $area.Width))
    $window.Height = [math]::Max($window.MinHeight, [math]::Min($wh, $area.Height))
    if ($script:Settings.WinState -eq 'Maximized') { $window.Add_SourceInitialized({ $this.WindowState = 'Maximized' }) }
    $window.Title = "$script:AppName v$script:AppVersion"
    $icon = Get-AssetImage 'CD-Catalogue.ico'
    if ($icon) { $window.Icon = $icon }
    $ui = @{}
    foreach ($n in 'BtnCsv', 'BtnReport', 'BtnPick', 'BtnStats', 'BtnBackup', 'BtnCollection', 'BtnLook', 'BtnHelp', 'BtnAbout', 'TxtStatus', 'Progress', 'TxtSearch', 'TxtHint', 'BtnField', 'Key', 'KeyMb', 'KeyHand', 'KeyMbText', 'KeyHandText', 'BtnLookup', 'BtnAdd', 'TxtSummary', 'TxtTotals',
                   'TxtBarcode', 'BtnScan', 'BtnBatch', 'TxtScanNote', 'Grid', 'BtnEdit', 'BtnRemove', 'BtnMb', 'BtnInfo', 'BtnVersions', 'DNoCover', 'DCover', 'DDisc', 'DHub', 'DHole', 'DAlbum', 'DArtist', 'DMeta', 'DNotes',
                   'ViewCovers', 'ViewList', 'ViewArtists', 'Wall', 'ListCard', 'ArtistCard', 'ArtistList', 'ArtCount', 'ArtName', 'ArtMeta', 'Disco', 'BtnGaps',
                   'Empty', 'EmptyTitle', 'EmptyText', 'Details') { $ui[$n] = $window.FindName($n) }
    # The wall's panel is the app's own type, so it's set here rather than in the XAML.
    $ui.Wall.ItemsPanel = New-Object Windows.Controls.ItemsPanelTemplate (New-Object Windows.FrameworkElementFactory ([CdWallPanel]))
    $ui.Disco.ItemsPanel = New-Object Windows.Controls.ItemsPanelTemplate (New-Object Windows.FrameworkElementFactory ([CdWallPanel]))
    $script:UI = $ui
    $setLook = { $ui.BtnLook.Content = switch ($script:Settings.Look) { 'Dark' { 'Look: Dark' } 'System' { 'Look: Auto' } default { 'Look: Light' } } }
    & $setLook
    $ui.BtnLook.ToolTip = 'Light, dark, or the same as Windows. Used the next time the app starts.'
    $ui.BtnLook.Add_Click({
        $script:Settings.Look = switch ($script:Settings.Look) { 'Light' { 'Dark' } 'Dark' { 'System' } default { 'Light' } }
        Save-AppSetting; & $setLook
        Set-Status 'Look saved. It is used the next time the app starts.'
    })
    $ui.BtnHelp.Add_Click({ Show-Help })
    $ui.BtnAbout.Add_Click({ Show-About -Owner $window })
    # A barcode scanner types the digits and presses Enter.
    $ui.TxtBarcode.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Invoke-Safely { Add-Barcode }; $e.Handled = $true } })
    # In Scan several the button is Search: a barcode still in the box goes on the list first.
    $ui.BtnScan.Add_Click({ Invoke-Safely { if ($script:Batching -and $ui.TxtBarcode.Text.Trim()) { Add-Barcode }; if ($script:Batching) { Start-BatchSearch } else { Add-Barcode } } })
    $ui.BtnBatch.Add_Click({ Invoke-Safely { Switch-Batch } })
    # Esc leaves Scan several (asking first if barcodes are waiting).
    $ui.TxtBarcode.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'Escape' -and $script:Batching) { Invoke-Safely { Switch-Batch }; $e.Handled = $true } })
    $ui.BtnLookup.Add_Click({ Invoke-Safely { Start-LookupAll } })
    $ui.BtnAdd.Add_Click({ Invoke-Safely { Edit-Cd $null } })
    $ui.BtnEdit.Add_Click({ Invoke-Safely { Edit-Cd $ui.Grid.SelectedItem } })
    $ui.Grid.Add_MouseDoubleClick({ Invoke-Safely { if ($ui.Grid.SelectedItem) { Edit-Cd $ui.Grid.SelectedItem } } })
    $ui.BtnRemove.Add_Click({
        Invoke-Safely {
            $i = $ui.Grid.SelectedItem
            if (-not $i) { return }
            if (-not (Show-AppMessage "Take $($i.Artist) - $($i.Title) off the list?" -YesText 'Remove' -NoText 'Cancel')) { return }
            [void]$script:Items.Remove($i)
            Save-Catalogue; Update-Summary; Set-Status "Removed $($i.Artist) - $($i.Title) from the list."
        }
    })
    $ui.BtnMb.Add_Click({
        Invoke-Safely {
            $i = $ui.Grid.SelectedItem
            if (-not $i) { return }
            if ($i.Mbid -and $i.Mbid -ne '-') { Start-Process "https://musicbrainz.org/release/$($i.Mbid)" }
            elseif ($i.Barcode) { Open-MbAddRelease $i }
        }
    })
    $ui.BtnCollection.Add_Click({ Invoke-Safely { Show-Collection } })
    $ui.BtnStats.Add_Click({ Invoke-Safely { Show-Stats } })
    $ui.BtnPick.Add_Click({ Invoke-Safely { Select-RandomCd } })
    $ui.BtnGaps.Add_Click({ Invoke-Safely { Show-Gaps } })
    $ui.BtnBackup.Add_Click({ Invoke-Safely { Show-Backup } })
    $ui.BtnInfo.Add_Click({ Invoke-Safely { Show-Info $ui.Grid.SelectedItem } })
    $ui.BtnVersions.Add_Click({ Invoke-Safely { if ($ui.Grid.SelectedItem) { Show-Versions $ui.Grid.SelectedItem } } })
    $ui.BtnCsv.Add_Click({ Invoke-Safely { Export-List -Kind Csv } })
    $ui.BtnReport.Add_Click({ Invoke-Safely { Export-List -Kind Html } })
    # The wall and the list share one selection; the list's is the one the rest of the app reads.
    $ui.Grid.Add_SelectionChanged({
        $sel = $ui.Grid.SelectedItem
        if (-not [object]::ReferenceEquals($ui.Wall.SelectedItem, $sel)) {
            $ui.Wall.SelectedItem = $sel
            if ($sel -and $ui.Wall.IsVisible) { $ui.Wall.ScrollIntoView($sel) }
        }
        # In Artists, a CD picked anywhere (a new scan, a search) shows its artist.
        if ($sel -and $script:Settings.View -eq 'Artists' -and -not $script:ArtistFilling) {
            if ($script:DiscoKey -ne '*' -and (Get-ArtistKey $sel) -ne $script:DiscoKey) {
                $row = @($script:ArtistRows | Where-Object { $_.Key -eq (Get-ArtistKey $sel) }) | Select-Object -First 1
                if ($row) { $ui.ArtistList.SelectedItem = $row; $ui.ArtistList.ScrollIntoView($row) }
            }
            if (-not [object]::ReferenceEquals($ui.Disco.SelectedItem, $sel)) { $ui.Disco.SelectedItem = $sel; if ($ui.Disco.IsVisible) { $ui.Disco.ScrollIntoView($sel) } }
        }
        Show-Details
    })
    $ui.Wall.Add_SelectionChanged({ if (-not [object]::ReferenceEquals($ui.Grid.SelectedItem, $ui.Wall.SelectedItem)) { $ui.Grid.SelectedItem = $ui.Wall.SelectedItem } })
    $ui.Disco.Add_SelectionChanged({ if ($ui.Disco.SelectedItem -and -not [object]::ReferenceEquals($ui.Grid.SelectedItem, $ui.Disco.SelectedItem)) { $ui.Grid.SelectedItem = $ui.Disco.SelectedItem } })
    $ui.ArtistList.Add_SelectionChanged({ if (-not $script:ArtistFilling -and $ui.ArtistList.SelectedItem) { Invoke-Safely { Show-Artist $ui.ArtistList.SelectedItem } } })
    $ui.Disco.Add_MouseDoubleClick({
        param($s, $e)
        if ($e.OriginalSource.DataContext -is [CdItem]) { $cd = $e.OriginalSource.DataContext; Invoke-Safely { Edit-Cd $cd } }
    })
    $ui.Wall.Add_MouseDoubleClick({
        param($s, $e)
        # Only a double-click on a cover, not on the scroll bar.
        if ($e.OriginalSource.DataContext -is [CdItem]) { $cd = $e.OriginalSource.DataContext; Invoke-Safely { Edit-Cd $cd } }
    })
    $setView = {
        param([string]$View)
        $script:Settings.View = $View
        if ($View -eq 'Artists') { $script:DiscoKey = $null }   # Artists always opens on All artists
        Save-AppSetting; Update-Shelf
        $sel = $ui.Grid.SelectedItem
        if ($sel) {
            $window.UpdateLayout()
            if ($View -eq 'List') { $ui.Grid.ScrollIntoView($sel) } elseif ($View -eq 'Covers') { $ui.Wall.ScrollIntoView($sel) }
        }
    }
    if ($script:Settings.View -eq 'List') { $ui.ViewList.IsChecked = $true }
    if ($script:Settings.View -eq 'Artists') { $ui.ViewArtists.IsChecked = $true }
    $ui.ViewCovers.Add_Checked({ & $setView 'Covers' })
    $ui.ViewList.Add_Checked({ & $setView 'List' })
    $ui.ViewArtists.Add_Checked({ & $setView 'Artists' })
    $ui.TxtBarcode.Add_TextChanged({ $ui.TxtScanNote.Visibility = if ($ui.TxtBarcode.Text) { 'Collapsed' } else { 'Visible' } })
    $ui.BtnField.Add_Click({ Invoke-Safely { Show-FieldMenu } })
    # The key: click a kind to show only those CDs, click it again to show all.
    $ui.KeyMb.Tag = 'source:mb'; $ui.KeyHand.Tag = 'source:hand'
    $keyClick = { $ui.TxtSearch.Text = if ($ui.TxtSearch.Text.Trim() -eq $this.Tag) { '' } else { $this.Tag }; Invoke-Safely { Update-View } }
    $ui.KeyMb.Add_Click($keyClick); $ui.KeyHand.Add_Click($keyClick)
    # The search runs a moment after you stop typing, so a big collection isn't searched at every letter.
    $searchWait = New-Object Windows.Threading.DispatcherTimer
    $searchWait.Interval = [TimeSpan]::FromMilliseconds(220)
    $searchWait.Add_Tick({ $this.Stop(); Invoke-Safely { Update-View } })
    $ui.TxtSearch.Add_TextChanged({ $ui.TxtHint.Visibility = if ($ui.TxtSearch.Text) { 'Collapsed' } else { 'Visible' }; $searchWait.Stop(); $searchWait.Start() })
    $ui.Grid.ItemsSource = $script:Items
    $ui.Wall.ItemsSource = $script:Items
    # Artists has its own view of the same CDs: one artist, oldest first, and the search.
    $script:DiscoKey = $null; $script:SearchTest = $null; $script:ArtistRows = @(); $script:ArtistFilling = $false
    $script:DiscoView = New-Object Windows.Data.ListCollectionView -ArgumentList (, $script:Items)
    foreach ($sd in @(@('Year', 'Ascending'), @('Album', 'Ascending'))) { $script:DiscoView.SortDescriptions.Add((New-Object ComponentModel.SortDescription $sd[0], $sd[1])) }
    $script:DiscoSet = $null; $script:ArtistGroups = $null
    # The artist's CDs that the search shows (worked out once in Update-Artists); a CD added since then counts too.
    $script:DiscoView.Filter = [Predicate[object]]{ param($i)
        if ($script:DiscoKey -eq '*') { return (-not $script:SearchTest -or (& $script:SearchTest $i)) }   # All artists
        if ($null -eq $script:DiscoSet) { return $false }
        if ($script:DiscoSet.Contains($i)) { return $true }
        return ([string]$i.Artist).Trim().ToLowerInvariant() -eq $script:DiscoKey -and (-not $script:SearchTest -or (& $script:SearchTest $i)) }
    $ui.Disco.ItemsSource = $script:DiscoView
    $sortView = [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items)
    foreach ($sd in @(@('Artist', 'Ascending'), @('Year', 'Ascending'), @('Album', 'Ascending'))) { $sortView.SortDescriptions.Add((New-Object ComponentModel.SortDescription $sd[0], $sd[1])) }
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({ try { Update-Worker; Step-Choose; Step-Disc; Step-Tracks } catch { Write-AppLog "Update: $($_.Exception.Message)" } })
    $window.Add_ContentRendered({
        Invoke-Safely {
            Read-Catalogue
            if ($script:Items.Count) { $ui.Grid.SelectedItem = @($sortView)[0] }
            Update-Summary
            Set-Status $(if ($script:Items.Count) { 'Scan a barcode to add a CD, or type in the search box to find one.' } else { 'Scan the barcode on the back of a CD to add it (or Add by hand for one with no barcode).' })
            $timer.Start()
            $ui.TxtBarcode.Focus() | Out-Null
        }
    })
    $window.Add_Closing({
        param($s, $e)
        if ($script:Batching -and $script:Batch.Count -and -not (Show-AppMessage "$($script:Batch.Count) scanned barcode$(if ($script:Batch.Count -ne 1) { 's have' } else { ' has' }) not been looked up yet. Close anyway?" -YesText 'Close' -NoText 'Keep scanning')) { $e.Cancel = $true; return }
        if ($script:Worker) { $script:Worker.Sync.Cancel = $true }
        # Remember the size for next time (the normal size when it's maximised).
        $b = if ($window.WindowState -eq 'Normal') { New-Object Windows.Rect $window.Left, $window.Top, $window.ActualWidth, $window.ActualHeight } else { $window.RestoreBounds }
        if ($b.Width -gt 0) {
            $script:Settings.WinWidth = $b.Width.ToString([Globalization.CultureInfo]::InvariantCulture)
            $script:Settings.WinHeight = $b.Height.ToString([Globalization.CultureInfo]::InvariantCulture)
        }
        $script:Settings.WinState = if ($window.WindowState -eq 'Maximized') { 'Maximized' } else { 'Normal' }
        Save-AppSetting
    })
    $window.Add_Closed({ $timer.Stop() })
    Write-AppLog "Started v$script:AppVersion from $script:ProgramDir"
    [void]$window.ShowDialog()
} catch {
    Write-AppLog "Error: $($_.Exception.Message)"
    [void][Windows.MessageBox]::Show("$script:AppName couldn't start:`n`n$($_.Exception.Message)`n`nDetails are in $script:LogPath", $script:AppName, 'OK', 'Error')
    exit 1
}
