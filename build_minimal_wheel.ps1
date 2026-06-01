#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Build a minimal PySide6 wheel on Windows (non-Docker, native build).

.DESCRIPTION
    This script builds a custom PySide6 wheel with a minimal module subset.
    It handles environment setup validation and runs the pyside-setup build system.

    Prerequisites (must be installed before running this script):
    - Python 3.10-3.14 (64-bit)
    - Visual Studio 2022 or VS Build Tools 2022 with MSVC v143 + Windows SDK
    - Qt 6.x installed via Qt Installer or aqtinstall
    - Clang/LLVM (Qt-specific build from https://download.qt.io/development_releases/prebuilt/libclang/)
    - CMake 3.18+ (included with VS Build Tools or via choco install cmake)
    - Ninja (via choco install ninja or pip install ninja)

.PARAMETER QtVersion
    Qt version to build against. Default: 6.8.3

.PARAMETER ModuleSubset
    Comma-separated list of Qt modules to include. Default: Core,Gui,Widgets
    Available modules: Core,Gui,Widgets,Network,Xml,Svg,SvgWidgets,OpenGL,OpenGLWidgets,
    PrintSupport,Sql,Help,Test,UiTools,Concurrent,DBus,Qml,Quick,QuickControls2,
    QuickWidgets,QuickTest,Designer

.PARAMETER QtPath
    Path to Qt installation. Default: C:\Qt\<QtVersion>\msvc2019_64
    Must contain bin\qtpaths6.exe

.PARAMETER LlvmPath
    Path to Qt-specific Clang installation. Default: C:\libclang

.PARAMETER PysideTag
    Git tag for pyside-setup clone. Default: v<QtVersion>

.PARAMETER OutputDir
    Directory for the built wheel. Default: .\dist_wheels

.PARAMETER ParallelJobs
    Number of parallel compile jobs. Default: CPU count

.PARAMETER SkipClone
    Skip git clone if pyside-setup directory already exists.

.PARAMETER VcvarsallPath
    Path to vcvarsall.bat. Default: auto-detected from VS 2022/2019.

.EXAMPLE
    # Minimal Core+Gui+Widgets wheel
    .\build_minimal_wheel.ps1

.EXAMPLE
    # Larger but still small: add Network, Svg, Xml
    .\build_minimal_wheel.ps1 -ModuleSubset "Core,Gui,Widgets,Network,Svg,SvgWidgets,Xml"

.EXAMPLE
    # Specify Qt path explicitly
    .\build_minimal_wheel.ps1 -QtPath "C:\Qt\6.8.3\msvc2019_64" -LlvmPath "C:\libclang"

.NOTES
    Build time: 2-4 hours on a modern machine.
    Disk space required: ~10-15 GB during build.

    SIZE EXPECTATIONS (based on measurements with PySide6 6.8.0):
    - Core+Gui+Widgets:             wheel ~55-65 MB, PyInstaller output ~55-60 MB
    - + Network,Svg,SvgWidgets,Xml: wheel ~65-75 MB, PyInstaller output ~60-65 MB
    - Full Essentials (no Addons):  wheel ~103 MB,   PyInstaller output ~67-97 MB
#>

[CmdletBinding()]
param(
    [string]$QtVersion = "6.8.3",
    [string]$ModuleSubset = "Core,Gui,Widgets",
    [string]$QtPath = "",
    [string]$LlvmPath = "C:\libclang",
    [string]$PysideTag = "",
    [string]$OutputDir = ".\dist_wheels",
    [int]$ParallelJobs = 0,
    [switch]$SkipClone,
    [string]$VcvarsallPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Defaults ──────────────────────────────────────────────────────────────────
if (-not $QtPath) {
    $QtPath = "C:\Qt\$QtVersion\msvc2019_64"
}
if (-not $PysideTag) {
    $PysideTag = "v$QtVersion"
}
if ($ParallelJobs -le 0) {
    $ParallelJobs = [System.Environment]::ProcessorCount
}

$WorkDir = ".\pyside-build-src"
$DistDir = Resolve-Path (New-Item -ItemType Directory -Force $OutputDir) | Select-Object -ExpandProperty Path

# ── Helper functions ──────────────────────────────────────────────────────────
function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
}

function Write-Check([string]$item, [bool]$ok, [string]$detail = "") {
    if ($ok) {
        Write-Host "  [OK] $item" -ForegroundColor Green
        if ($detail) { Write-Host "       $detail" -ForegroundColor DarkGray }
    } else {
        Write-Host "  [FAIL] $item" -ForegroundColor Red
        if ($detail) { Write-Host "       $detail" -ForegroundColor Yellow }
    }
}

# ── Step 1: Validate prerequisites ───────────────────────────────────────────
Write-Step "Validating prerequisites"

$errors = @()

# Python check
$pythonVersion = python --version 2>&1
$pythonOk = $pythonVersion -match "3\.(1[0-4])"
Write-Check "Python 3.10-3.14" $pythonOk $pythonVersion
if (-not $pythonOk) { $errors += "Python 3.10-3.14 required. Found: $pythonVersion" }

# Qt check
$qtpaths = "$QtPath\bin\qtpaths6.exe"
$qtOk = Test-Path $qtpaths
Write-Check "Qt at $QtPath" $qtOk
if (-not $qtOk) {
    $errors += "Qt not found at $QtPath. Install Qt $QtVersion msvc2019_64 or set -QtPath"
    Write-Host "  Hint: pip install aqtinstall && python -m aqt install-qt windows desktop $QtVersion win64_msvc2019_64 -O C:\Qt" -ForegroundColor Yellow
}

# LLVM/Clang check
$llvmOk = Test-Path "$LlvmPath\bin\clang.exe"
Write-Check "Qt Clang at $LlvmPath" $llvmOk
if (-not $llvmOk) {
    $errors += "Qt Clang not found at $LlvmPath. Download from https://download.qt.io/development_releases/prebuilt/libclang/"
    Write-Host "  Hint: Download libclang-release_180-based-windows-vs2019_64.7z and extract to C:\" -ForegroundColor Yellow
}

# CMake check
$cmakeOk = $null -ne (Get-Command cmake -ErrorAction SilentlyContinue)
$cmakeVersion = if ($cmakeOk) { cmake --version 2>&1 | Select-Object -First 1 } else { "not found" }
Write-Check "CMake" $cmakeOk $cmakeVersion
if (-not $cmakeOk) { $errors += "CMake not found. Install: choco install cmake" }

# Ninja check
$ninjaOk = $null -ne (Get-Command ninja -ErrorAction SilentlyContinue)
Write-Check "Ninja" $ninjaOk
if (-not $ninjaOk) { $errors += "Ninja not found. Install: choco install ninja OR pip install ninja" }

# Git check
$gitOk = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
Write-Check "git" $gitOk
if (-not $gitOk) { $errors += "git not found. Install: choco install git" }

# MSVC / vcvarsall check
if (-not $VcvarsallPath) {
    $candidatePaths = @(
        "C:\BuildTools\VC\Auxiliary\Build\vcvarsall.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvarsall.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvarsall.bat",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvarsall.bat",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvarsall.bat"
    )
    foreach ($p in $candidatePaths) {
        if (Test-Path $p) { $VcvarsallPath = $p; break }
    }
}
$msvcOk = $VcvarsallPath -and (Test-Path $VcvarsallPath)
Write-Check "MSVC (vcvarsall.bat)" $msvcOk $VcvarsallPath
if (-not $msvcOk) {
    $errors += "MSVC Build Tools not found. Install VS 2022 Build Tools with VC++ workload."
    Write-Host "  Hint: Download from https://aka.ms/vs/17/release/vs_buildtools.exe" -ForegroundColor Yellow
}

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "Prerequisites check FAILED:" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "All prerequisites satisfied." -ForegroundColor Green
Write-Host "  Qt path:      $QtPath"
Write-Host "  LLVM path:    $LlvmPath"
Write-Host "  MSVC:         $VcvarsallPath"
Write-Host "  Module subset: $ModuleSubset"
Write-Host "  Parallel jobs: $ParallelJobs"
Write-Host "  Output dir:   $DistDir"

# ── Step 2: Clone or update pyside-setup ─────────────────────────────────────
Write-Step "Cloning pyside-setup (tag: $PysideTag)"

if (-not $SkipClone) {
    if (Test-Path $WorkDir) {
        Write-Host "Removing existing $WorkDir..."
        Remove-Item $WorkDir -Recurse -Force
    }
    git clone --depth=1 --branch $PysideTag `
        https://github.com/qtproject/pyside-pyside-setup.git $WorkDir
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Tag $PysideTag not found, trying main branch..." -ForegroundColor Yellow
        git clone --depth=1 https://github.com/qtproject/pyside-pyside-setup.git $WorkDir
    }
} else {
    if (-not (Test-Path "$WorkDir\setup.py")) {
        Write-Host "ERROR: $WorkDir does not contain setup.py. Run without -SkipClone." -ForegroundColor Red
        exit 1
    }
    Write-Host "Skipping clone, using existing $WorkDir"
}

# ── Step 3: Install Python build dependencies ─────────────────────────────────
Write-Step "Installing Python build dependencies"

python -m pip install --upgrade pip setuptools wheel cmake ninja packaging

# ── Step 4: Build wheel ───────────────────────────────────────────────────────
Write-Step "Building PySide6 wheel (this will take 2-4 hours)"

Push-Location $WorkDir
try {
    $qtpathsExe = "$QtPath\bin\qtpaths6.exe"

    # Build command - run inside MSVC environment via cmd.exe
    $buildCmd = @"
call "$VcvarsallPath" amd64
if errorlevel 1 exit /b 1
set LLVM_INSTALL_DIR=$LlvmPath
set PATH=$LlvmPath\bin;%PATH%
python setup.py bdist_wheel ^
    --qtpaths="$qtpathsExe" ^
    --module-subset=$ModuleSubset ^
    --no-qt-tools ^
    --parallel=$ParallelJobs
"@

    $buildScriptPath = "$env:TEMP\pyside_build.cmd"
    Set-Content $buildScriptPath $buildCmd -Encoding ASCII

    Write-Host "Running build with MSVC environment..."
    Write-Host "Command: python setup.py bdist_wheel --qtpaths=... --module-subset=$ModuleSubset --no-qt-tools --parallel=$ParallelJobs"
    Write-Host ""

    cmd /c $buildScriptPath
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

# ── Step 5: Collect and report output ─────────────────────────────────────────
Write-Step "Build complete - collecting output"

$wheels = Get-ChildItem "$WorkDir\dist\*.whl" -ErrorAction SilentlyContinue
if ($wheels.Count -eq 0) {
    Write-Host "ERROR: No wheel files found in $WorkDir\dist\" -ForegroundColor Red
    exit 1
}

foreach ($whl in $wheels) {
    $destPath = Join-Path $DistDir $whl.Name
    Copy-Item $whl.FullName $destPath -Force
    $sizeMb = [math]::Round($whl.Length / 1MB, 2)
    Write-Host ""
    Write-Host "  Wheel: $($whl.Name)" -ForegroundColor Green
    Write-Host "  Size:  $sizeMb MB" -ForegroundColor Green
    Write-Host "  Path:  $destPath" -ForegroundColor Green
}

Write-Host ""
Write-Host "SUCCESS! Wheel(s) saved to: $DistDir" -ForegroundColor Green
Write-Host ""
Write-Host "To install:"
Write-Host "  pip install '$DistDir\*.whl'"
Write-Host ""
Write-Host "To test PyInstaller output size:"
Write-Host "  pip install pyinstaller '$DistDir\*.whl'"
Write-Host "  pyinstaller --onedir your_app.py"
Write-Host "  (Get-ChildItem .\dist\your_app -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB"
