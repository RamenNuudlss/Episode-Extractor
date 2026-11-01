<#
.SYNOPSIS
    Episode Extractor - unpack multi-part RAR episode releases and file them
    straight into a Plex TV library.

.NOTES
    Needs: Windows + .NET (built in). 7-Zip is found automatically.
    Run as a script:
        powershell -ExecutionPolicy Bypass -File .\Extractor-GUI.ps1
    ...or compile to Extractor.exe with Build-Exe.ps1.

    Optional branding: put app.ico (window + exe icon) and app.png / app.jpg
    (header image) next to the script/exe.

    https://github.com/RamenNuudlss/episode-extractor  (MIT license)

    UI is WPF (dark title bar, styled table, toggle switches, collapsible log).
    Detection, Plex naming and the extraction worker are unchanged.
#>

# WPF needs a single-threaded apartment. Windows PowerShell 5.1 already is;
# if something launched us MTA, relaunch the script the right way.
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    if ($PSCommandPath) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") -WindowStyle Hidden
        return
    }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ===========================================================================
# Paths / config
# ===========================================================================
function Get-ScriptDir {
    if ($PSScriptRoot -and -not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { return $PSScriptRoot }
    try {
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $leaf = [System.IO.Path]::GetFileName($exe)
        # When run as a script host (powershell.exe/pwsh.exe) fall back to cwd
        if ($leaf -match '(?i)^(powershell|pwsh)(\.exe)?$') { return (Get-Location).Path }
        return [System.IO.Path]::GetDirectoryName($exe)
    } catch { return (Get-Location).Path }
}
$script:ScriptDir = Get-ScriptDir

$script:ConfigDir  = Join-Path $env:APPDATA 'EpisodeExtractor'
$script:ConfigPath = Join-Path $script:ConfigDir 'config.json'

function Load-Config {
    $defaults = [ordered]@{
        LastFolder    = ''
        SevenZip      = ''
        DeleteAfter   = $true
        PreviewOnly   = $false
        OpenWhenDone  = $false
        PlexMode      = $false
        LibraryRoot   = ''
    }
    try {
        if (Test-Path -LiteralPath $script:ConfigPath) {
            $json = Get-Content -LiteralPath $script:ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($k in @($defaults.Keys)) {
                if ($json.PSObject.Properties.Name -contains $k -and $null -ne $json.$k) {
                    $defaults[$k] = $json.$k
                }
            }
        }
    } catch { }
    return $defaults
}

function Save-Config {
    param($Cfg)
    try {
        if (-not (Test-Path -LiteralPath $script:ConfigDir)) {
            New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        }
        ($Cfg | ConvertTo-Json) | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
    } catch { }
}

$script:Config = Load-Config

# ===========================================================================
# 7-Zip auto-detection
# ===========================================================================
function Find-SevenZip {
    $candidates = New-Object System.Collections.Generic.List[string]
    # A saved path wins if it still exists
    if (-not [string]::IsNullOrWhiteSpace($script:Config.SevenZip)) { $candidates.Add($script:Config.SevenZip) }
    # Portable copy sitting next to the script/exe
    $candidates.Add((Join-Path $script:ScriptDir '7z.exe'))
    $candidates.Add((Join-Path $script:ScriptDir 'tools\7z.exe'))
    $candidates.Add((Join-Path $script:ScriptDir '7-Zip\7z.exe'))
    # Standard install locations
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles '7-Zip\7z.exe')) }
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')) }
    if ($env:ProgramW6432) { $candidates.Add((Join-Path $env:ProgramW6432 '7-Zip\7z.exe')) }
    if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\7-Zip\7z.exe')) }
    # Registry (per-machine and per-user)
    foreach ($hive in @('HKLM:\SOFTWARE\7-Zip', 'HKCU:\SOFTWARE\7-Zip', 'HKLM:\SOFTWARE\WOW6432Node\7-Zip')) {
        try {
            $regPath = (Get-ItemProperty -Path $hive -Name 'Path' -ErrorAction SilentlyContinue).Path
            if ($regPath) { $candidates.Add((Join-Path $regPath '7z.exe')) }
        } catch { }
    }
    # On PATH (7z.exe, and the console build 7zr.exe as a last resort)
    foreach ($name in @('7z.exe', '7zr.exe')) {
        try {
            $onPath = (Get-Command $name -ErrorAction SilentlyContinue).Source
            if ($onPath) { $candidates.Add($onPath) }
        } catch { }
    }

    foreach ($c in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return ''
}

# ===========================================================================
# PLEX NAMING
# ---------------------------------------------------------------------------
# Turn a detected Title + episode Label into Plex library parts:
#   <show> / Season NN / <show> - sNNeMM[-eMM].<ext>
# Returns $null when there's no usable episode label (so the caller can fall
# back to plain extraction).
# ===========================================================================
function Get-PlexParts {
    param([string]$Title, [string]$Label)

    $show = Get-SafeFolderName -Name $Title
    if ([string]::IsNullOrWhiteSpace($show)) { $show = 'Unknown Show' }
    if ([string]::IsNullOrWhiteSpace($Label)) { return $null }

    # Date-based daily show: Season <year>, "Show - 2024-03-15"
    if ($Label -match '^(\d{4})-(\d{2})-(\d{2})$') {
        return [PSCustomObject]@{
            Show = $show; SeasonFolder = ("Season {0}" -f $matches[1])
            FileBase = ("{0} - {1}" -f $show, $Label)
        }
    }
    # Extras / specials -> Season 00
    if ($Label -match '^S(\d{1,2})\.Extras$') {
        return [PSCustomObject]@{
            Show = $show; SeasonFolder = 'Season 00'
            FileBase = ("{0} - s00 {1}" -f $show, ('Season {0} Extras' -f [int]$matches[1]))
        }
    }
    # Standard SxxEyy (with optional -Eyy range)
    if ($Label -match '^S(\d{1,2})E(\d{1,3})(?:-E(\d{1,3}))?$') {
        $s = [int]$matches[1]
        $tag = $Label.ToLower()
        return [PSCustomObject]@{
            Show = $show; SeasonFolder = ('Season {0:D2}' -f $s)
            FileBase = ("{0} - {1}" -f $show, $tag)
        }
    }
    # Episode only, no season -> assume Season 01
    if ($Label -match '^E(\d{1,3})$') {
        $tag = 's01' + $Label.ToLower()
        return [PSCustomObject]@{
            Show = $show; SeasonFolder = 'Season 01'
            FileBase = ("{0} - {1}" -f $show, $tag)
        }
    }
    return $null
}

# ===========================================================================
# DETECTION ENGINE
# ---------------------------------------------------------------------------
# Returns a PSCustomObject with .Title and .Label for a release base name.
# Strategy: try the strongly-structured patterns on the raw name first, then
# strip junk tokens and only then fall back to bare numbers.
# ===========================================================================

# Tokens that are definitely NOT episode numbers. Stripped before any
# bare-number guessing so resolutions / codecs / years don't get misread.
$script:JunkPattern = @(
    '(?<![a-z0-9])(?:480|540|576|720|1080|1440|2160|4320)[pi]?(?![a-z0-9])'  # resolutions
    '(?<![a-z0-9])(?:x|h)\.?26[45](?![a-z0-9])'                               # x264/x265/h264/h265
    '(?<![a-z0-9])(?:hevc|avc|av1|vp9|xvid|divx|mpeg2?)(?![a-z0-9])'          # codecs
    '(?<![a-z0-9])(?:8|10|12)bit(?![a-z0-9])'                                 # bit depth
    '(?<![a-z0-9])(?:[57]\.1)(?![a-z0-9])'                                    # 5.1 / 7.1
    '(?<![a-z0-9])(?:aac|ac3|eac3|dd5|ddp5|dts(?:hd)?|truehd|atmos|flac|opus|mp3)(?![a-z0-9])'
    '(?<![a-z0-9])(?:web-?dl|webrip|web|bluray|blu-ray|bdrip|brrip|bdremux|remux|hdtv|pdtv|dvdrip|dvd|hdrip|hdcam|cam| amzn|dsnp|nf|hmax|atvp|hulu)(?![a-z0-9])'
    '(?<![a-z0-9])(?:repack|proper|internal|limited|extended|uncut|readnfo|real)(?![a-z0-9])'
    '(?<![a-z0-9])(?:19|20)[0-9]{2}(?![a-z0-9])'                              # standalone year
) -join '|'

function Remove-JunkTokens {
    param([string]$Text)
    # work with separators as spaces so \b-style boundaries behave
    $t = $Text -replace '[._]', ' '
    $t = [regex]::Replace($t, "(?i)$($script:JunkPattern)", ' ')
    # drop a trailing release group after a dash ("... -GROUP")
    $t = [regex]::Replace($t, '\s-\s*[A-Za-z0-9]+\s*$', ' ')
    # collapse whitespace
    $t = ($t -replace '\s+', ' ').Trim(' ', '-')
    return $t
}

