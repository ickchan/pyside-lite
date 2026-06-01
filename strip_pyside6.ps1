#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Strip unnecessary modules from an installed PySide6 to reduce PyInstaller output size.

.DESCRIPTION
    This script physically removes unused PySide6 modules from a Python environment
    (virtual or system-wide), then optionally runs PyInstaller on a target script.

    It implements "方案B" (post-install stripping) from the research notes.

    Based on measurements (PySide6 6.8.0):
    - Installed Essentials:              103.54 MB
    - After stripping QML/Quick/Designer: ~57 MB  (saved ~46 MB)
    - PyInstaller output (full):          66.56 MB
    - PyInstaller output (after strip):   ~55-60 MB

    For PySide6 6.11.x (includes opengl32sw.dll):
    - Installed Essentials:              202 MB
    - After stripping incl opengl32sw:   ~80 MB
    - PyInstaller output (after strip):  ~70 MB

.PARAMETER PySideDir
    Path to PySide6 directory. If empty, auto-detected from current Python environment.
    Example: "C:\MyProject\venv\Lib\site-packages\PySide6"

.PARAMETER Profile
    Stripping profile:
    - "widgets-minimal"  Remove QML, Quick, Designer, Help, Test, DBus, OpenGL (default)
    - "widgets-standard" Remove QML, Quick, Designer, Help, Test, DBus only
    - "core-gui-only"    Remove everything except Core, Gui, Widgets (aggressive)
    - "custom"           Use -ExcludeModules to specify modules

.PARAMETER ExcludeModules
    When -Profile is "custom", a comma-separated list of modules to remove.
    Example: "Qml,Quick,Designer,Help,Test,DBus"

.PARAMETER KeepTranslations
    Keep translation files (not present in standard Essentials, but may be in full PySide6).

.PARAMETER WhatIf
    Dry run: show what would be deleted without actually deleting.

.PARAMETER AppScript
    If specified, run PyInstaller on this script after stripping and report output size.

.PARAMETER AppName
    Name for the PyInstaller output (used with -AppScript). Default: "myapp"

.EXAMPLE
    # Auto-detect PySide6 in current venv, use default profile (widgets-minimal)
    .\strip_pyside6.ps1

.EXAMPLE
    # Aggressive: keep only Core+Gui+Widgets
    .\strip_pyside6.ps1 -Profile core-gui-only

.EXAMPLE
    # Dry run to preview changes
    .\strip_pyside6.ps1 -WhatIf

.EXAMPLE
    # Strip then build with PyInstaller
    .\strip_pyside6.ps1 -AppScript .\my_app.py -AppName "myapp"

.EXAMPLE
    # Target a specific venv
    .\strip_pyside6.ps1 -PySideDir "C:\Projects\myproject\venv\Lib\site-packages\PySide6"

.NOTES
    IMPORTANT: This modifies your Python environment permanently.
    ALWAYS use a virtual environment (venv), not your system Python.
    To undo changes, reinstall: pip install --force-reinstall PySide6-Essentials
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PySideDir = "",
    [ValidateSet("widgets-minimal", "widgets-standard", "core-gui-only", "custom")]
    [string]$Profile = "widgets-minimal",
    [string]$ExcludeModules = "",
    [switch]$KeepTranslations,
    [string]$AppScript = "",
    [string]$AppName = "myapp"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Helper ──────────────────────────────────────────────────────────────────
function Write-Section([string]$msg) {
    Write-Host ""
    Write-Host "── $msg ──────────────────────────────────────────" -ForegroundColor Cyan
}

function Get-DirSize([string]$path) {
    if (-not (Test-Path $path)) { return 0 }
    (Get-ChildItem $path -Recurse -File | Measure-Object -Property Length -Sum).Sum
}

function Remove-IfExists([string]$path, [switch]$recurse) {
    if (Test-Path $path) {
        $size = if ($recurse) { Get-DirSize $path } else { (Get-Item $path).Length }
        $sizeMb = [math]::Round($size / 1MB, 2)
        if ($WhatIfPreference) {
            Write-Host "  [WOULD DELETE] $path ($sizeMb MB)"
        } else {
            if ($recurse) {
                Remove-Item $path -Recurse -Force
            } else {
                Remove-Item $path -Force
            }
            Write-Host "  [DELETED] $path ($sizeMb MB)" -ForegroundColor Yellow
        }
        return $size
    }
    return 0
}

