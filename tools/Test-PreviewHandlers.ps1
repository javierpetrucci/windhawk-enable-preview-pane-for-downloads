<#
.SYNOPSIS
Checks whether the File Explorer preview pane shows a PDF that has the Mark of
the Web, once for each registered PDF preview handler.

.DESCRIPTION
For each handler, the script:
  1. Sets the per-user preview handler for the extension (HKCU).
  2. Restarts File Explorer and the preview host, so the change is applied and
     Windhawk injects the mod into the new Explorer process.
  3. Opens a window that selects the test file. The preview pane must already
     be on (Alt+P in File Explorer); the script never toggles it.
  4. Reports PREVIEWED (a prevhost.exe window is shown in the pane and the
     handler DLL is loaded), BLOCKED (the "could harm your computer" text is
     shown) or UNKNOWN, and saves a screenshot of the window.

The OptIn column shows whether the handler sets AutomaticallyPreviewUntrustedFiles
on its CLSID key (for example the PDF previewer of Microsoft Edge). shell32
skips the zone check for such handlers, but only when an internal feature is
on, so the effect depends on the Windows build. To check it, disable the mod
and run the script: a handler that is still PREVIEWED is exempted by Windows.

Run the script from a normal PowerShell window. A host that virtualizes
HKCU\Software\Classes (for example a packaged app) changes only its own view
of the registry, and File Explorer keeps using the original handler.

A control file (a type that isn't in the mod settings and whose handler doesn't
opt in, with the Mark of the Web, in a temporary folder) checks that BLOCKED is
detected when the preview is not exempted.

The original HKCU preview handler setting is always restored at the end, and
the test file is only read. File Explorer is restarted several times, so open
Explorer windows are closed.

.PARAMETER File
The test file. It must have a Zone.Identifier stream. Defaults to the first
PDF in Downloads that has one.

.PARAMETER Handlers
CLSIDs of the preview handlers to test. Defaults to every registered preview
handler whose name mentions PDF, plus the machine-wide handler for .pdf.

.PARAMETER Timeout
Seconds to wait for a preview or the warning, per handler.

.PARAMETER SkipControl
Skips the control check.

.PARAMETER ControlOnly
Only runs the control check, without changing the handler or restarting File
Explorer. Useful to check that the detection works.

.PARAMETER Force
Doesn't ask for confirmation before restarting File Explorer.