function Get-TitleFromName {
    param([string]$Name, [int]$CutAt = -1)
    $src = if ($CutAt -ge 0 -and $CutAt -le $Name.Length) { $Name.Substring(0, $CutAt) } else { $Name }
    $title = Remove-JunkTokens -Text $src
    $title = $title.Trim(' ', '-', '_', '.')
    if ([string]::IsNullOrWhiteSpace($title)) { return '' }
    # Title Case words that are all-lower (leave acronyms / mixed case alone)
    $ti = (Get-Culture).TextInfo
    $words = $title -split ' '
    for ($i = 0; $i -lt $words.Count; $i++) {
        if ($words[$i] -cmatch '^[a-z0-9]+$') { $words[$i] = $ti.ToTitleCase($words[$i]) }
    }
    return ($words -join ' ')
}

function Get-EpisodeInfo {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return [PSCustomObject]@{ Title = ''; Label = $null }
    }

    # ---- 1. Date-based dailies: 2024.03.15 / 2024-03-15 ----
    $mDate = [regex]::Match($Name, '(?<![0-9])((?:19|20)[0-9]{2})[.\-]([01]?[0-9])[.\-]([0-3]?[0-9])(?![0-9])')
    if ($mDate.Success) {
        $label = ('{0}-{1:D2}-{2:D2}' -f $mDate.Groups[1].Value, [int]$mDate.Groups[2].Value, [int]$mDate.Groups[3].Value)
        return [PSCustomObject]@{ Title = (Get-TitleFromName -Name $Name -CutAt $mDate.Index); Label = $label }
    }

    # ---- 2. SxxEyy (+ optional multi-episode range) ----
    #   s01e01, s1.e2, season 1 episode 2, s01e01e02, s01e01-e02
    $mSE = [regex]::Match($Name, '(?i)s(?:eason)?[.\-_ ]?([0-9]{1,2})[.\-_ ]?e(?:pisode)?[.\-_ ]?([0-9]{1,3})(?:[.\-_ ]?e[.\-_ ]?([0-9]{1,3}))?')
    if ($mSE.Success) {
        $s = [int]$mSE.Groups[1].Value
        $e1 = [int]$mSE.Groups[2].Value
        if ($mSE.Groups[3].Success) {
            $e2 = [int]$mSE.Groups[3].Value
            $label = ('S{0:D2}E{1:D2}-E{2:D2}' -f $s, $e1, $e2)
        } else {
            $label = ('S{0:D2}E{1:D2}' -f $s, $e1)
        }
        return [PSCustomObject]@{ Title = (Get-TitleFromName -Name $Name -CutAt $mSE.Index); Label = $label }
    }

    # ---- 3. 1x01 (+ optional range 1x01-02) ----
    $mX = [regex]::Match($Name, '(?<![0-9])([0-9]{1,2})x([0-9]{2})(?:-([0-9]{2}))?(?![0-9])')
    if ($mX.Success) {
        $s = [int]$mX.Groups[1].Value
        $e1 = [int]$mX.Groups[2].Value
        if ($mX.Groups[3].Success) {
            $label = ('S{0:D2}E{1:D2}-E{2:D2}' -f $s, $e1, [int]$mX.Groups[3].Value)
        } else {
            $label = ('S{0:D2}E{1:D2}' -f $s, $e1)
        }
        return [PSCustomObject]@{ Title = (Get-TitleFromName -Name $Name -CutAt $mX.Index); Label = $label }
    }

    # ---- 4. Season N / series N "Extras" ----
    $mExtras = [regex]::Match($Name, '(?i)(?:s(?:eason)?|series)[.\-_ ]?([0-9]{1,2}).*?extras')
    if ($mExtras.Success) {
        return [PSCustomObject]@{ Title = (Get-TitleFromName -Name $Name -CutAt $mExtras.Index); Label = ('S{0:D2}.Extras' -f [int]$mExtras.Groups[1].Value) }
    }

    # ---- 5. Bare "Episode 12" / "Ep 12" / "E12" (no season given) ----
    $mEp = [regex]::Match($Name, '(?i)(?<![a-z0-9])e(?:p(?:isode)?)?[.\-_ ]?([0-9]{1,3})(?![0-9])')
    if ($mEp.Success) {
        return [PSCustomObject]@{ Title = (Get-TitleFromName -Name $Name -CutAt $mEp.Index); Label = ('E{0:D2}' -f [int]$mEp.Groups[1].Value) }
    }

    # ---- 6. Bare-number fallback, but ONLY after stripping junk tokens ----
    $clean = Remove-JunkTokens -Text $Name
    # Bare numbers only count when they're the LAST token (no words after them),
    # so "Documentary 264 Days" isn't read as S02E64.
    # 4-digit SSEE  (e.g. "0102" -> S01E02); season 1..40, ep 1..99
    $m4 = [regex]::Match($clean, '(?<![0-9])([0-9]{4})(?![0-9])')
    if ($m4.Success -and -not [regex]::IsMatch($clean.Substring($m4.Index + $m4.Length), '[A-Za-z]')) {
        $d = $m4.Groups[1].Value
        $s = [int]$d.Substring(0,2); $e = [int]$d.Substring(2,2)
        if ($s -ge 1 -and $s -le 40 -and $e -ge 1 -and $e -le 99) {
            return [PSCustomObject]@{ Title = (Get-TitleFromName -Name $clean -CutAt $m4.Index); Label = ('S{0:D2}E{1:D2}' -f $s, $e) }
        }
    }
    # 3-digit SEE  (e.g. "102" -> S01E02); season 1..9, ep 1..99
    $m3 = [regex]::Match($clean, '(?<![0-9])([0-9]{3})(?![0-9])')
    if ($m3.Success -and -not [regex]::IsMatch($clean.Substring($m3.Index + $m3.Length), '[A-Za-z]')) {
        $d = $m3.Groups[1].Value
        $s = [int]$d.Substring(0,1); $e = [int]$d.Substring(1,2)
        if ($e -ge 1 -and $e -le 99) {
            return [PSCustomObject]@{ Title = (Get-TitleFromName -Name $clean -CutAt $m3.Index); Label = ('S{0:D2}E{1:D2}' -f $s, $e) }
        }
    }

    # Nothing matched - no episode label, title is the cleaned name
    return [PSCustomObject]@{ Title = (Get-TitleFromName -Name $Name); Label = $null }
}

function Get-SafeFolderName {
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $pattern = "[{0}]" -f [regex]::Escape($invalid)
    $safe = ($Name -replace $pattern, '_').Trim()
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'Extracted' }
    return $safe
}

function Get-PrimaryArchiveFile {
    param([System.Collections.Generic.List[System.IO.FileInfo]]$Files)
    $partFiles = $Files | Where-Object { $_.Name -match '(?i)\.part([0-9]+)\.rar$' }
    if ($partFiles) {
        return $partFiles | Sort-Object {
            [int]([regex]::Match($_.Name, '(?i)\.part([0-9]+)\.rar$').Groups[1].Value)
        } | Select-Object -First 1
    }
    return $Files | Where-Object { $_.Extension -ieq '.rar' } | Select-Object -First 1
}