# ── Detect PySide6 directory ──────────────────────────────────────────────────
Write-Section "Locating PySide6"

if (-not $PySideDir) {
    $PySideDir = python -c "import PySide6, os; print(os.path.dirname(PySide6.__file__))" 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $PySideDir)) {
        Write-Host "ERROR: Cannot locate PySide6. Is it installed in the current Python environment?" -ForegroundColor Red
        Write-Host "Run: pip install PySide6-Essentials" -ForegroundColor Yellow
        exit 1
    }
}

if (-not (Test-Path $PySideDir)) {
    Write-Host "ERROR: PySide6 directory not found: $PySideDir" -ForegroundColor Red
    exit 1
}

$pysideVersion = python -c "import PySide6; print(PySide6.__version__)" 2>&1
Write-Host "PySide6 $pysideVersion at: $PySideDir"

$sizeBefore = Get-DirSize $PySideDir
Write-Host "Size before stripping: $([math]::Round($sizeBefore/1MB,2)) MB"

# ── Safety check: warn if not in venv ────────────────────────────────────────
$inVenv = $env:VIRTUAL_ENV -or (python -c "import sys; print(hasattr(sys, 'real_prefix') or (hasattr(sys, 'base_prefix') and sys.base_prefix != sys.prefix))" 2>&1) -eq "True"
if (-not $inVenv) {
    Write-Host ""
    Write-Host "WARNING: You do not appear to be in a virtual environment!" -ForegroundColor Red
    Write-Host "This script will PERMANENTLY delete files from your Python installation." -ForegroundColor Red
    Write-Host "It is STRONGLY recommended to use a venv." -ForegroundColor Red
    Write-Host ""
    $confirm = Read-Host "Type 'yes' to continue anyway, or anything else to abort"
    if ($confirm -ne "yes") {
        Write-Host "Aborted."
        exit 0
    }
}

