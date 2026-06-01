# PySide6 Minimal Wheel — Final Report

## 结论摘要

| 优化方案 | 估算 PyInstaller 产物 | 实施难度 | 推荐 |
|---|---|---|---|
| 完整 PySide6 6.8.0（基准） | 66 MB（实测） | 无 | 基准 |
| +排除 Network/Svg/OpenGL 模块 | 59 MB（实测） | 低 | ✓ 快速收益 |
| 源码构建 Core+Gui+Widgets only | ~42-50 MB（估算） | 高 | ✓ 极致目标 |
| +UPX 压缩 .pyd 文件 | ~35-45 MB（估算） | 中 | 可选 |
| typesystem XML 裁剪 | ~40-48 MB（估算） | 极高 | ✗ 不值得 |

**不做 typesystem XML 裁剪的原因**：每个模块的 typesystem.xml 需要手动维护，与 Qt 版本强耦合，一次 Qt 小版本升级即可使裁剪失效，投入产出比极低。

---

## 推荐实施路径

### 路径 A — 立即可用，~59 MB

不需要编译，15 分钟内完成。

```powershell
# 1. 安装 PySide6-Essentials（不含 Multimedia、WebEngine 等重型模块）
pip install "PySide6-Essentials==6.8.0"

# 2. 运行裁剪脚本，移除未使用模块的 DLL
.\strip_pyside6.ps1 -Profile widgets-minimal

# 3. PyInstaller 打包，显式排除不需要的模块
pyinstaller --onedir app.py `
  --exclude-module PySide6.QtNetwork `
  --exclude-module PySide6.QtSvg `
  --exclude-module PySide6.QtSvgWidgets `
  --exclude-module PySide6.QtXml `
  --exclude-module PySide6.QtOpenGL `
  --exclude-module PySide6.QtOpenGLWidgets `
  --exclude-module PySide6.QtQml `
  --exclude-module PySide6.QtQuick `
  --exclude-module PySide6.QtMultimedia
```

### 路径 B — Docker 源码构建，~42 MB

需要 Docker Desktop（Windows Containers 模式）、稳定网络、约 40 GB 磁盘。

```powershell
# 1. 切换 Docker 到 Windows Containers 模式
#    右键托盘图标 -> "Switch to Windows containers..."
#    确认: docker info | Select-String OSType   (应输出 "windows")

# 2. 构建镜像（首次约 3-6 小时）
docker build -f Dockerfile.windows -t pyside6-builder .

# 启用 UPX 压缩 .pyd（可选，额外减小 5-10%）
docker build -f Dockerfile.windows --build-arg ENABLE_UPX=1 -t pyside6-builder .

# 3. 提取 wheel
$id = docker create pyside6-builder
docker cp "${id}:C:\output" .\wheel_output\
docker rm $id

# 4. 在目标环境安装
pip install .\wheel_output\PySide6-6.8.3-cp311-cp311-win_amd64.whl
```

---

## 环境准备清单（路径 B）

构建前需要准备或自动下载的内容：

### 自动通过网络下载（构建时）

| 组件 | 获取方式 | 预计大小 |
|---|---|---|
| Chocolatey | `community.chocolatey.org/install.ps1` | ~5 MB |
| git / cmake / ninja / 7zip | `choco install` | ~200 MB |
| Python 3.11 | `choco install python311` | ~30 MB |
| VS Build Tools 2022 (MSVC v143) | `https://aka.ms/vs/17/release/vs_buildtools.exe` | ~3-4 GB |
| Qt 6.8.3 msvc2019_64 (qtbase) | `aqtinstall` → `download.qt.io` | ~500 MB |
| Qt-custom Clang release_180 | `https://download.qt.io/development_releases/prebuilt/libclang/libclang-release_180-based-windows-vs2019_64.7z` | ~300 MB |
| pyside-setup 源码 | `https://github.com/qtproject/pyside-pyside-setup.git` (tag v6.8.3) | ~200 MB |

### 版本说明

- **PySide6 版本**：使用 6.8.x，不用 6.9+。6.9+ 的 wheel 开始强制打包 `opengl32sw.dll`（软件渲染器，约 19 MB），导致 PyInstaller 产物无故增大。
- **Qt Clang**：必须使用 Qt 官方定制版（`release_180-based`），不能替换为官方 LLVM release。Qt 定制版包含 `ClangConfig.cmake` 等文件，shiboken6 构建系统依赖这些文件。
- **shiboken6**：运行时必需，不尝试静态链接（静态链接反而会增大体积，且构建复杂度极高）。

### 离线环境的替代方案

若网络受限，可提前下载安装包并通过 `COPY` 指令放入镜像：

```powershell
# 提前下载（宿主机）
Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile vs_buildtools.exe
python -m aqt download-qt windows desktop 6.8.3 win64_msvc2019_64 -m qtbase -O ./qt_offline
Invoke-WebRequest -Uri 'https://download.qt.io/development_releases/prebuilt/libclang/libclang-release_180-based-windows-vs2019_64.7z' -OutFile libclang.7z
```

---

## 已生成的文件

| 文件 | 说明 |
|---|---|
| `research_notes.md` | 完整研究笔记（含实验数据、实测数字来源） |
| `Dockerfile.windows` | Windows Container 构建环境，包含 UPX 可选步骤 |
| `build_minimal_wheel.ps1` | 本机（非 Docker）构建脚本 |
| `strip_pyside6.ps1` | 安装后裁剪脚本（路径 A 使用） |
| `FINAL_REPORT.md` | 本文件 |

---

## 关键约束备忘

- **UPX 只能压缩 `*.pyd`**，不能压缩 `Qt6*.dll`（qwindows.dll 等会损坏）
- **shiboken6 运行时必须随 wheel 分发**，不可省略
- **`--no-qt-tools`** 排除 designer.exe、linguist.exe 等工具，节省约 50 MB 安装体积
- **`--disable-pyi`** 去掉类型存根文件，wheel 体积减小约 5-10 MB
- `MODULE_SUBSET=Core,Gui,Widgets` 时 aqtinstall 只需 `-m qtbase`，无需 qtsvg/qtnetwork