# Derive a file's folder by string handling (FileInfo.DirectoryName can be
# null for >260 char paths).
function Get-DirOfFile {
    param($File)
    $full = [string]$File.FullName
    if ([string]::IsNullOrWhiteSpace($full)) { return $null }
    $idx = $full.LastIndexOf('\')
    if ($idx -lt 1) { return $null }
    return $full.Substring(0, $idx)
}

function Get-ArchiveSets {
    param([string]$RootPath)

    $result = [PSCustomObject]@{
        Sets     = New-Object System.Collections.Generic.List[psobject]
        Skipped  = 0
        Warnings = New-Object System.Collections.Generic.List[string]
    }

    $archiveFiles = Get-ChildItem -LiteralPath $RootPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '(\.part[0-9]+)?\.(rar|r[0-9]{2}|sfv|info)$'
    }
    if (-not $archiveFiles) { return $result }

    $groupMap = @{}
    foreach ($f in $archiveFiles) {
        $fDir = Get-DirOfFile -File $f
        if ([string]::IsNullOrWhiteSpace($fDir)) {
            $result.Warnings.Add("Could not determine folder for: $($f.Name)")
            continue
        }
        $base = $f.Name -replace '(\.part[0-9]+)?\.(rar|r[0-9]{2}|sfv|info)$', ''
        $key = $fDir + "::" + $base
        if (-not $groupMap.ContainsKey($key)) {
            $groupMap[$key] = [PSCustomObject]@{
                Dir      = $fDir
                BaseName = $base
                Files    = New-Object System.Collections.Generic.List[System.IO.FileInfo]
            }
        }
        $groupMap[$key].Files.Add($f)
    }

    foreach ($key in $groupMap.Keys) {
        $g = $groupMap[$key]
        try {
            $rarFile = Get-PrimaryArchiveFile -Files $g.Files
            if (-not $rarFile) { $result.Skipped++; continue }

            $info  = Get-EpisodeInfo -Name $g.BaseName
            $label = $info.Label
            if (-not $label) { $label = Get-SafeFolderName -Name $g.BaseName }
            $title = $info.Title
            if ([string]::IsNullOrWhiteSpace($title)) { $title = $g.BaseName }

            $parentLeaf  = $g.Dir.Substring($g.Dir.LastIndexOf('\') + 1)
            $parentInfo  = Get-EpisodeInfo -Name $parentLeaf

            $outFolder = $null
            if ($parentInfo.Label -and ($parentInfo.Label -ieq $label)) {
                $outFolder = $g.Dir
            } else {
                $outFolder = [System.IO.Path]::Combine([string]$g.Dir, (Get-SafeFolderName -Name $label))
            }
            if ([string]::IsNullOrWhiteSpace($outFolder)) {
                $outFolder = [System.IO.Path]::Combine([string]$g.Dir, (Get-SafeFolderName -Name $g.BaseName))
            }

            $result.Sets.Add([PSCustomObject]@{
                BaseName     = $g.BaseName
                Title        = [string]$title
                Dir          = $g.Dir
                Files        = $g.Files
                PrimaryFile  = $rarFile
                EpisodeLabel = [string]$label
                OutputFolder = [string]$outFolder
                PartCount    = $g.Files.Count
            })
        } catch {
            $result.Warnings.Add("Skipped '$($g.BaseName)': $($_.Exception.Message)")
        }
    }

    # Natural-ish sort by episode label then title
    $sorted = $result.Sets | Sort-Object EpisodeLabel, Title
    $result.Sets = New-Object System.Collections.Generic.List[psobject]
    foreach ($s in $sorted) { $result.Sets.Add($s) }

    return $result
}

# ===========================================================================
# Shared state between the worker runspace and the UI thread
# ===========================================================================
$sync = [hashtable]::Synchronized(@{
    LogQueue        = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
    StatusQueue     = New-Object System.Collections.Concurrent.ConcurrentQueue[psobject]
    Completed       = 0
    Total           = 0
    Running         = $false
    CancelRequested = $false
    CurrentProc     = $null
})


# ===========================================================================
# Row model for the table (INotifyPropertyChanged so status updates show live)
# and a tiny helper to give the window a dark title bar.
# ===========================================================================
if (-not ('EpisodeRow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public class EpisodeRow : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    private void N(string p) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }

    private int _index;
    private bool _checked = true;
    private string _episode = "";
    private string _show = "";
    private string _release = "";
    private string _dest = "";
    private int _parts;
    private string _status = "Ready";

    public int Index { get { return _index; } set { _index = value; N("Index"); } }
    public bool IsChecked { get { return _checked; } set { _checked = value; N("IsChecked"); } }
    public string Episode { get { return _episode; } set { _episode = value ?? ""; N("Episode"); } }
    public string Show { get { return _show; } set { _show = value ?? ""; N("Show"); } }
    public string Release { get { return _release; } set { _release = value ?? ""; N("Release"); } }
    public string Destination { get { return _dest; } set { _dest = value ?? ""; N("Destination"); } }
    public int Parts { get { return _parts; } set { _parts = value; N("Parts"); } }
    public string Status { get { return _status; } set { _status = value ?? ""; N("Status"); N("StatusBrush"); } }

    public string StatusBrush {
        get {
            string s = _status ?? "";
            if (s.StartsWith("Done") || s.StartsWith("Previewed")) return "#3DDC84";
            if (s.StartsWith("Failed") || s.StartsWith("Error") || s.StartsWith("No video")) return "#FF5C6C";
            if (s.StartsWith("Extracting")) return "#4FA3FF";
            if (s.StartsWith("Queued")) return "#FFC857";
            if (s.StartsWith("Cancelled")) return "#6B7280";
            return "#8B93A5";
        }
    }
}

public static class DwmHelper {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
'@
}

# ===========================================================================
# Window layout + styles (XAML). Pure ASCII on purpose - Windows PowerShell
# 5.1 reads BOM-less scripts as ANSI, so any fancy characters are entities.
# ===========================================================================
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Episode Extractor" Width="1180" Height="820" MinWidth="960" MinHeight="660"
        WindowStartupLocation="CenterScreen" Background="#0F1115"
        FontFamily="Segoe UI" FontSize="13" Foreground="#E8EAF0"
        UseLayoutRounding="True" SnapsToDevicePixels="True" AllowDrop="True">
  <Window.Resources>
    <SolidColorBrush x:Key="{x:Static SystemColors.ControlBrushKey}" Color="#171A21"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#1E2A42"/>
    <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#E8EAF0"/>
    <BooleanToVisibilityConverter x:Key="B2V"/>

    <!-- Cards / captions -->
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#171A21"/>
      <Setter Property="BorderBrush" Value="#232733"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18,16"/>
    </Style>
    <Style x:Key="Caption" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#8B93A5"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>

    <!-- Text boxes (Tag = placeholder text) -->
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#0F1115"/>
      <Setter Property="Foreground" Value="#E8EAF0"/>
      <Setter Property="BorderBrush" Value="#2A2F3A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CaretBrush" Value="#E8EAF0"/>
      <Setter Property="SelectionBrush" Value="#2F7BFF"/>
      <Setter Property="Padding" Value="11,0"/>
      <Setter Property="Height" Value="38"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
              <Grid Margin="{TemplateBinding Padding}">
                <TextBlock x:Name="Ph" Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}"
                           Foreground="#5D6575" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                           Visibility="Collapsed" IsHitTestVisible="False" TextTrimming="CharacterEllipsis"/>
                <ScrollViewer x:Name="PART_ContentHost" Focusable="False"
                              VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                              HorizontalScrollBarVisibility="{TemplateBinding HorizontalScrollBarVisibility}"
                              VerticalScrollBarVisibility="{TemplateBinding VerticalScrollBarVisibility}"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="Text" Value="">
                <Setter TargetName="Ph" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#3A4150"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#2F7BFF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Buttons -->
    <Style TargetType="Button">
      <Setter Property="Background" Value="#1E222B"/>
      <Setter Property="Foreground" Value="#E8EAF0"/>
      <Setter Property="BorderBrush" Value="#2E3441"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Height" Value="38"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#262B36"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter Property="Background" Value="#2E3441"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Accent" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#2F7BFF"/>
      <Setter Property="BorderBrush" Value="#2F7BFF"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#4C8DFF"/>
          <Setter Property="BorderBrush" Value="#4C8DFF"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter Property="Background" Value="#2566DB"/>
          <Setter Property="BorderBrush" Value="#2566DB"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Link" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="#8AB4FF"/>
      <Setter Property="Padding" Value="8,0"/>
      <Setter Property="Height" Value="28"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#1E2638"/>
          <Setter Property="Foreground" Value="#B5CEFF"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter Property="Background" Value="#22304D"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="LinkToggle" TargetType="ToggleButton">
      <Setter Property="Foreground" Value="#8AB4FF"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="6" Padding="8,4">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1E2638"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Toggle switch -->
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E8EAF0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Track" Width="38" Height="22" CornerRadius="11" Background="#2A2F3A" VerticalAlignment="Center">
                <Ellipse x:Name="Knob" Width="16" Height="16" Fill="#C9CED8" HorizontalAlignment="Left" Margin="3,0,0,0"/>
              </Border>
              <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#2F7BFF"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Margin" Value="0,0,3,0"/>
                <Setter TargetName="Knob" Property="Fill" Value="White"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Row tick box -->
    <Style x:Key="Tick" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Box" Width="18" Height="18" CornerRadius="5" BorderThickness="1.5" BorderBrush="#4A5263" Background="Transparent">
              <Path x:Name="Mark" Data="M 3,8.5 L 6.5,12 L 12.5,4.5" Stroke="White" StrokeThickness="2"
                    StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="#8AB4FF"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="#2F7BFF"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="#2F7BFF"/>
                <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Progress bar -->
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Foreground" Value="#2F7BFF"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" CornerRadius="3" Background="#232733"/>
              <Border x:Name="PART_Indicator" CornerRadius="3" Background="{TemplateBinding Foreground}" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Scrollbars -->
    <Style x:Key="ThumbStyle" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="T" CornerRadius="4" Background="#353B48" Margin="3"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="T" Property="Background" Value="#4A5263"/>
              </Trigger>
              <Trigger Property="IsDragging" Value="True">
                <Setter TargetName="T" Property="Background" Value="#5A6375"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="12"/>
      <Setter Property="MinWidth" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="{TemplateBinding Background}">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb Style="{StaticResource ThumbStyle}"/>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="12"/>
          <Setter Property="MinHeight" Value="12"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="{TemplateBinding Background}">
                  <Track x:Name="PART_Track" IsDirectionReversed="False">
                    <Track.Thumb>
                      <Thumb Style="{StaticResource ThumbStyle}"/>
                    </Track.Thumb>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- Tooltips / context menu -->
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#1E222B"/>
      <Setter Property="Foreground" Value="#E8EAF0"/>
      <Setter Property="BorderBrush" Value="#2E3441"/>
      <Setter Property="Padding" Value="9,6"/>
    </Style>
    <Style x:Key="DarkMenu" TargetType="ContextMenu">
      <Setter Property="Foreground" Value="#E8EAF0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ContextMenu">
            <Border Background="#1E222B" BorderBrush="#2E3441" BorderThickness="1" CornerRadius="8" Padding="4">
              <StackPanel IsItemsHost="True"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DarkMenuItem" TargetType="MenuItem">
      <Setter Property="Foreground" Value="#E8EAF0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="MenuItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="5" Padding="14,8" MinWidth="200">
              <ContentPresenter ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#2A3142"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Table -->
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#E8EAF0"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="RowBackground" Value="Transparent"/>
      <Setter Property="AlternatingRowBackground" Value="Transparent"/>
      <Setter Property="GridLinesVisibility" Value="None"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="RowHeight" Value="40"/>
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserDeleteRows" Value="False"/>
      <Setter Property="CanUserResizeRows" Value="False"/>
      <Setter Property="SelectionMode" Value="Extended"/>
      <Setter Property="SelectionUnit" Value="FullRow"/>
      <Setter Property="HorizontalScrollBarVisibility" Value="Disabled"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Foreground" Value="#8B93A5"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridColumnHeader">
            <Grid Background="Transparent">
              <Border BorderBrush="#232733" BorderThickness="0,0,0,1"/>
              <DockPanel Margin="{TemplateBinding Padding}">
                <TextBlock x:Name="Arrow" DockPanel.Dock="Right" FontSize="9" Margin="6,0,0,0"
                           VerticalAlignment="Center" Foreground="#8AB4FF"/>
                <ContentPresenter VerticalAlignment="Center"/>
              </DockPanel>
              <Thumb x:Name="PART_RightHeaderGripper" HorizontalAlignment="Right" Width="8" Cursor="SizeWE">
                <Thumb.Template>
                  <ControlTemplate TargetType="Thumb">
                    <Border Background="Transparent"/>
                  </ControlTemplate>
                </Thumb.Template>
              </Thumb>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="SortDirection" Value="Ascending">
                <Setter TargetName="Arrow" Property="Text" Value="&#x25B2;"/>
              </Trigger>
              <Trigger Property="SortDirection" Value="Descending">
                <Setter TargetName="Arrow" Property="Text" Value="&#x25BC;"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="#E8EAF0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#E8EAF0"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="BorderBrush" Value="#1C1F27"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#1B1F28"/>
        </Trigger>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#1E2A42"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="Transparent" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Foreground" Value="#E8EAF0"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="CellText" TargetType="TextBlock">
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="ToolTip" Value="{Binding Text, RelativeSource={RelativeSource Self}}"/>
    </Style>
    <Style x:Key="CellShow" TargetType="TextBlock" BasedOn="{StaticResource CellText}">
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="CellMuted" TargetType="TextBlock" BasedOn="{StaticResource CellText}">
      <Setter Property="Foreground" Value="#9AA3B2"/>
    </Style>
    <Style x:Key="CellMono" TargetType="TextBlock" BasedOn="{StaticResource CellText}">
      <Setter Property="Foreground" Value="#6B7385"/>
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="11.5"/>
    </Style>
    <Style x:Key="CellCenter" TargetType="TextBlock" BasedOn="{StaticResource CellMuted}">
      <Setter Property="HorizontalAlignment" Value="Center"/>
    </Style>
  </Window.Resources>

  <Grid Margin="24,20,24,20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <DockPanel Grid.Row="0" Margin="0,0,0,18" LastChildFill="False">
      <Border x:Name="Logo" DockPanel.Dock="Left" Width="46" Height="46" CornerRadius="12" Background="#1A2540"/>
      <StackPanel DockPanel.Dock="Left" Margin="14,0,0,0" VerticalAlignment="Center">
        <TextBlock Text="Episode Extractor" FontSize="21" FontWeight="SemiBold"/>
        <TextBlock Text="Unpack multi-part RAR releases and file them straight into your Plex library"
                   Foreground="#8B93A5" Margin="0,2,0,0"/>
      </StackPanel>
      <Border DockPanel.Dock="Right" Background="#171A21" BorderBrush="#232733" BorderThickness="1"
              CornerRadius="18" Padding="14,4,6,4" VerticalAlignment="Center">
        <StackPanel Orientation="Horizontal">
          <Ellipse x:Name="SzDot" Width="8" Height="8" Fill="#3DDC84" VerticalAlignment="Center"/>
          <TextBlock x:Name="SzText" Text="7-Zip ready" Margin="9,0,8,0" VerticalAlignment="Center"/>
          <Button x:Name="Btn7z" Content="Change" Style="{StaticResource Link}"/>
        </StackPanel>
      </Border>
    </DockPanel>

    <!-- Source + Plex cards -->
    <Grid Grid.Row="1" Margin="0,0,0,16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="16"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Style="{StaticResource Card}">
        <StackPanel>
          <TextBlock Text="SOURCE FOLDER" Style="{StaticResource Caption}"/>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="TxtPath" Tag="Drop a folder here, or browse..."/>
            <Button x:Name="BtnBrowse" Grid.Column="1" Content="Browse" Margin="8,0,0,0"/>
            <Button x:Name="BtnScan" Grid.Column="2" Content="Scan" Style="{StaticResource Accent}" Margin="8,0,0,0" MinWidth="92"/>
          </Grid>
          <TextBlock Text="Finds .rar / .r00 / .partNN.rar sets in every subfolder"
                     Foreground="#5D6575" FontSize="11.5" Margin="0,10,0,0"/>
        </StackPanel>
      </Border>

      <Border Grid.Column="2" Style="{StaticResource Card}">
        <StackPanel>
          <DockPanel Margin="0,0,0,10">
            <CheckBox x:Name="ChkPlex" DockPanel.Dock="Right" Style="{StaticResource Switch}" Content="Plex layout"/>
            <TextBlock Text="PLEX TV LIBRARY" Style="{StaticResource Caption}" Margin="0" VerticalAlignment="Center"/>
          </DockPanel>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="TxtLib" Tag="Your TV library folder, e.g. D:\Media\TV Shows"/>
            <Button x:Name="BtnBrowseLib" Grid.Column="1" Content="Browse" Margin="8,0,0,0"/>
          </Grid>
          <TextBlock x:Name="PlexHint" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" Foreground="#5D6575"
                     Margin="0,10,0,0" TextTrimming="CharacterEllipsis"
                     Text="Show Name\Season 01\Show Name - s01e05.mkv"/>
        </StackPanel>
      </Border>
    </Grid>

    <!-- Releases table -->
    <Border Grid.Row="2" Style="{StaticResource Card}" Padding="0">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <DockPanel Margin="18,14,18,10" LastChildFill="False">
          <TextBox x:Name="TxtFilter" DockPanel.Dock="Left" Width="320" Height="34" Tag="Filter by show, episode or release"/>
          <Button x:Name="BtnAll" DockPanel.Dock="Left" Content="Select all" Style="{StaticResource Link}" Margin="12,0,0,0"/>
          <Button x:Name="BtnNone" DockPanel.Dock="Left" Content="Select none" Style="{StaticResource Link}" Margin="2,0,0,0"/>
          <TextBlock x:Name="LblSummary" DockPanel.Dock="Right" Foreground="#8B93A5" VerticalAlignment="Center" Text="No scan yet"/>
        </DockPanel>

        <DataGrid x:Name="List" Grid.Row="1" Margin="6,0,6,6">
          <DataGrid.Columns>
            <DataGridTemplateColumn Width="50" CanUserResize="False" SortMemberPath="IsChecked">
              <DataGridTemplateColumn.CellTemplate>
                <DataTemplate>
                  <CheckBox Style="{StaticResource Tick}" HorizontalAlignment="Center" VerticalAlignment="Center"
                            IsChecked="{Binding IsChecked, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"/>
                </DataTemplate>
              </DataGridTemplateColumn.CellTemplate>
            </DataGridTemplateColumn>
            <DataGridTemplateColumn Header="EPISODE" Width="132" SortMemberPath="Episode">
              <DataGridTemplateColumn.CellTemplate>
                <DataTemplate>
                  <Border Background="#1A2540" CornerRadius="6" Padding="8,3" HorizontalAlignment="Left">
                    <TextBlock Text="{Binding Episode}" FontFamily="Cascadia Mono, Consolas" FontSize="12" Foreground="#9CC0FF"/>
                  </Border>
                </DataTemplate>
              </DataGridTemplateColumn.CellTemplate>
            </DataGridTemplateColumn>
            <DataGridTextColumn Header="SHOW" Binding="{Binding Show}" Width="210" IsReadOnly="True" ElementStyle="{StaticResource CellShow}"/>
            <DataGridTextColumn Header="LANDS IN" Binding="{Binding Destination}" Width="1.5*" IsReadOnly="True" ElementStyle="{StaticResource CellMuted}"/>
            <DataGridTextColumn Header="RELEASE" Binding="{Binding Release}" Width="*" IsReadOnly="True" ElementStyle="{StaticResource CellMono}"/>
            <DataGridTextColumn Header="PARTS" Binding="{Binding Parts}" Width="64" IsReadOnly="True" ElementStyle="{StaticResource CellCenter}"/>
            <DataGridTemplateColumn Header="STATUS" Width="128" SortMemberPath="Status">
              <DataGridTemplateColumn.CellTemplate>
                <DataTemplate>
                  <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <Ellipse Width="8" Height="8" Fill="{Binding StatusBrush}" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <TextBlock Text="{Binding Status}" Foreground="{Binding StatusBrush}" VerticalAlignment="Center"/>
                  </StackPanel>
                </DataTemplate>
              </DataGridTemplateColumn.CellTemplate>
            </DataGridTemplateColumn>
          </DataGrid.Columns>
        </DataGrid>

        <StackPanel x:Name="EmptyState" Grid.Row="1" VerticalAlignment="Center" HorizontalAlignment="Center" IsHitTestVisible="False">
          <TextBlock Text="Nothing scanned yet" FontSize="17" FontWeight="SemiBold" HorizontalAlignment="Center"/>
          <TextBlock Text="Pick or drop a source folder, then hit Scan." Foreground="#8B93A5" Margin="0,6,0,0" HorizontalAlignment="Center"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Footer: options, progress, actions -->
    <Grid Grid.Row="3" Margin="0,16,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <CheckBox x:Name="ChkDelete" Style="{StaticResource Switch}" Content="Delete RARs after"/>
        <CheckBox x:Name="ChkPreview" Style="{StaticResource Switch}" Content="Preview only" Margin="24,0,0,0"/>
        <CheckBox x:Name="ChkOpen" Style="{StaticResource Switch}" Content="Open folder when done" Margin="24,0,0,0"/>
      </StackPanel>
      <StackPanel Grid.Column="1" Margin="32,0,20,0" VerticalAlignment="Center">
        <DockPanel Margin="0,0,0,7">
          <TextBlock x:Name="LblProgress" DockPanel.Dock="Right" Foreground="#8B93A5" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" Text="0 / 0"/>
          <TextBlock x:Name="LblNow" Foreground="#8B93A5" FontSize="12" TextTrimming="CharacterEllipsis" Text="Idle"/>
        </DockPanel>
        <ProgressBar x:Name="Progress" Minimum="0" Maximum="1" Value="0"/>
      </StackPanel>
      <Button x:Name="BtnCancel" Grid.Column="2" Content="Cancel" IsEnabled="False" Margin="0,0,10,0" MinWidth="96" Height="42"/>
      <Button x:Name="BtnStart" Grid.Column="3" Content="Start extracting" Style="{StaticResource Accent}" MinWidth="160" Height="42" FontSize="14"/>
    </Grid>

    <!-- Log -->
    <StackPanel Grid.Row="4" Margin="0,12,0,0">
      <ToggleButton x:Name="TglLog" Style="{StaticResource LinkToggle}" Content="Show log" HorizontalAlignment="Left"/>
      <TextBox x:Name="TxtLog" Height="160" Margin="0,8,0,0" IsReadOnly="True" TextWrapping="NoWrap"
               VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
               VerticalContentAlignment="Stretch" Padding="12,8"
               FontFamily="Cascadia Mono, Consolas" FontSize="11.5" Foreground="#A9D8B8" Background="#0B0D11"
               Visibility="{Binding IsChecked, ElementName=TglLog, Converter={StaticResource B2V}}"/>
    </StackPanel>
  </Grid>
</Window>
'@

# Startup failures get written to Extractor-error.log next to the script/exe,
# with the full inner-exception chain (WPF hides the real cause in there).
function Write-StartupError {
    param($Err, [string]$Stage)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(("[{0}] Episode Extractor failed during: {1}" -f (Get-Date -Format s), $Stage))
    $ex = $Err; $depth = 0
    while ($ex -and $depth -lt 10) {
        $where = ''
        if ($ex -is [System.Windows.Markup.XamlParseException] -and $ex.LineNumber -gt 0) {
            $where = " (XAML line $($ex.LineNumber), col $($ex.LinePosition))"
        }
        $lines.Add(("  {0}{1}: {2}{3}" -f ('  ' * $depth), $ex.GetType().FullName, $ex.Message, $where))
        $ex = $ex.InnerException; $depth++
    }
    $text = $lines -join "`r`n"
    try { Set-Content -LiteralPath (Join-Path $script:ScriptDir 'Extractor-error.log') -Value $text -Encoding UTF8 } catch { }
    Write-Host $text -ForegroundColor Red
    try { [void][System.Windows.MessageBox]::Show($text, 'Episode Extractor - startup error') } catch { }
}

try {
    $win = [Windows.Markup.XamlReader]::Parse($xaml)
} catch {
    Write-StartupError $_.Exception 'loading the window layout (XAML)'
    return
}

foreach ($n in @('Logo','SzDot','SzText','Btn7z','TxtPath','BtnBrowse','BtnScan','ChkPlex','TxtLib','BtnBrowseLib',
                 'PlexHint','TxtFilter','BtnAll','BtnNone','LblSummary','List','EmptyState','ChkDelete','ChkPreview',
                 'ChkOpen','LblProgress','LblNow','Progress','BtnCancel','BtnStart','TglLog','TxtLog')) {
    Set-Variable -Name $n -Value $win.FindName($n) -Scope Script
}

$script:BrushConv = New-Object System.Windows.Media.BrushConverter
function Get-Brush { param([string]$Hex) return $script:BrushConv.ConvertFromString($Hex) }
$script:Bullet = [string][char]0x2022

function Show-Msg {
    param([string]$Text, [string]$Icon = 'Warning', [string]$Buttons = 'OK')
    return [System.Windows.MessageBox]::Show($win, $Text, 'Episode Extractor',
        [System.Windows.MessageBoxButton]$Buttons, [System.Windows.MessageBoxImage]$Icon)
}

# ===========================================================================
# Icon, header image, dark title bar
# ===========================================================================
function Get-AppImage {
    param([string[]]$Candidates)
    foreach ($p in $Candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            try {
                $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
                $bmp.BeginInit()
                $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bmp.UriSource = New-Object System.Uri($p)
                $bmp.EndInit()
                $bmp.Freeze()
                return $bmp
            } catch { }
        }
    }
    try {
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
        return [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $ico.Handle, [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    } catch { return $null }
}

# Custom branding: drop app.ico (window/exe icon) and optionally app.png or
# app.jpg (header image) next to the script/exe. Older local file names are
# still picked up so existing setups keep their look.
$assetDir = $script:ScriptDir
$iconFiles   = @((Join-Path $assetDir 'app.ico'), (Join-Path $assetDir 'sonic-the-hedgehog-1.ico'))
$headerFiles = @((Join-Path $assetDir 'app.png'), (Join-Path $assetDir 'app.jpg'), (Join-Path $assetDir 'sonic-the-hedgehog-1.jpg')) + $iconFiles
$winIcon = Get-AppImage -Candidates $iconFiles
if ($winIcon) { $win.Icon = $winIcon }
$headerImg = Get-AppImage -Candidates $headerFiles
if ($headerImg) {
    $brush = New-Object System.Windows.Media.ImageBrush($headerImg)
    $brush.Stretch = [System.Windows.Media.Stretch]::UniformToFill
    $Logo.Background = $brush
}

$win.Add_SourceInitialized({
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
        $on = 1
        [void][DwmHelper]::DwmSetWindowAttribute($h, 20, [ref]$on, 4)   # Win10 20H1+ / Win11
        [void][DwmHelper]::DwmSetWindowAttribute($h, 19, [ref]$on, 4)   # older Win10 builds
    } catch { }
})

# ===========================================================================
# 7-Zip status pill
# ===========================================================================
$script:SevenZipPath = Find-SevenZip

function Update-SevenZipBadge {
    if ($script:SevenZipPath -and (Test-Path -LiteralPath $script:SevenZipPath)) {
        $SzDot.Fill = Get-Brush '#3DDC84'
        $SzText.Text = '7-Zip ready'
        $SzText.ToolTip = $script:SevenZipPath
        $Btn7z.Content = 'Change'
    } else {
        $SzDot.Fill = Get-Brush '#FF5C6C'
        $SzText.Text = '7-Zip not found'
        $SzText.ToolTip = 'Install 7-Zip from 7-zip.org, or point me at 7z.exe'
        $Btn7z.Content = 'Locate'
    }
}

$Btn7z.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Find 7z.exe'
    $dlg.Filter = '7-Zip (7z.exe)|7z.exe;7zr.exe|All files|*.*'
    if ($script:SevenZipPath) { try { $dlg.InitialDirectory = [System.IO.Path]::GetDirectoryName($script:SevenZipPath) } catch { } }
    if ($dlg.ShowDialog($win)) { $script:SevenZipPath = $dlg.FileName; Update-SevenZipBadge }
})