# ── Define module-to-file mappings ───────────────────────────────────────────
# Each entry: ModuleName -> @{ dlls = @(...); pyds = @(...); dirs = @(...) }
# File patterns are relative to $PySideDir
$moduleFiles = @{
    "Qml" = @{
        dlls = @("Qt6Qml.dll", "Qt6QmlCompiler.dll", "Qt6QmlModels.dll", "Qt6QmlMeta.dll",
                 "Qt6QmlCore.dll", "Qt6QmlNetwork.dll", "Qt6QmlLocalStorage.dll",
                 "Qt6QmlWorkerScript.dll", "Qt6QmlXmlListModel.dll", "Qt6LabsQmlModels.dll")
        pyds = @("QtQml.pyd")
        dirs = @()
    }
    "Quick" = @{
        dlls = @("Qt6Quick.dll", "Qt6QuickControls2.dll", "Qt6QuickControls2Basic.dll",
                 "Qt6QuickControls2BasicStyleImpl.dll", "Qt6QuickControls2Fusion.dll",
                 "Qt6QuickControls2FusionStyleImpl.dll", "Qt6QuickControls2Imagine.dll",
                 "Qt6QuickControls2ImagineStyleImpl.dll", "Qt6QuickControls2Impl.dll",
                 "Qt6QuickControls2Material.dll", "Qt6QuickControls2MaterialStyleImpl.dll",
                 "Qt6QuickControls2Universal.dll", "Qt6QuickControls2UniversalStyleImpl.dll",
                 "Qt6QuickControls2FluentWinUI3StyleImpl.dll",
                 "Qt6QuickControls2WindowsStyleImpl.dll",
                 "Qt6QuickDialogs2.dll", "Qt6QuickDialogs2QuickImpl.dll",
                 "Qt6QuickDialogs2Utils.dll", "Qt6QuickEffects.dll", "Qt6QuickLayouts.dll",
                 "Qt6QuickParticles.dll", "Qt6QuickShapes.dll", "Qt6QuickTemplates2.dll",
                 "Qt6QuickTest.dll", "Qt6QuickTimeline.dll", "Qt6QuickTimelineBlendTrees.dll",
                 "Qt6QuickVectorImage.dll", "Qt6QuickVectorImageGenerator.dll",
                 "Qt6QuickWidgets.dll", "Qt6LabsPlatform.dll", "Qt6LabsFolderListModel.dll",
                 "Qt6LabsSettings.dll", "Qt6LabsWavefrontMesh.dll", "Qt6LabsSharedImage.dll",
                 "Qt6LabsAnimation.dll", "pyside6qml.abi3.dll")
        pyds = @("QtQuick.pyd", "QtQuickControls2.pyd", "QtQuickTest.pyd",
                 "QtQuickWidgets.pyd", "QtExampleIcons.pyd")
        dirs = @()
    }
    "Designer" = @{
        dlls = @("Qt6Designer.dll", "Qt6DesignerComponents.dll")
        pyds = @("QtDesigner.pyd")
        dirs = @()
    }
    "Help" = @{
        dlls = @("Qt6Help.dll")
        pyds = @("QtHelp.pyd")
        dirs = @()
    }
    "Test" = @{
        dlls = @("Qt6Test.dll", "Qt6QuickTest.dll")
        pyds = @("QtTest.pyd")
        dirs = @()
    }
    "DBus" = @{
        dlls = @("Qt6DBus.dll")
        pyds = @("QtDBus.pyd")
        dirs = @()
    }
    "OpenGL" = @{
        dlls = @("Qt6OpenGL.dll", "Qt6OpenGLWidgets.dll", "opengl32sw.dll")
        pyds = @("QtOpenGL.pyd", "QtOpenGLWidgets.pyd")
        dirs = @()
    }
    "Network" = @{
        dlls = @("Qt6Network.dll")
        pyds = @("QtNetwork.pyd")
        dirs = @()
    }
    "Sql" = @{
        dlls = @("Qt6Sql.dll")
        pyds = @("QtSql.pyd")
        dirs = @()
    }
    "PrintSupport" = @{
        dlls = @("Qt6PrintSupport.dll")
        pyds = @("QtPrintSupport.pyd")
        dirs = @()
    }
    "UiTools" = @{
        dlls = @("Qt6UiTools.dll")
        pyds = @("QtUiTools.pyd")
        dirs = @()
    }
    "Svg" = @{
        dlls = @("Qt6Svg.dll", "Qt6SvgWidgets.dll")
        pyds = @("QtSvg.pyd", "QtSvgWidgets.pyd")
        dirs = @()
    }
    "Xml" = @{
        dlls = @("Qt6Xml.dll")
        pyds = @("QtXml.pyd")
        dirs = @()
    }
    "Concurrent" = @{
        dlls = @("Qt6Concurrent.dll")
        pyds = @("QtConcurrent.pyd")
        dirs = @()
    }
    # opengl32sw.dll only (no Qt module, just the Mesa software renderer)
    "SoftwareOpenGL" = @{
        dlls = @("opengl32sw.dll")
        pyds = @()
        dirs = @()
    }
}

# ── Define profiles ──────────────────────────────────────────────────────────
$profiles = @{
    "widgets-minimal"  = @("Qml", "Quick", "Designer", "Help", "Test", "DBus", "OpenGL", "SoftwareOpenGL")
    "widgets-standard" = @("Qml", "Quick", "Designer", "Help", "Test", "DBus", "SoftwareOpenGL")
    "core-gui-only"    = @("Qml", "Quick", "Designer", "Help", "Test", "DBus", "OpenGL", "SoftwareOpenGL",
                            "Network", "Sql", "PrintSupport", "UiTools", "Svg", "Xml", "Concurrent")
    "custom"           = @()
}

# ── Determine which modules to strip ─────────────────────────────────────────
Write-Section "Stripping profile: $Profile"

$modulesToStrip = @()
if ($Profile -eq "custom") {
    if (-not $ExcludeModules) {
        Write-Host "ERROR: -ExcludeModules required when -Profile is 'custom'" -ForegroundColor Red
        exit 1
    }
    $modulesToStrip = $ExcludeModules -split "," | ForEach-Object { $_.Trim() }
} else {
    $modulesToStrip = $profiles[$Profile]
}

Write-Host "Will strip modules: $($modulesToStrip -join ', ')"

# ── Execute stripping ─────────────────────────────────────────────────────────
Write-Section "Removing files"

$totalRemoved = 0