.EXAMPLE
.\Test-PreviewHandlers.ps1
.\Test-PreviewHandlers.ps1 -File "$env:USERPROFILE\Downloads\Offset.pdf"
.\Test-PreviewHandlers.ps1 -ControlOnly
#>
[CmdletBinding()]
param(
    [string]$File,
    [string[]]$Handlers,
    [int]$Timeout = 15,
    [string]$WarningText = 'could harm your computer',
    [switch]$SkipControl,
    [switch]$ControlOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class PreviewTestNative {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr parent, EnumProc proc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int count);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")]
    public static extern IntPtr FindWindow(string className, string windowName);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    // Returns "pid|class" for every visible child window.
    public static List<string> VisibleChildren(IntPtr parent) {
        var result = new List<string>();
        EnumChildWindows(parent, (h, l) => {
            if (IsWindowVisible(h)) {
                var name = new StringBuilder(256);
                GetClassName(h, name, name.Capacity);
                uint pid;
                GetWindowThreadProcessId(h, out pid);
                result.Add(pid + "|" + name);
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
'@

$handlerKeyPath = 'HKCU:\Software\Classes\.pdf\ShellEx\{8895b1c6-b41f-4c1c-a562-0d564250836f}'

# Reads a registry value (the default value when Name is empty), or $null.
function Get-RegValue([string]$Path, [string]$Name = '') {
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $key) { return $null }
    $key.GetValue($Name)
}

function Get-HandlerInfo([string]$Clsid) {
    $clsidKey = "Registry::HKEY_CLASSES_ROOT\CLSID\$Clsid"
    $name = Get-RegValue $clsidKey
    # shell32 skips the zone check for handlers that set this value, but only
    # when an internal feature is on.
    $optInValue = Get-RegValue $clsidKey 'AutomaticallyPreviewUntrustedFiles'
    $optIn = [bool]($null -ne $optInValue -and [int]$optInValue -ne 0)
    $dll = Get-RegValue "$clsidKey\InprocServer32"
    if ($dll) { $dll = [Environment]::ExpandEnvironmentVariables($dll) }
    [pscustomobject]@{ Clsid = $Clsid; Name = $name; Dll = $dll; OptIn = $optIn }
}

# Returns the preview handler CLSID registered for an extension, or $null.
function Get-ExtensionHandler([string]$Extension) {
    $shellEx = 'ShellEx\{8895b1c6-b41f-4c1c-a562-0d564250836f}'
    $keys = @("Registry::HKEY_CLASSES_ROOT\.$Extension\$shellEx")
    $progId = Get-RegValue "Registry::HKEY_CLASSES_ROOT\.$Extension"
    if ($progId) { $keys += "Registry::HKEY_CLASSES_ROOT\$progId\$shellEx" }
    $keys += "Registry::HKEY_CLASSES_ROOT\SystemFileAssociations\.$Extension\$shellEx"
    foreach ($key in $keys) {
        $value = Get-RegValue $key
        if ($value) { return $value }
    }
    return $null
}

# Extensions listed in the mod settings, if Windhawk's settings can be read.
function Get-ModExtensions {
    $key = 'HKLM:\SOFTWARE\Windhawk\Engine\Mods\local@enable-preview-pane-for-downloads\Settings'
    $value = Get-RegValue $key 'extensions'
    if (-not $value) { return @('pdf') }
    @($value -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { $_.TrimStart('.').ToLowerInvariant() })
}

function Get-DefaultHandlers {
    $clsids = New-Object System.Collections.Generic.List[string]
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PreviewHandlers',
                     'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PreviewHandlers') {
        $item = Get-Item $key -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($valueName in $item.GetValueNames()) {
            $display = [string]$item.GetValue($valueName)
            # Keep PDF handlers, skip entries for other types such as
            # "SumatraPDF Preview (*.epub)".
            if ($display -match 'pdf' -and $display -notmatch '\(\*\.(?!pdf\))') {
                $clsids.Add($valueName)
            }
        }
    }
    $machine = Get-RegValue 'HKLM:\Software\Classes\.pdf\ShellEx\{8895b1c6-b41f-4c1c-a562-0d564250836f}'
    if ($machine) { $clsids.Add($machine) }
    $clsids | ForEach-Object { $_.ToUpperInvariant() } | Select-Object -Unique
}

function Restart-Explorer {
    Stop-Process -Name prevhost -Force -ErrorAction SilentlyContinue
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ([PreviewTestNative]::FindWindow('Shell_TrayWnd', $null) -ne [IntPtr]::Zero) { break }
    }
    if ([PreviewTestNative]::FindWindow('Shell_TrayWnd', $null) -eq [IntPtr]::Zero) {
        Start-Process explorer.exe
        Start-Sleep -Seconds 5
    }
    # Gives Windhawk time to load the mod into the new Explorer process, and
    # shell extensions time to load.
    Start-Sleep -Seconds 10
}

function Open-SelectedFile([string]$Path) {
    $shell = New-Object -ComObject Shell.Application
    $before = @($shell.Windows() | ForEach-Object { [int64]$_.HWND })
    Start-Process explorer.exe "/select,`"$Path`""
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        foreach ($window in $shell.Windows()) {
            if ($before -notcontains [int64]$window.HWND) { return $window }
        }
    }
    throw "No File Explorer window opened for $Path"
}

# Returns an element that only exists while the preview pane is shown, or $null.
function Find-PaneElement([IntPtr]$Hwnd) {
    $root = [Windows.Automation.AutomationElement]::FromHandle($Hwnd)
    foreach ($className in 'ReadingPaneModuleInner', 'PreviewThumbnailInner') {
        $condition = New-Object Windows.Automation.PropertyCondition(
            [Windows.Automation.AutomationElement]::ClassNameProperty, $className)
        $element = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
        if ($element) { return $element }
    }
    return $null
}

# The warning is a text element in the preview pane, next to a "Preview
# anyway" button.
function Test-WarningShown([IntPtr]$Hwnd) {
    $root = [Windows.Automation.AutomationElement]::FromHandle($Hwnd)
    $condition = New-Object Windows.Automation.PropertyCondition(
        [Windows.Automation.AutomationElement]::ControlTypeProperty,
        [Windows.Automation.ControlType]::Text)
    foreach ($element in $root.FindAll([Windows.Automation.TreeScope]::Descendants, $condition)) {
        if ($element.Current.Name -like "*$WarningText*") { return $true }
    }
    return $false
}

function Get-PrevhostWindows([IntPtr]$Hwnd) {
    $pids = @(Get-Process prevhost -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Id })
    if (-not $pids) { return @() }
    @([PreviewTestNative]::VisibleChildren($Hwnd) | Where-Object { $pids -contains $_.Split('|')[0] })
}

# Visible child windows of the Explorer window that belong to other processes,
# as "process:class". Some handlers draw the preview in their own process (for
# example Adobe Acrobat).
function Get-ForeignWindows([IntPtr]$Hwnd) {
    $explorerPid = [uint32]0
    [void][PreviewTestNative]::GetWindowThreadProcessId($Hwnd, [ref]$explorerPid)
    $names = @{}
    foreach ($entry in [PreviewTestNative]::VisibleChildren($Hwnd)) {
        $parts = $entry.Split('|')
        if ($parts[0] -eq [string]$explorerPid) { continue }
        if (-not $names.ContainsKey($parts[0])) {
            $process = Get-Process -Id $parts[0] -ErrorAction SilentlyContinue
            $names[$parts[0]] = if ($process) { $process.ProcessName } else { $parts[0] }
        }
        "$($names[$parts[0]]):$($parts[1])"
    }
}

function Test-ModuleLoaded([string]$Dll) {
    if (-not $Dll) { return $false }
    foreach ($process in Get-Process prevhost -ErrorAction SilentlyContinue) {
        try {
            foreach ($module in $process.Modules) {
                if ($module.FileName -ieq $Dll) { return $true }
            }
        } catch {
            # 32-bit prevhost or access denied.
        }
    }
    return $false
}

# Captures the window with PrintWindow, which also works when other windows
# cover it.
function Save-WindowScreenshot([IntPtr]$Hwnd, [string]$Path) {
    [void][PreviewTestNative]::ShowWindow($Hwnd, 9)  # SW_RESTORE
    Start-Sleep -Milliseconds 700
    $rect = New-Object PreviewTestNative+RECT
    [void][PreviewTestNative]::GetWindowRect($Hwnd, [ref]$rect)
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) { return }
    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $hdc = $graphics.GetHdc()
    # PW_RENDERFULLCONTENT includes content drawn by other processes.
    $printed = [PreviewTestNative]::PrintWindow($Hwnd, $hdc, 2)
    $graphics.ReleaseHdc($hdc)
    if (-not $printed) {
        $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
    }
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose()
    $bitmap.Dispose()
}

# Opens the file, waits for a result and returns PREVIEWED, BLOCKED or UNKNOWN.
function Invoke-PreviewCheck([string]$Path, [string]$Dll, [string]$Screenshot) {
    $window = Open-SelectedFile $Path
    $hwnd = [IntPtr][int64]$window.HWND
    try {
        $result = 'UNKNOWN'
        $deadline = (Get-Date).AddSeconds($Timeout)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            if (Test-WarningShown $hwnd) { $result = 'BLOCKED'; break }
            if (@(Get-PrevhostWindows $hwnd).Count -gt 0) {
                # Lets the handler finish drawing before the screenshot.
                Start-Sleep -Seconds 2
                $result = 'PREVIEWED'
                break
            }
        }

        $paneFound = $result -ne 'UNKNOWN' -or [bool](Find-PaneElement $hwnd)
        if (-not $paneFound) {
            Write-Warning 'The preview pane seems to be off. Turn it on in File Explorer (Alt+P) and run the script again.'
        }

        $details = [pscustomobject]@{
            Result         = $result
            PaneFound      = $paneFound
            PrevhostWindow = ((Get-PrevhostWindows $hwnd) | ForEach-Object { $_.Split('|')[1] }) -join ', '
            PaneWindows    = (@(Get-ForeignWindows $hwnd) | Select-Object -Unique) -join ', '
            DllLoaded      = Test-ModuleLoaded $Dll
        }
        Save-WindowScreenshot $hwnd $Screenshot
        return $details
    } finally {
        try { $window.Quit() } catch { }
    }
}

# The control is a file with the Mark of the Web whose type is not in the mod
# settings, so Windows must block it. It checks that BLOCKED is detected.
# Handlers that set AutomaticallyPreviewUntrustedFiles are avoided, in case the
# feature that honors it is on.
function Invoke-ControlCheck([string]$OutDir) {
    $modExtensions = Get-ModExtensions
    $extension = $null
    foreach ($candidate in 'xps', 'epub', 'djvu', 'docx', 'xlsx', 'pptx', 'odt') {
        if ($modExtensions -contains $candidate) { continue }
        $clsid = Get-ExtensionHandler $candidate
        if ($clsid -and -not (Get-HandlerInfo $clsid).OptIn) {
            $extension = $candidate
            break
        }
    }
    if (-not $extension) {
        Write-Warning 'No suitable control type found, skipping the control check'
        return $null
    }

    Write-Host "== Control: .$extension with the Mark of the Web (expected BLOCKED)"
    $controlDir = Join-Path $OutDir 'control'
    New-Item -ItemType Directory -Path $controlDir | Out-Null
    $control = Join-Path $controlDir "control.$extension"
    Set-Content -LiteralPath $control -Value 'Control file for the preview test.' -Encoding Ascii
    Set-Content -LiteralPath $control -Stream Zone.Identifier -Encoding Ascii `
        -Value "[ZoneTransfer]`r`nZoneId=3`r`nHostUrl=https://example.com/control.$extension"
    $shot = Join-Path $OutDir "control-$extension.png"
    $check = Invoke-PreviewCheck $control $null $shot
    Write-Host "    $($check.Result)  (preview pane found: $($check.PaneFound))"
    [pscustomobject]@{
        Test           = "Control .$extension (expected BLOCKED)"
        Result         = $check.Result
        OptIn          = $false
        PrevhostWindow = $check.PrevhostWindow
        PaneWindows    = $check.PaneWindows
        DllLoaded      = ''
        Screenshot     = $shot
    }
}

$outDir = Join-Path $env:TEMP ("preview-handler-test-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $outDir | Out-Null

if ($ControlOnly) {
    $control = Invoke-ControlCheck $outDir
    if ($control) { $control | Format-List | Out-String | Write-Host }
    return
}

# --- Test file ---------------------------------------------------------------

if (-not $File) {
    $File = Get-ChildItem "$env:USERPROFILE\Downloads" -Filter *.pdf -File -ErrorAction SilentlyContinue |
        Where-Object { Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue } |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $File) { throw 'No PDF with a Zone.Identifier stream found in Downloads. Use -File.' }
}
$File = (Resolve-Path -LiteralPath $File).ProviderPath
if (-not (Get-Item -LiteralPath $File -Stream Zone.Identifier -ErrorAction SilentlyContinue)) {
    throw "The test file has no Zone.Identifier stream, so Windows would preview it anyway: $File"
}

if (-not $Handlers) { $Handlers = Get-DefaultHandlers }
$handlerInfos = @($Handlers | ForEach-Object { Get-HandlerInfo $_ })
$missing = @($handlerInfos | Where-Object { -not $_.Dll -or -not (Test-Path -LiteralPath $_.Dll) })
foreach ($handler in $missing) {
    Write-Warning "Skipping $($handler.Clsid) ($($handler.Name)): handler DLL not found"
}
$handlerInfos = @($handlerInfos | Where-Object { $missing -notcontains $_ })
if (-not $handlerInfos) { throw 'No preview handlers to test.' }

Write-Host "Test file: $File"
Write-Host 'Handlers:'
foreach ($handler in $handlerInfos) {
    $note = ''
    if ($handler.OptIn) {
        $note = '  [sets AutomaticallyPreviewUntrustedFiles]'
    }
    Write-Host "  $($handler.Clsid)  $($handler.Name)$note"
}
Write-Host "Output: $outDir"
Write-Host ''
Write-Host 'Before running: enable the mod in Windhawk (or disable it for a baseline run), and disable local@skip-mark-of-the-web.'
Write-Host 'File Explorer will be restarted several times, and open Explorer windows will close.'
if (-not $Force) {
    $answer = Read-Host 'Continue? (y/n)'
    if ($answer -notmatch '^(y|s)') { return }
}

# --- Back up the HKCU setting ------------------------------------------------

$hadKey = Test-Path $handlerKeyPath
$originalValue = $null
if ($hadKey) { $originalValue = (Get-Item $handlerKeyPath).GetValue('') }

$results = New-Object System.Collections.Generic.List[object]
try {
    foreach ($handler in $handlerInfos) {
        Write-Host "== $($handler.Name) $($handler.Clsid)"
        if (-not (Test-Path $handlerKeyPath)) { New-Item -Path $handlerKeyPath -Force | Out-Null }
        Set-Item -Path $handlerKeyPath -Value $handler.Clsid
        Restart-Explorer

        $safeName = ($handler.Name -replace '[^\w\-]+', '_').Trim('_')
        $shot = Join-Path $outDir "$safeName.png"
        $check = Invoke-PreviewCheck $File $handler.Dll $shot
        Write-Host "    $($check.Result)  (handler DLL loaded: $($check.DllLoaded))"
        Write-Host "    windows of other processes in the window: $($check.PaneWindows)"
        $results.Add([pscustomobject]@{
            Test           = $handler.Name
            Result         = $check.Result
            OptIn          = $handler.OptIn
            PrevhostWindow = $check.PrevhostWindow
            PaneWindows    = $check.PaneWindows
            DllLoaded      = $check.DllLoaded
            Screenshot     = $shot
        })
    }

    if (-not $SkipControl) {
        $control = Invoke-ControlCheck $outDir
        if ($control) { $results.Add($control) }
    }
} finally {
    Write-Host '== Restoring the original preview handler setting'
    if ($hadKey) {
        Set-Item -Path $handlerKeyPath -Value $originalValue
    } elseif (Test-Path $handlerKeyPath) {
        Remove-Item -Path $handlerKeyPath -Force
    }
    Restart-Explorer
}

$stillMarked = [bool](Get-Item -LiteralPath $File -Stream Zone.Identifier -ErrorAction SilentlyContinue)
Write-Host ''
$results | Format-Table Test, Result, OptIn, DllLoaded, PaneWindows -AutoSize | Out-String -Width 250 | Write-Host
Write-Host 'OptIn = True means the handler sets AutomaticallyPreviewUntrustedFiles. To check whether'
Write-Host 'Windows exempts it on this build, disable the mod and run the script: a handler that is'
Write-Host 'still PREVIEWED is exempted by Windows.'
Write-Host 'If the DllLoaded column is False for a PREVIEWED handler, another handler drew the preview.'
Write-Host 'PREVIEWED means the warning was not shown and a preview host window appeared. Check the'
Write-Host 'screenshots to see whether the handler drew the document.'
Write-Host "Zone.Identifier still present on the test file: $stillMarked"
Write-Host "Screenshots: $outDir"
$results | Format-Table -AutoSize | Out-String -Width 300 | Set-Content (Join-Path $outDir 'results.txt')
"Zone.Identifier still present: $stillMarked" | Add-Content (Join-Path $outDir 'results.txt')