# ===========================================================================
# Table data
# ===========================================================================
$script:sets       = New-Object System.Collections.Generic.List[psobject]
$script:Rows       = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:RowByIndex = @{}
$script:ScanRoot   = ''
$List.ItemsSource  = $script:Rows

$script:View = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:Rows)
$script:View.Filter = [Predicate[object]]{
    param($r)
    $f = $TxtFilter.Text.Trim()
    if ([string]::IsNullOrEmpty($f)) { return $true }
    foreach ($v in @($r.Episode, $r.Show, $r.Release, $r.Destination)) {
        if ($v -and $v.IndexOf($f, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Test-IsEpisodeLabel {
    param([string]$Label)
    return ($Label -match '^(S\d{1,2}E\d{1,3}(-E\d{1,3})?|S\d{1,2}\.Extras|E\d{1,3}|\d{4}-\d{2}-\d{2})$')
}

function Get-LibraryRootFor {
    param($Set)
    $root = $TxtLib.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $Set.Dir }
    return $root
}

# What the "Lands in" column shows for a release
function Get-RowDestination {
    param($Set)
    if ($ChkPlex.IsChecked) {
        $parts = $null
        if (Test-IsEpisodeLabel $Set.EpisodeLabel) { $parts = Get-PlexParts -Title $Set.Title -Label $Set.EpisodeLabel }
        if ($parts) { return ('{0}\{1}\{2}' -f $parts.Show, $parts.SeasonFolder, $parts.FileBase) }
        return 'Not an episode - extracts next to the RARs'
    }
    $out = [string]$Set.OutputFolder
    if ($script:ScanRoot -and $out.StartsWith($script:ScanRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $out.Substring($script:ScanRoot.Length).TrimStart('\')
        if ($rel) { return ('.\' + $rel) }
        return '.\'
    }
    return $out
}

# Real folder to open for a release (right-click menu / open when done)
function Get-DestFolder {
    param($Set)
    if ($ChkPlex.IsChecked -and (Test-IsEpisodeLabel $Set.EpisodeLabel)) {
        $parts = Get-PlexParts -Title $Set.Title -Label $Set.EpisodeLabel
        if ($parts) {
            $root   = Get-LibraryRootFor $Set
            $show   = [System.IO.Path]::Combine($root, $parts.Show)
            $season = [System.IO.Path]::Combine($show, $parts.SeasonFolder)
            foreach ($p in @($season, $show, $root)) { if (Test-Path -LiteralPath $p) { return $p } }
        }
    }
    if ($Set.OutputFolder -and (Test-Path -LiteralPath $Set.OutputFolder)) { return $Set.OutputFolder }
    return $Set.Dir
}

function Update-Destinations {
    foreach ($r in $script:Rows) {
        if ($r.Index -ge 0 -and $r.Index -lt $script:sets.Count) {
            $r.Destination = Get-RowDestination $script:sets[$r.Index]
        }
    }
}

function Update-EmptyState {
    $EmptyState.Visibility = if ($script:Rows.Count -eq 0) { 'Visible' } else { 'Collapsed' }
}

function Update-PlexState {
    $on = [bool]$ChkPlex.IsChecked
    $TxtLib.IsEnabled = $on
    $BtnBrowseLib.IsEnabled = $on
    $PlexHint.Opacity = if ($on) { 1.0 } else { 0.45 }
    Update-Destinations
}

function Add-Log {
    param([string]$Text)
    $TxtLog.AppendText($Text + "`r`n")
    $TxtLog.ScrollToEnd()
}

# ===========================================================================
# Scan
# ===========================================================================
function Invoke-Scan {
    $root = $TxtPath.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
        [void](Show-Msg "That folder doesn't exist.")
        return
    }
    if ($sync.Running) { return }

    $win.Cursor = [System.Windows.Input.Cursors]::Wait
    $BtnScan.IsEnabled = $false
    try {
        $res = Get-ArchiveSets -RootPath $root
        $script:ScanRoot = $root.TrimEnd('\')
        $script:sets = New-Object System.Collections.Generic.List[psobject]
        $script:Rows.Clear()
        $script:RowByIndex = @{}

        $i = 0
        foreach ($s in @($res.Sets | Sort-Object Title, EpisodeLabel)) {
            $script:sets.Add($s)
            $row = New-Object EpisodeRow
            $row.Index       = $i
            $row.Episode     = if (Test-IsEpisodeLabel $s.EpisodeLabel) { [string]$s.EpisodeLabel } else { '--' }
            $row.Show        = [string]$s.Title
            $row.Release     = [string]$s.BaseName
            $row.Parts       = [int]$s.PartCount
            $row.Status      = 'Ready'
            $row.IsChecked   = $true
            $row.Destination = Get-RowDestination $s
            $script:Rows.Add($row)
            $script:RowByIndex[$i] = $row
            $i++
        }

        $shows = @($script:sets | ForEach-Object { $_.Title } | Sort-Object -Unique).Count
        $txt = '{0} release{1}  {2}  {3} show{4}' -f $script:sets.Count, $(if ($script:sets.Count -eq 1) { '' } else { 's' }),
               $script:Bullet, $shows, $(if ($shows -eq 1) { '' } else { 's' })
        if ($res.Skipped -gt 0) { $txt += ('  {0}  {1} incomplete skipped' -f $script:Bullet, $res.Skipped) }
        $LblSummary.Text = $txt

        if ($res.Warnings.Count -gt 0) {
            foreach ($w in $res.Warnings) { Add-Log "[Scan warning] $w" }
            $TglLog.IsChecked = $true
        }
        if ($script:sets.Count -eq 0) { $LblSummary.Text = 'No RAR sets found in that folder' }
        $LblNow.Text = 'Ready'
    } catch {
        $LblSummary.Text = 'Scan failed - see log'
        Add-Log "[Scan error] $($_.Exception.Message)"
        $TglLog.IsChecked = $true
    } finally {
        $win.Cursor = $null
        $BtnScan.IsEnabled = $true
        Update-EmptyState
    }
}

# ===========================================================================
# The extraction worker (runs in its own runspace; unchanged engine)
# ===========================================================================
$script:WorkerScript = {
        # Move one video (and its matching subtitles) into a Plex destination.
        function Move-One {
            param($VideoFile, $DestDir, $DestBase, $Sync, [bool]$Strict)
            $ext = $VideoFile.Extension.ToLower()
            if (-not (Test-Path -LiteralPath $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
            $destVideo = [System.IO.Path]::Combine($DestDir, $DestBase + $ext)
            if (Test-Path -LiteralPath $destVideo) {
                $Sync.LogQueue.Enqueue("  Already in library, skipped: $DestBase$ext")
                return $false
            }
            [System.IO.File]::Move($VideoFile.FullName, $destVideo)
            $Sync.LogQueue.Enqueue("  -> $destVideo")

            $subExt = @('.srt','.ass','.ssa','.sub','.idx','.vtt')
            $vbase  = [System.IO.Path]::GetFileNameWithoutExtension($VideoFile.Name)
            $srcDirs = New-Object System.Collections.Generic.List[string]
            $srcDirs.Add($VideoFile.DirectoryName)
            foreach ($sd in @('Subs','Subtitles','Subtitle')) {
                $cand = [System.IO.Path]::Combine($VideoFile.DirectoryName, $sd)
                if (Test-Path -LiteralPath $cand) { $srcDirs.Add($cand) }
            }
            foreach ($sd in $srcDirs) {
                Get-ChildItem -LiteralPath $sd -File -ErrorAction SilentlyContinue |
                    Where-Object { $subExt -contains $_.Extension.ToLower() } |
                    ForEach-Object {
                        if ($Strict -and ($_.BaseName -notlike "$vbase*")) { return }
                        $lang = ''
                        $m = [regex]::Match($_.BaseName, '[.\-_ ](eng|english|en|spa|es|fre|fr|ger|de|forced|sdh)$', 'IgnoreCase')
                        if ($m.Success) { $lang = '.' + $m.Groups[1].Value.ToLower() }
                        $subDest = [System.IO.Path]::Combine($DestDir, $DestBase + $lang + $_.Extension.ToLower())
                        if (-not (Test-Path -LiteralPath $subDest)) {
                            try { [System.IO.File]::Move($_.FullName, $subDest); $Sync.LogQueue.Enqueue("     + subtitle $($_.Name)") } catch {}
                        }
                    }
            }
            return $true
        }

        try {
            foreach ($item in $payload) {
                try {
                    if ($sync.CancelRequested) {
                        $sync.LogQueue.Enqueue("Stopped before: $($item.BaseName)")
                        $sync.StatusQueue.Enqueue([PSCustomObject]@{Index=$item.Index; Status="Cancelled"})
                        continue
                    }
                    $sync.StatusQueue.Enqueue([PSCustomObject]@{Index=$item.Index; Status="Extracting..."})
                    $sync.LogQueue.Enqueue("---- $($item.BaseName) ----")

                    $outFolder = $item.OutputFolder
                    if ([string]::IsNullOrWhiteSpace($outFolder)) {
                        $outFolder = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($item.PrimaryFile), $item.BaseName)
                        $sync.LogQueue.Enqueue("  (no output folder set - using '$outFolder')")
                    }

                    if ($whatIf) {
                        if ($item.Plex -and $item.Plex.Enabled) {
                            $sync.LogQueue.Enqueue("[Preview] Would extract '$($item.PrimaryFile)', then place the video as '$([System.IO.Path]::Combine($item.Plex.SeasonDir, $item.Plex.FileBase)).<ext>'.")
                        } else {
                            $sync.LogQueue.Enqueue("[Preview] Would extract '$($item.PrimaryFile)' -> '$outFolder' and delete $($item.Files.Count) source file(s).")
                        }
                        $sync.StatusQueue.Enqueue([PSCustomObject]@{Index=$item.Index; Status="Previewed"})
                    } else {
                        try {
                            if (-not (Test-Path -LiteralPath $outFolder)) {
                                New-Item -ItemType Directory -Path $outFolder -Force | Out-Null
                            }
                        } catch { }

                        $psi = New-Object System.Diagnostics.ProcessStartInfo
                        $psi.FileName               = $sevenZip
                        $psi.Arguments              = "x `"$($item.PrimaryFile)`" -o`"$outFolder`" -y"
                        $psi.UseShellExecute        = $false
                        $psi.CreateNoWindow         = $true
                        $psi.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
                        $psi.RedirectStandardOutput = $true
                        $psi.RedirectStandardError  = $true

                        $p = [System.Diagnostics.Process]::Start($psi)
                        $sync.CurrentProc = $p
                        $stdoutTask = $p.StandardOutput.ReadToEndAsync()
                        $stderrTask = $p.StandardError.ReadToEndAsync()
                        $p.WaitForExit()
                        [void]$stdoutTask.Wait()
                        [void]$stderrTask.Wait()
                        $exitCode = $p.ExitCode
                        $errText  = $stderrTask.Result
                        $sync.CurrentProc = $null
                        $p.Dispose()

                        if ($sync.CancelRequested -and $exitCode -ne 0) {
                            $sync.LogQueue.Enqueue("  Cancelled during extraction (source files kept).")
                            $sync.StatusQueue.Enqueue([PSCustomObject]@{Index=$item.Index; Status="Cancelled"})
                        }
                        elseif ($exitCode -eq 0) {
                            $sync.LogQueue.Enqueue("  Extraction OK.")
                            $placedOk    = $true
                            $finalStatus = "Done"

                            # ---- Plex placement ----
                            if ($item.Plex -and $item.Plex.Enabled) {
                                $placedOk = $false
                                $videoExt = @('.mkv','.mp4','.avi','.m4v','.ts','.m2ts','.wmv','.mov','.mpg','.mpeg','.flv','.webm')
                                $vids = @(Get-ChildItem -LiteralPath $outFolder -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
                                    ($videoExt -contains $_.Extension.ToLower()) -and ($_.Length -gt 20MB) `
                                    -and ($_.FullName -notmatch '(?i)[\\/](sample|proof)[\\/]') `
                                    -and ($_.BaseName -notmatch '(?i)(^|[._\- ])sample([._\- ]|$)')
                                })
                                if ($vids.Count -eq 0) {
                                    $sync.LogQueue.Enqueue("  No video over 20MB found - left the extracted files in '$outFolder'.")
                                    $finalStatus = "No video"
                                }
                                elseif ($vids.Count -eq 1) {
                                    [void](Move-One -VideoFile $vids[0] -DestDir $item.Plex.SeasonDir -DestBase $item.Plex.FileBase -Sync $sync -Strict $false)
                                    $placedOk = $true
                                }
                                else {
                                    # Season pack: detect each file on its own name, place under the show
                                    $n = 0
                                    foreach ($v in $vids) {
                                        $tag = $null; $seasonFolder = $null
                                        if ($v.BaseName -match '(?i)s(\d{1,2})[._ -]?e(\d{1,3})(?:[._ -]?e(\d{1,3}))?') {
                                            $sn = [int]$matches[1]; $e1 = ('{0:D2}' -f [int]$matches[2])
                                            if ($matches[3]) { $tag = ('s{0:d2}e{1}-e{2:d2}' -f $sn, $e1, [int]$matches[3]) } else { $tag = ('s{0:d2}e{1}' -f $sn, $e1) }
                                            $seasonFolder = ('Season {0:D2}' -f $sn)
                                        } elseif ($v.BaseName -match '(?<![0-9])(\d{1,2})x(\d{2})(?![0-9])') {
                                            $sn = [int]$matches[1]; $tag = ('s{0:d2}e{1:d2}' -f $sn, [int]$matches[2]); $seasonFolder = ('Season {0:D2}' -f $sn)
                                        } elseif ($v.BaseName -match '(?<![0-9])((?:19|20)\d\d)[.\-](\d{1,2})[.\-](\d{1,2})(?![0-9])') {
                                            $tag = ('{0}-{1:D2}-{2:D2}' -f $matches[1], [int]$matches[2], [int]$matches[3]); $seasonFolder = ('Season {0}' -f $matches[1])
                                        }
                                        if ($tag) {
                                            $destDir  = [System.IO.Path]::Combine($item.Plex.ShowDir, $seasonFolder)
                                            $destBase = ('{0} - {1}' -f $item.Plex.Show, $tag)
                                        } else {
                                            $destDir  = [System.IO.Path]::Combine($item.Plex.ShowDir, 'Unsorted')
                                            $destBase = [System.IO.Path]::GetFileNameWithoutExtension($v.Name)
                                        }
                                        if (Move-One -VideoFile $v -DestDir $destDir -DestBase $destBase -Sync $sync -Strict $true) { $n++ }
                                    }
                                    $sync.LogQueue.Enqueue("  Placed $n of $($vids.Count) video(s) into the library (season pack).")
                                    $placedOk = $true
                                }

                                # Remove our temp extraction folder (never the source RARs)
                                try { if (Test-Path -LiteralPath $outFolder) { Remove-Item -LiteralPath $outFolder -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
                            }

                            # ---- Delete source RARs (only if the content is safely in place) ----
                            if ($deleteAfter -and $placedOk) {
                                $delOk = 0; $delFail = 0
                                foreach ($f in $item.Files) {
                                    $target = $f
                                    if ($f.Length -ge 240 -and -not $f.StartsWith('\\?\')) {
                                        if ($f.StartsWith('\\')) { $target = '\\?\UNC\' + $f.Substring(2) } else { $target = '\\?\' + $f }
                                    }
                                    try { [System.IO.File]::Delete($target); $delOk++ } catch { $delFail++ }
                                }
                                $sync.LogQueue.Enqueue("  Deleted $delOk source file(s)." + $(if ($delFail -gt 0) { " $delFail could not be deleted." } else { "" }))
                            }

                            $sync.StatusQueue.Enqueue([PSCustomObject]@{Index=$item.Index; Status=$finalStatus})
                        }
                        else {
                            $sync.LogQueue.Enqueue("  FAILED (exit $exitCode): $errText")
                            $sync.StatusQueue.Enqueue([PSCustomObject]@{Index=$item.Index; Status="Failed"})
                        }
                    }
                }
                catch {
                    $sync.LogQueue.Enqueue("  ERROR on '$($item.BaseName)': $($_.Exception.Message)")
                    $sync.StatusQueue.Enqueue([PSCustomObject]@{Index=$item.Index; Status="Error"})
                }
                finally { $sync.Completed++ }
            }
        }
        catch { $sync.LogQueue.Enqueue("FATAL worker error: $($_.Exception.Message)") }
        finally { $sync.CurrentProc = $null; $sync.Running = $false }
}

# ===========================================================================
# Start / progress / finish
# ===========================================================================
$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(150)

function Set-RunningUi {
    param([bool]$Running)
    $BtnStart.IsEnabled     = -not $Running
    $BtnScan.IsEnabled      = -not $Running
    $BtnBrowse.IsEnabled    = -not $Running
    $TxtPath.IsEnabled      = -not $Running
    $ChkPlex.IsEnabled      = -not $Running
    $TxtLib.IsEnabled       = (-not $Running) -and [bool]$ChkPlex.IsChecked
    $BtnBrowseLib.IsEnabled = (-not $Running) -and [bool]$ChkPlex.IsChecked
    $BtnCancel.IsEnabled    = $Running
}

function Receive-WorkerUpdates {
    $sb = New-Object System.Text.StringBuilder
    $line = $null
    while ($sync.LogQueue.TryDequeue([ref]$line)) { [void]$sb.AppendLine($line) }
    if ($sb.Length -gt 0) { $TxtLog.AppendText($sb.ToString()); $TxtLog.ScrollToEnd() }

    $upd = $null
    while ($sync.StatusQueue.TryDequeue([ref]$upd)) {
        $r = $script:RowByIndex[[int]$upd.Index]
        if ($r) {
            $r.Status = [string]$upd.Status
            if ($r.Status -like 'Extracting*') {
                $LblNow.Text = ('Extracting  {0}  {1}' -f $r.Show, $r.Episode)
                $List.ScrollIntoView($r)
            }
            if ($r.Status -match '^(Failed|Error|No video)') { $TglLog.IsChecked = $true }
        }
    }
}

$script:Timer.Add_Tick({
    $finished = (-not $sync.Running) -and ($sync.Total -gt 0) -and ($sync.Completed -ge $sync.Total)
    Receive-WorkerUpdates

    $Progress.Value = [Math]::Min([double]$sync.Completed, $Progress.Maximum)
    $LblProgress.Text = "$($sync.Completed) / $($sync.Total)"

    if ($finished) {
        $script:Timer.Stop()
        Set-RunningUi $false
        Add-Log '---- Queue finished ----'

        $done   = @($script:Rows | Where-Object { $_.Status -eq 'Done' -or $_.Status -eq 'Previewed' }).Count
        $failed = @($script:Rows | Where-Object { $_.Status -match '^(Failed|Error|No video)' }).Count
        $LblNow.Text = if ($failed -gt 0) { "Finished - $done ok, $failed need attention (see log)" } else { "Finished - $done ok" }

        if ($ChkOpen.IsChecked -and $script:lastOutputRoot -and (Test-Path -LiteralPath $script:lastOutputRoot)) {
            try { Start-Process explorer.exe $script:lastOutputRoot } catch { }
        }
        if ($script:currentPs) {
            try { $script:currentPs.Dispose() } catch { }
            try { $script:currentRunspace.Close() } catch { }
            $script:currentPs = $null
            $script:currentRunspace = $null
        }
    }
})

function Start-Queue {
    if ($script:Rows.Count -eq 0) { [void](Show-Msg 'Scan a folder first.'); return }
    $selRows = @($script:Rows | Where-Object { $_.IsChecked })
    if ($selRows.Count -eq 0) { [void](Show-Msg 'Nothing is ticked.'); return }
    if (-not $script:SevenZipPath -or -not (Test-Path -LiteralPath $script:SevenZipPath)) {
        [void](Show-Msg "7-Zip wasn't found. Install it from 7-zip.org, or use Locate (top right) to point at 7z.exe." 'Error')
        return
    }

    $plexOn  = [bool]$ChkPlex.IsChecked
    $libRoot = $TxtLib.Text.Trim()
    if ($plexOn -and [string]::IsNullOrWhiteSpace($libRoot)) {
        $ans = Show-Msg ("No Plex TV library folder is set, so each show folder will be created next to its release." +
                         "`r`n`r`nContinue anyway?") 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
    }
    if ($plexOn -and $libRoot -and -not (Test-Path -LiteralPath $libRoot)) {
        $ans = Show-Msg "The TV library folder doesn't exist yet:`r`n$libRoot`r`n`r`nCreate it?" 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
        try { New-Item -ItemType Directory -Path $libRoot -Force | Out-Null } catch { [void](Show-Msg "Couldn't create it: $($_.Exception.Message)" 'Error'); return }
    }

    $script:lastOutputRoot = if ($plexOn -and $libRoot) { $libRoot } else { $script:sets[$selRows[0].Index].Dir }

    $payload = @(foreach ($r in $selRows) {
        $s = $script:sets[$r.Index]
        $r.Status = 'Queued'

        $plex = $null
        $extractDir = [string]$s.OutputFolder
        if ($plexOn) {
            $parts = $null
            if (Test-IsEpisodeLabel $s.EpisodeLabel) { $parts = Get-PlexParts -Title $s.Title -Label $s.EpisodeLabel }
            if ($parts) {
                $root      = Get-LibraryRootFor $s
                $showDir   = [System.IO.Path]::Combine($root, $parts.Show)
                $seasonDir = [System.IO.Path]::Combine($showDir, $parts.SeasonFolder)
                $plex = [PSCustomObject]@{
                    Enabled   = $true
                    ShowDir   = $showDir
                    SeasonDir = $seasonDir
                    FileBase  = $parts.FileBase
                    Show      = $parts.Show
                }
                $extractDir = [System.IO.Path]::Combine($s.Dir, '.extract_tmp_' + (Get-SafeFolderName -Name $s.BaseName))
            } else {
                $plex = [PSCustomObject]@{ Enabled = $false }
            }
        }

        [PSCustomObject]@{
            Index        = $r.Index
            PrimaryFile  = [string]$s.PrimaryFile.FullName
            OutputFolder = [string]$extractDir
            Files        = @($s.Files | ForEach-Object { $_.FullName })
            BaseName     = [string]$s.BaseName
            Plex         = $plex
        }
    })

    $sync.Completed       = 0
    $sync.Total           = $payload.Count
    $sync.CancelRequested = $false
    $sync.CurrentProc     = $null
    $sync.Running         = $true

    $Progress.Maximum = [Math]::Max(1, $payload.Count)
    $Progress.Value   = 0
    $LblProgress.Text = "0 / $($payload.Count)"
    $LblNow.Text      = 'Starting...'
    $TxtLog.Clear()
    Set-RunningUi $true

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('sync', $sync)
    $runspace.SessionStateProxy.SetVariable('payload', $payload)
    $runspace.SessionStateProxy.SetVariable('deleteAfter', [bool]$ChkDelete.IsChecked)
    $runspace.SessionStateProxy.SetVariable('whatIf', [bool]$ChkPreview.IsChecked)
    $runspace.SessionStateProxy.SetVariable('sevenZip', $script:SevenZipPath)

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($script:WorkerScript.ToString())
    [void]$ps.BeginInvoke()
    $script:currentPs = $ps
    $script:currentRunspace = $runspace
    $script:Timer.Start()
}

# ===========================================================================
# Wiring
# ===========================================================================
$BtnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pick the folder that holds your RAR releases'
    if ($TxtPath.Text -and (Test-Path -LiteralPath $TxtPath.Text)) { $dlg.SelectedPath = $TxtPath.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $TxtPath.Text = $dlg.SelectedPath; Invoke-Scan }
})
$BtnScan.Add_Click({ Invoke-Scan })
$TxtPath.Add_KeyDown({ param($s, $e) if ($e.Key -eq [System.Windows.Input.Key]::Return) { Invoke-Scan } })

$BtnBrowseLib.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pick your Plex TV library folder (the one that holds your show folders)'
    if ($TxtLib.Text -and (Test-Path -LiteralPath $TxtLib.Text)) { $dlg.SelectedPath = $TxtLib.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $TxtLib.Text = $dlg.SelectedPath }
})
$TxtLib.Add_TextChanged({ if ($ChkPlex.IsChecked) { Update-Destinations } })
$ChkPlex.Add_Checked({ Update-PlexState })
$ChkPlex.Add_Unchecked({ Update-PlexState })

$TxtFilter.Add_TextChanged({ $script:View.Refresh() })
$BtnAll.Add_Click({  foreach ($r in $script:View) { $r.IsChecked = $true } })
$BtnNone.Add_Click({ foreach ($r in $script:View) { $r.IsChecked = $false } })

$TglLog.Add_Checked({   $TglLog.Content = 'Hide log' })
$TglLog.Add_Unchecked({ $TglLog.Content = 'Show log' })

$BtnStart.Add_Click({ Start-Queue })
$BtnCancel.Add_Click({
    $sync.CancelRequested = $true
    $LblNow.Text = 'Cancelling...'
    Add-Log 'Cancel requested - stopping the current extraction and skipping the rest...'
    try { $p = $sync.CurrentProc; if ($p -and -not $p.HasExited) { $p.Kill() } } catch { }
})

# Drag a folder (or a file inside it) anywhere onto the window
$win.Add_PreviewDragOver({
    param($s, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { $e.Effects = [System.Windows.DragDropEffects]::Copy }
    else { $e.Effects = [System.Windows.DragDropEffects]::None }
    $e.Handled = $true
})
$win.Add_PreviewDrop({
    param($s, $e)
    $paths = $e.Data.GetData([System.Windows.DataFormats]::FileDrop)
    if ($paths -and $paths.Count -gt 0) {
        $p = [string]$paths[0]
        if (Test-Path -LiteralPath $p -PathType Container) { $TxtPath.Text = $p }
        elseif (Test-Path -LiteralPath $p) { $TxtPath.Text = [System.IO.Path]::GetDirectoryName($p) }
        $e.Handled = $true
        if (-not $sync.Running) { Invoke-Scan }
    }
})

# Right-click menu on the table
$menu = New-Object System.Windows.Controls.ContextMenu
$menu.Style = $win.FindResource('DarkMenu')
function Add-MenuItem {
    param([string]$Header, [scriptblock]$Action)
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $Header
    $mi.Style = $win.FindResource('DarkMenuItem')
    $mi.Add_Click($Action)
    [void]$menu.Items.Add($mi)
}
Add-MenuItem 'Open where it lands' {
    $r = $List.SelectedItem
    if ($r) { $p = Get-DestFolder $script:sets[$r.Index]; if ($p -and (Test-Path -LiteralPath $p)) { Start-Process explorer.exe $p } }
}
Add-MenuItem 'Open source folder' {
    $r = $List.SelectedItem
    if ($r) { $p = $script:sets[$r.Index].Dir; if ($p -and (Test-Path -LiteralPath $p)) { Start-Process explorer.exe $p } }
}
Add-MenuItem 'Remove from list' {
    if ($sync.Running) { return }
    foreach ($r in @($List.SelectedItems)) { [void]$script:Rows.Remove($r); $script:RowByIndex.Remove($r.Index) }
    Update-EmptyState
}
$List.ContextMenu = $menu

# Save settings / stop work on close
$win.Add_Closing({
    if ($sync.Running) { $sync.CancelRequested = $true }
    try { $p = $sync.CurrentProc; if ($p -and -not $p.HasExited) { $p.Kill() } } catch { }
    if ($script:currentPs) {
        try { $script:currentPs.Stop() } catch { }
        try { $script:currentRunspace.Close() } catch { }
    }
    Save-Config ([ordered]@{
        LastFolder   = $TxtPath.Text
        SevenZip     = [string]$script:SevenZipPath
        DeleteAfter  = [bool]$ChkDelete.IsChecked
        PreviewOnly  = [bool]$ChkPreview.IsChecked
        OpenWhenDone = [bool]$ChkOpen.IsChecked
        PlexMode     = [bool]$ChkPlex.IsChecked
        LibraryRoot  = $TxtLib.Text
    })
})

# ===========================================================================
# Initial state + go
# ===========================================================================
$TxtPath.Text       = [string]$script:Config.LastFolder
$TxtLib.Text        = [string]$script:Config.LibraryRoot
$ChkPlex.IsChecked  = [bool]$script:Config.PlexMode
$ChkDelete.IsChecked  = [bool]$script:Config.DeleteAfter
$ChkPreview.IsChecked = [bool]$script:Config.PreviewOnly
$ChkOpen.IsChecked    = [bool]$script:Config.OpenWhenDone
Update-SevenZipBadge
Update-PlexState
Update-EmptyState

try {
    [void]$win.ShowDialog()
} catch {
    Write-StartupError $_.Exception 'running the window'
}