foreach ($mod in $modulesToStrip) {
    if (-not $moduleFiles.ContainsKey($mod)) {
        Write-Host "  [SKIP] Unknown module: $mod" -ForegroundColor DarkYellow
        continue
    }

    $spec = $moduleFiles[$mod]
    $modRemoved = 0

    # Remove DLLs
    foreach ($dll in $spec.dlls) {
        $path = Join-Path $PySideDir $dll
        $modRemoved += Remove-IfExists $path
    }

    # Remove .pyd files
    foreach ($pyd in $spec.pyds) {
        $path = Join-Path $PySideDir $pyd
        $modRemoved += Remove-IfExists $path
    }

    # Remove .pyi stubs (type hints, safe to remove)
    foreach ($pyd in $spec.pyds) {
        $pyiPath = Join-Path $PySideDir ($pyd -replace "\.pyd$", ".pyi")
        $modRemoved += Remove-IfExists $pyiPath
    }

    # Remove directories
    foreach ($dir in $spec.dirs) {
        $path = Join-Path $PySideDir $dir
        $modRemoved += Remove-IfExists $path -recurse
    }

    if ($modRemoved -gt 0) {
        Write-Host "  → Removed $mod: $([math]::Round($modRemoved/1MB,2)) MB" -ForegroundColor DarkGray
    }
    $totalRemoved += $modRemoved
}

# Remove translations directory (usually empty in Essentials, present in full PySide6)
if (-not $KeepTranslations) {
    $transDir = Join-Path $PySideDir "translations"
    if (Test-Path $transDir) {
        $totalRemoved += Remove-IfExists $transDir -recurse
    }
}

# Remove qml directory
$qmlDir = Join-Path $PySideDir "qml"
if ($modulesToStrip -contains "Qml" -or $modulesToStrip -contains "Quick") {
    if (Test-Path $qmlDir) {
        Write-Host ""
        Write-Host "  Removing qml/ directory..."
        $totalRemoved += Remove-IfExists $qmlDir -recurse
    }
}

# ── Report results ────────────────────────────────────────────────────────────
Write-Section "Results"

$sizeAfter = Get-DirSize $PySideDir
$savedMb = [math]::Round($totalRemoved / 1MB, 2)
$beforeMb = [math]::Round($sizeBefore / 1MB, 2)
$afterMb = [math]::Round($sizeAfter / 1MB, 2)

Write-Host "  Size before: $beforeMb MB"
Write-Host "  Size after:  $afterMb MB" -ForegroundColor Green
Write-Host "  Saved:       $savedMb MB ($([math]::Round($totalRemoved/$sizeBefore*100,1))%)" -ForegroundColor Green

if ($WhatIfPreference) {
    Write-Host ""
    Write-Host "DRY RUN COMPLETE. No files were actually deleted." -ForegroundColor Yellow
    Write-Host "Re-run without -WhatIf to apply changes."
    exit 0
}

# ── Optional: Run PyInstaller ─────────────────────────────────────────────────
if ($AppScript) {
    if (-not (Test-Path $AppScript)) {
        Write-Host "ERROR: AppScript not found: $AppScript" -ForegroundColor Red
        exit 1
    }

    Write-Section "Running PyInstaller on $AppScript"

    $pyinstallerAvail = $null -ne (Get-Command pyinstaller -ErrorAction SilentlyContinue)
    if (-not $pyinstallerAvail) {
        Write-Host "PyInstaller not found. Installing..."
        pip install pyinstaller
    }

    pyinstaller --onedir --name $AppName $AppScript
    if ($LASTEXITCODE -ne 0) {
        Write-Host "PyInstaller failed!" -ForegroundColor Red
        exit 1
    }

    $distPath = ".\dist\$AppName"
    if (Test-Path $distPath) {
        $distSize = (Get-ChildItem $distPath -Recurse | Measure-Object -Property Length -Sum).Sum
        $distCount = (Get-ChildItem $distPath -Recurse -File).Count
        Write-Host ""
        Write-Host "PyInstaller output:" -ForegroundColor Green
        Write-Host "  Path:  $distPath"
        Write-Host "  Size:  $([math]::Round($distSize/1MB,2)) MB ($distCount files)" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "DONE." -ForegroundColor Green
Write-Host "To undo: pip install --force-reinstall PySide6-Essentials"
