# PySide6 最小化 Wheel 构建研究笔记

**研究日期**: 2026-05-31  
**目标**: 构建最小化 PySide6 Windows wheel，减小 PyInstaller 打包产物体积

---

## 1. PySide6 构建系统关键发现

### 1.1 构建工具链

PySide6 使用基于 `setup.py` 的构建系统，内部调用 CMake。主要构建文件位于：
- `build_scripts/options.py` — 所有命令行选项定义
- `sources/pyside6/cmake/PySideSetup.cmake` — CMake 模块控制逻辑

### 1.2 模块控制核心参数

**最关键的两个参数**：

```bash
# 方式一：指定要构建的模块子集（白名单）
python setup.py install --module-subset=Core,Gui,Widgets,Network,Xml

# 方式二：跳过特定模块（黑名单）
python setup.py install --skip-modules=WebEngineCore,WebEngineWidgets,WebChannel,Qt3DCore,Qt3DRender,...
```

**CMake 层面**：`--module-subset` 会被翻译为 `-DMODULES=...`，而 `--skip-modules` 映射为 `-DSKIP_MODULES=...`。内部 CMake 使用 `DISABLE_Qt<ModuleName>=1` 标志来禁用各模块。

### 1.3 完整构建选项列表（来自 options.py）

| 选项 | 说明 |
|------|------|
| `--module-subset=` | 指定要构建的 Qt 模块列表（逗号分隔，不含 "Qt" 前缀） |
| `--skip-modules=` | 指定要跳过的 Qt 模块列表 |
| `--no-size-optimization` | 关闭二进制大小优化（默认开启优化） |
| `--no-qt-tools` | 不复制 Qt 工具（designer、linguist 等） |
| `--disable-numpy-support` | 禁用 numpy 支持 |
| `--disable-pyi` | 不生成 .pyi 类型存根文件 |
| `--parallel=N` | 并行编译线程数 |
| `--qtpaths=` | Qt 安装路径 |
| `--openssl=` | OpenSSL 路径 |
| `--reuse-build` | 复用已有构建缓存 |

### 1.4 Windows 构建环境要求

| 工具 | 版本要求 |
|------|---------|
| Python | 3.10 - 3.14 |
| MSVC | 2019 或 2022（须与 Python 构建时使用的版本一致） |
| Qt | 6.x（与目标 PySide6 版本对应） |
| Clang/LLVM | 16-22（推荐 18+，须从 Qt 服务器下载，不能用 LLVM 官方包） |
| CMake | 3.18+ |
| Ninja | 推荐使用 |

**重要**: LLVM 须从 Qt 服务器下载特定版本，如 `libclang-release_140-based-windows-vs2019_64.7z`，官方 LLVM 12+ 不包含 CMake 配置文件，无法使用。

---

## 2. PySide6 包结构分析

### 2.1 三层包结构

PySide6 在 PyPI 上分为三个独立包：

```
PySide6            ← 元包（只有依赖声明，几百KB）
├── PySide6-Essentials  ← 核心模块（约 77MB wheel，安装后约 207MB）
└── PySide6-Addons      ← 扩展模块（安装后约 407MB）
```

**总大小对比**：
- 完整 PySide6（Essentials + Addons）：安装后约 **614 MB**
- 仅 PySide6-Essentials：安装后约 **207 MB**
- 节省：**407 MB（66%减少）**

### 2.2 PySide6-Essentials 包含的模块

| 模块 | 用途 |
|------|------|
| QtCore | 核心非GUI类，必须 |
| QtGui | 图形、字体、输入，必须 |
| QtWidgets | 传统控件UI，必须 |
| QtQml | QML语言集成 |
| QtQuick | QML快速渲染 |
| QtQuickControls2 | QML控件库 |
| QtQuickTest | QML测试 |
| QtQuickWidgets | QML+Widgets混合 |
| QtNetwork | 网络通信 |
| QtConcurrent | 并发/线程 |
| QtDBus | D-Bus IPC（仅Linux） |
| QtDesigner | Qt Designer插件 |
| QtHelp | 帮助系统 |
| QtOpenGL | OpenGL |
| QtOpenGLWidgets | OpenGL Widgets |
| QtPrintSupport | 打印 |
| QtSql | 数据库 |
| QtSvg | SVG渲染 |
| QtSvgWidgets | SVG控件 |
| QtTest | 单元测试 |
| QtUiTools | .ui文件加载 |
| QtXml | XML解析 |

### 2.3 PySide6-Addons 包含的模块（可全部排除）

| 模块 | 大小估计 | 说明 |
|------|---------|------|
| QtWebEngineCore | ~194 MB | Chromium内核，最大 |
| QtWebEngineWidgets | 包含于上 | Web浏览器控件 |
| QtMultimedia | ~30 MB | 音视频 |
| QtMultimediaWidgets | 包含于上 | 多媒体UI |
| Qt3DCore/Render/Animation/Input/Logic/Extras | ~19 MB | 3D渲染 |
| QtGraphs / QtGraphsWidgets | 数据可视化 | |
| QtBluetooth | 蓝牙 | |
| QtNfc | NFC | |
| QtLocation | 地理定位 | |
| QtMqtt | MQTT协议 | |
| QtOpcUa | 工业OPC UA | |
| QtCoap | IoT CoAP协议 | |
| QtNetworkAuth | OAuth认证 | |
| QtSerialPort | 串口通信 | |
| QtSensors | 硬件传感器 | |
| QtStateMachine | 状态机 | |
| QtHttpServer | HTTP服务器 | |
| QtPdf / QtPdfWidgets | PDF渲染 | |
| QtLinguist | 国际化工具 | |

### 2.4 wheel 文件内部结构

每个 PySide6 wheel（zip格式）包含：
- `PySide6/Qt<Module>.pyd` — Python扩展模块（调用Qt C++ API的绑定）
- `PySide6/Qt6*.dll` — Qt 动态链接库（实际Qt运行时）
- `PySide6/plugins/` — Qt 平台插件（如 `qwindows.dll`）
- `PySide6/translations/` — 翻译文件（56MB，通常可删除）
- `shiboken6/` — Python<->C++ 绑定运行时库

---

## 3. 可排除的模块列表

### 3.1 对于仅 QtWidgets GUI 应用，最小模块集

**必须保留**：
```
Core, Gui, Widgets
```

**通常也需要**（视应用功能）：
```
Network          # 如果有网络请求
Xml              # 如果解析XML
Svg, SvgWidgets  # 如果显示SVG图标
PrintSupport     # 如果有打印功能
OpenGL, OpenGLWidgets  # 如果有3D/OpenGL
UiTools          # 如果动态加载.ui文件
Sql              # 如果使用数据库
```

**可以安全排除（典型 widgets 应用）**：
```
Qml, Quick, QuickControls2, QuickTest, QuickWidgets  # QML相关
Designer         # Qt Designer（开发工具，运行时不需要）
Help             # 帮助系统
Test             # 测试框架
DBus             # D-Bus（Windows无用）
Concurrent       # 如果不用QtConcurrent API
```

**PySide6-Addons 全部可排除**（纯 widgets 应用）：
所有 WebEngine、Multimedia、3D、Bluetooth、Location、Mqtt、OpcUa 等模块。

### 3.2 推荐的最小化构建命令示例

```bash
# 最小化：只要 Core + Gui + Widgets
python setup.py install \
  --qtpaths=C:\Qt\6.7.0\msvc2019_64\bin\qtpaths6.exe \
  --module-subset=Core,Gui,Widgets \
  --no-qt-tools \
  --parallel=8

# 稍大但更实用：加入 Network, Svg, Xml
python setup.py install \
  --qtpaths=C:\Qt\6.7.0\msvc2019_64\bin\qtpaths6.exe \
  --module-subset=Core,Gui,Widgets,Network,Svg,SvgWidgets,Xml,PrintSupport \
  --no-qt-tools \
  --parallel=8
```

---

## 4. 方案分析与推荐

### 方案A：使用 --module-subset 从源码构建（推荐）

**优点**：
- 最彻底，wheel 中只有需要的 .pyd 和 Qt DLL
- 官方支持的方式
- `--module-subset=Core,Gui,Widgets` 可将 wheel 从 207MB 压缩到估计 30-50MB

**缺点**：
- 构建时间长（在强机器上约 2-4 小时）
- 依赖复杂：需要 MSVC + Qt SDK + Clang/LLVM + CMake
- Windows container 中 MSVC 安装较复杂

**可行性**：高，但需要投入构建环境搭建时间

**具体参数**：
```bash
python setup.py install \
  --qtpaths=<Qt安装>/bin/qtpaths6.exe \
  --module-subset=Core,Gui,Widgets,Network,Xml,Svg,SvgWidgets \
  --no-qt-tools \
  --parallel=8
```

---

### 方案B：安装后裁剪（post-install stripping）（最快可行）

安装完整 PySide6 后，手动删除不需要的文件，再用 PyInstaller 打包。

**步骤**：
```powershell
# 1. 安装 PySide6-Essentials（跳过 Addons）
pip install PySide6-Essentials

# 2. 找到安装目录
python -c "import PySide6; print(PySide6.__file__)"

# 3. 删除不需要的 .pyd 和对应的 Qt DLL
# 例如删除 QML 相关：
Remove-Item "...\PySide6\QtQml.pyd"
Remove-Item "...\PySide6\QtQuick*.pyd"
Remove-Item "...\PySide6\Qt6Qml.dll"
Remove-Item "...\PySide6\Qt6Quick*.dll"
# ... 等等

# 4. 删除翻译文件（56MB）
Remove-Item "...\PySide6\translations" -Recurse

# 5. 运行 PyInstaller
pyinstaller --onefile app.py
```

**优点**：
- 不需要构建环境
- 可立即实施
- 风险可控（可用虚拟环境实验）

**缺点**：
- 手动维护，升级时要重复操作
- 需要分析 DLL 依赖关系，避免删除被依赖的 DLL
- 无法减小 shiboken6 运行时体积

**可排除的主要文件（Essentials 包内）**：

| 文件/目录 | 大小估计 | 是否可删 |
|-----------|---------|---------|
| QtQml.pyd + Qt6Qml.dll | ~20MB | 如不用QML可删 |
| QtQuick*.pyd + Qt6Quick*.dll | ~30MB | 如不用QML可删 |
| Qt6Designer.dll + QtDesigner.pyd | ~9MB | 可删 |
| Qt6Help.dll + QtHelp.pyd | 小 | 可删 |
| translations/ | ~56MB | 通常可删 |
| QtTest.pyd | 小 | 可删 |
| QtDBus.pyd（Windows无效） | 小 | 可删 |

---

### 方案C：PyInstaller 层面排除（配合方案B）

在 PyInstaller spec 文件中进一步排除不需要的二进制：

```python
# app.spec
a = Analysis(
    ['app.py'],
    excludes=[
        'PySide6.QtQml',
        'PySide6.QtQuick',
        'PySide6.QtQuickControls2',
        'PySide6.Qt3DCore',
        'PySide6.QtMultimedia',
        'PySide6.QtWebEngineCore',
        'PySide6.QtWebEngineWidgets',
        'PySide6.QtDesigner',
        'PySide6.QtHelp',
        'PySide6.QtTest',
        'PySide6.QtBluetooth',
        'PySide6.QtLocation',
        'PySide6.QtSql',      # 如不用数据库
        'PySide6.QtPrintSupport',  # 如不用打印
    ],
)
```

注意：PyInstaller 的 `--exclude-module` 只能排除 Python 模块导入，对于已经被 hook 收集的 Qt DLL 不一定有效。需要结合方案B手动删除 DLL。

---

### 方案D：Docker 构建环境

**Windows Container vs Linux Container**：

PySide6 的 Windows wheel（`.pyd` 文件是 Windows DLL，Qt DLL 是 Win32 格式）**不能**在 Linux 下交叉编译。必须使用：
- Windows 原生环境（本机），或
- Windows Container（Docker Desktop 切换到 Windows containers 模式）

**Windows Container Dockerfile 草稿**：

```dockerfile
# 基础镜像：Windows Server Core with LTSC
FROM mcr.microsoft.com/windows/servercore:ltsc2022

# 安装 Chocolatey 包管理器
RUN powershell -Command \
    Set-ExecutionPolicy Bypass -Scope Process -Force; \
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; \
    iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# 安装基础工具
RUN choco install -y git cmake ninja python311

# 安装 MSVC 构建工具（Build Tools for Visual Studio 2022）
# 注意：在容器中安装 MSVC 需要单独下载 vs_buildtools.exe
ADD vs_buildtools.exe C:/TEMP/
RUN C:/TEMP/vs_buildtools.exe --quiet --wait --norestart --nocache \
    --installPath C:/BuildTools \
    --add Microsoft.VisualStudio.Workload.VCTools \
    --add Microsoft.VisualStudio.Component.Windows11SDK.22621

# 设置 Python 并安装依赖
RUN python -m pip install setuptools wheel cmake ninja

# Qt SDK 需要单独下载安装（约 3GB）
# 推荐使用 aqtinstall (Another Qt installer)
RUN pip install aqtinstall
RUN python -m aqt install-qt windows desktop 6.7.2 win64_msvc2019_64 \
    -O C:/Qt \
    -m qtbase

# 下载 Clang（从 Qt 服务器）
ADD libclang-release_180-based-windows-vs2019_64.7z C:/TEMP/
RUN 7z x C:/TEMP/libclang*.7z -oC:/
ENV LLVM_INSTALL_DIR=C:/libclang

# 克隆 pyside-setup
RUN git clone --depth=1 https://github.com/qtproject/pyside-pyside-setup.git C:/pyside-setup

# 构建最小化 PySide6
WORKDIR C:/pyside-setup
RUN python setup.py bdist_wheel \
    --qtpaths=C:/Qt/6.7.2/msvc2019_64/bin/qtpaths6.exe \
    --module-subset=Core,Gui,Widgets,Network,Xml,Svg,SvgWidgets \
    --no-qt-tools \
    --parallel=4

# wheel 输出在 dist/ 目录
```

**Docker 方案的现实困难**：
1. Windows Container 基础镜像约 **5-10GB**
2. MSVC Build Tools 安装复杂，难以自动化
3. Qt SDK 约 3GB，Clang 约 400MB
4. 总构建时间：首次 4-8 小时
5. 镜像体积：20GB+

**结论**：Docker 方案技术上可行，但工程成本极高，不推荐作为第一步。

---

## 5. 推荐的最小模块集

### 5.1 极简模式（只有基础 GUI）

```
Core, Gui, Widgets
```
估计安装大小：~30-40MB（仅这三个模块的 DLL + pyd）

### 5.2 实用模式（大多数 GUI 应用）

```
Core, Gui, Widgets, Network, Xml, Svg, SvgWidgets, PrintSupport
```
估计安装大小：~50-70MB

### 5.3 PySide6-Essentials 去除 QML 后

从 PySide6-Essentials 的 207MB，删除 QML/Quick 相关（约 50-80MB），可得约 **130MB**。

---

## 6. 推荐实施策略（按难度递增）

### 第一步（立即可做）：虚拟环境 + 仅安装 Essentials + PyInstaller 排除

```powershell
# 创建干净虚拟环境
python -m venv venv_minimal
.\venv_minimal\Scripts\Activate.ps1

# 只安装 Essentials，不安装 Addons
pip install PySide6-Essentials

# 用 PyInstaller 打包并在 spec 中排除不需要的模块
pip install pyinstaller
pyinstaller --onefile --name myapp `
    --exclude-module PySide6.QtQml `
    --exclude-module PySide6.QtQuick `
    --exclude-module PySide6.QtQuickControls2 `
    --exclude-module PySide6.QtDesigner `
    --exclude-module PySide6.QtHelp `
    --exclude-module PySide6.QtTest `
    --exclude-module PySide6.Qt3DCore `
    app.py
```

### 第二步：手动删除 Essentials 包中不需要的 DLL

在虚拟环境中，定位 PySide6 安装目录，删除未使用模块的 .pyd 和对应 Qt6*.dll，然后再运行 PyInstaller。

### 第三步（最彻底）：本机从源码构建最小 wheel

安装 Qt 6.7+、MSVC 2022、Clang（Qt版本），然后：

```bash
git clone --depth=1 https://github.com/qtproject/pyside-pyside-setup.git
cd pyside-pyside-setup
python setup.py bdist_wheel \
    --qtpaths=C:\Qt\6.7.2\msvc2019_64\bin\qtpaths6.exe \
    --module-subset=Core,Gui,Widgets,Network,Xml,Svg,SvgWidgets \
    --no-qt-tools \
    --parallel=8
```

输出 wheel 在 `dist/` 目录，可直接 `pip install dist/*.whl`。

---

## 7. 关键数据汇总

| 配置 | 安装大小 | 备注 |
|------|---------|------|
| PySide6（完整） | ~614 MB | Essentials + Addons |
| PySide6-Essentials | ~207 MB | 无 WebEngine/Addons |
| Essentials 去 QML | ~130 MB | 估算 |
| 自定义最小构建（Core+Gui+Widgets） | ~30-50 MB | 需从源码构建 |
| PyInstaller 打包后（完整PySide6） | ~300-400 MB | onedir模式 |
| PyInstaller 打包后（最小构建） | ~20-40 MB | 估算 |

---

## 8. 参考资源

- [Qt for Python 包详情](https://doc.qt.io/qtforpython-6/package_details.html)
- [从源码构建 Windows](https://doc.qt.io/qtforpython-6/building_from_source/windows.html)
- [pyside-setup GitHub](https://github.com/qtproject/pyside-pyside-setup)
- [PySide6-Essentials PyPI](https://pypi.org/project/PySide6-Essentials/)
- [PySide6-Addons PyPI](https://pypi.org/project/PySide6-Addons/)
- [PyInstaller 使用文档](https://pyinstaller.org/en/stable/usage.html)
- [切换到 pyside6-essentials 减小体积 (Issue)](https://github.com/mprib/caliscope/issues/841)
- [OVITO PySide6 构建指南](https://www.ovito.org/manual/licenses/PySide6.instructions.html)

---

## 9. 下一步行动计划

### 优先级 1（本周可做，无需特殊环境）

1. [ ] 创建测试 Python 脚本（只 import QtCore, QtGui, QtWidgets 的简单 GUI 应用）
2. [ ] 创建干净 venv，`pip install PySide6-Essentials`
3. [ ] 用 `pip show --files PySide6-Essentials` 列出所有文件，统计各模块 DLL 大小
4. [ ] 在 spec 文件中排除 QML/Quick 模块，运行 PyInstaller，测量产物大小

### 优先级 2（需要 Qt SDK + MSVC，约 1 天准备）

5. [ ] 安装 Qt 6.7.x (msvc2019_64) + MSVC 2022 + Clang（从Qt服务器）
6. [ ] 克隆 pyside-setup（`--depth=1`）
7. [ ] 用 `--module-subset=Core,Gui,Widgets` 构建最小 wheel
8. [ ] 测量 wheel 大小，与 Essentials 对比
9. [ ] 用最小 wheel + PyInstaller 打包，测量最终产物大小

### 优先级 3（长期，可选）

10. [ ] 用 GitHub Actions (windows-latest runner) 自动化最小 wheel 构建
11. [ ] 评估是否值得维护私有 PyPI 服务器托管自定义 wheel

---

## 10. 实验数据（2026-05-31 实测）

### 10.1 实验环境

| 项目 | 版本 |
|------|------|
| Python | 3.11.9 |
| pip | 24.0 |
| Docker | 26.1.4 (Docker Desktop 4.31.1) |
| Docker 模式 | **Windows Containers**（OSType: windows） |
| OS | Windows 11 Pro 10.0.26200 |
| git | 2.50.1 |

### 10.2 已安装 PySide6 实测数据

系统全局环境已安装 **PySide6 6.8.0**（仅 Essentials，无 Addons）。

**总体大小**：103.54 MB（安装后，不含 shiboken6）

#### 按模块分组的实测大小（PySide6 6.8.0）

| 模块组 | 实测大小 | 文件数 | 可排除（纯 Widgets 应用）|
|--------|---------|--------|------------------------|
| Core（Qt6Core.dll + QtCore.pyd） | 9.31 MB | 3 | 否（必须） |
| Gui（Qt6Gui.dll + QtGui.pyd） | 12.81 MB | 3 | 否（必须） |
| Widgets（Qt6Widgets.dll + QtWidgets.pyd） | 12.13 MB | 3 | 否（必须） |
| Quick（所有 Qt6Quick*.dll + QtQuick*.pyd） | 23.08 MB | 48 | **是** |
| Qml（Qt6Qml.dll 等 + QtQml.pyd） | 9.43 MB | 15 | **是** |
| OpenGL（Qt6OpenGL.dll + QtOpenGL.pyd 等） | 10.79 MB | 5 | 视需求 |
| Designer（Qt6Designer.dll + QtDesigner.pyd） | 8.02 MB | 4 | **是** |
| Network（Qt6Network.dll + QtNetwork.pyd） | 2.77 MB | 3 | 视需求 |
| DBus（Qt6DBus.dll + QtDBus.pyd） | 0.99 MB | 2 | **是**（Windows 无用） |
| Help（Qt6Help.dll + QtHelp.pyd） | 0.87 MB | 2 | **是** |
| Svg + SvgWidgets | 0.80 MB | 4 | 视需求 |
| PrintSupport | 0.70 MB | 3 | 视需求 |
| Sql | 0.76 MB | 3 | 视需求 |
| Test | 0.56 MB | 3 | **是** |
| UiTools | 0.80 MB | 3 | 视需求 |
| Concurrent | 0.14 MB | 2 | 视需求 |
| Xml | 0.36 MB | 3 | 视需求 |
| plugins/imageformats | 1.78 MB | - | 部分可删 |
| plugins/platforms（qwindows.dll） | 1.03 MB | - | 否（必须） |
| plugins/tls | 0.64 MB | - | 视需求 |

**注意**：6.8.0 版本**不包含** `opengl32sw.dll`（软件渲染器），6.11.1 中该文件 **19.68 MB**。

#### shiboken6 大小

| 文件 | 大小 |
|------|------|
| shiboken6 总计 | **2.71 MB** |
| shiboken6.abi3.dll | 0.35 MB |
| MSVC 运行时（msvcp140 等，随 shiboken6） | 约 2.0 MB |

**结论**：shiboken6 是运行时必须的（PySide6 的 Python<->C++ 绑定层），无法排除，但很小（2.71 MB）。

### 10.3 PySide6-Essentials 6.11.1 与 6.8.0 对比

| 版本 | 安装大小 |
|------|---------|
| PySide6 6.8.0（全局 Python 环境） | 103.54 MB |
| PySide6-Essentials 6.11.1（venv） | **202.23 MB** |

**6.11.1 大了约 100 MB 的主要原因**：
- 新增 `opengl32sw.dll`（Mesa 软件 OpenGL 渲染器）= **19.68 MB**
- 新增 `icudtl.dat`（Unicode 数据）= **9.98 MB**
- Qt 各模块体积自然增长

### 10.4 PyInstaller 打包实测数据

测试应用：仅使用 `QApplication + QLabel`（最小化 Widgets 应用）。

#### PySide6 6.8.0（全局环境，已无 QML/Addons）

| 构建配置 | 产物大小 | 文件数 |
|---------|---------|--------|
| 无排除参数（完整打包） | **66.56 MB** | 94 |
| 排除 QML/Quick/Designer/Help/Test/DBus | **66.56 MB** | 94 |
| 额外排除 Network/Svg/OpenGL/Sql/UiTools/XML | **59.08 MB** | 88 |

**关键发现**：对 6.8.0 来说，前两个结果完全相同，因为该安装已经不含 QML 相关内容，`--exclude-module` 对这些根本不起作用。`--exclude-module` 只能减少"本来就有"的模块。

排除 Network/Svg/OpenGL 节省了 **7.48 MB**，但 Qt6Network.dll（1.69 MB）仍然存在（Qt6Widgets 的传递依赖），libcrypto-3.dll（4.95 MB）也无法彻底去除。

#### PySide6-Essentials 6.11.1（venv 环境）

| 构建配置 | 产物大小 | 文件数 |
|---------|---------|--------|
| 无排除参数（完整打包） | **96.74 MB** | 193 |
| 排除 QML/Quick/Designer/Help/Test/DBus/OpenGL/SQL/etc | **89.28 MB** | - |

**比 6.8.0 大 ~30 MB 的原因**：
- `opengl32sw.dll` = 19.68 MB（PyInstaller 自动收集）
- `icudtl.dat` = 9.98 MB
- `qmlls.exe`、`qmlformat.exe` 等工具

#### 6.8.0 产物中各大文件明细（59 MB 极简构建）

| 文件 | 大小 | 备注 |
|------|------|------|
| Qt6Gui.dll | 8.81 MB | 必须 |
| Qt6Widgets.dll | 6.20 MB | 必须 |
| Qt6Core.dll | 5.81 MB | 必须 |
| python311.dll | 5.53 MB | 必须 |
| libcrypto-3.dll | 4.95 MB | Qt 网络传递依赖，难以去除 |
| QtWidgets.pyd | 5.90 MB | 必须 |
| QtGui.pyd | 3.98 MB | 必须 |
| QtCore.pyd | 3.43 MB | 必须 |
| Qt6Network.dll | 1.69 MB | Widgets 传递依赖 |
| base_library.zip | 1.38 MB | Python 标准库 |
| unicodedata.pyd | 1.09 MB | Python 标准库 |
| qwindows.dll | 0.87 MB | 必须（Windows 平台插件） |
| MSVC 运行时合计 | ~2 MB | 必须 |
| api-ms-win-* 合计 | ~0.9 MB | Windows API 转发 DLL |

**理论最小值**：Core+Gui+Widgets DLL+PYD（34.25 MB）+ python311.dll（5.53 MB）+ shiboken6（2.71 MB）+ qwindows.dll（0.97 MB）+ libcrypto（4.95 MB）+ base_library.zip（1.38 MB）+ 系统 DLL = **约 55-60 MB**。与实测 59.08 MB 吻合。

### 10.5 Docker Windows Container 方案可行性评估

**实测 Docker 状态**：
- Docker Desktop 4.31.1，Docker Engine 26.1.4
- **当前处于 Windows Containers 模式**（OSType: windows）
- 这意味着可以直接使用 Windows Container 镜像，**无需切换模式**

**技术可行性**：✅ **可行**

**主要挑战**（基于实际测量）：
1. Windows Server Core 基础镜像：5-7 GB
2. MSVC Build Tools：约 3-4 GB（安装）
3. Qt SDK（仅 msvc2019_64）：约 3 GB
4. Clang/LLVM（Qt 版本）：400 MB
5. pyside-setup 源码：约 100 MB（depth=1）
6. **总镜像大小估计：15-20 GB**

**构建时间估计**：
- 环境搭建（首次）：1-2 小时
- PySide6 编译：2-4 小时（取决于 CPU）
- 总计首次：3-6 小时

### 10.6 源码构建关键参数验证

pyside-setup 源码分析（通过 GitHub raw 直接获取 `build_scripts/options.py`、`build_scripts/main.py`、`build_scripts/utils.py`）：

**`--module-subset` 的实际处理逻辑**（已验证）：

```python
# build_scripts/utils.py - parse_modules() 函数
def parse_modules(modules: str) -> str:
    module_sub_set = ""
    for m in modules.split(','):
        if m.startswith('Qt'):
            m = m[2:]      # 去掉 "Qt" 前缀
        if module_sub_set:
            module_sub_set += ';'
        module_sub_set += m
    return module_sub_set

# build_scripts/main.py - 传递给 CMake
if OPTION["MODULE_SUBSET"]:
    cmake_cmd.append(f"-DMODULES={parse_modules(OPTION['MODULE_SUBSET'])}")
```

**含义**：
- 用逗号分隔，支持有/无 "Qt" 前缀，如 `Core,Gui,Widgets` 或 `QtCore,QtGui,QtWidgets`
- 最终转为 CMake 的 `-DMODULES=Core;Gui;Widgets`
- `--skip-modules` 类似，转为 `-DSKIP_MODULES=...`

关键参数（基于 options.py 分析和文档）：

```bash
# 最小化构建命令（仅 Core + Gui + Widgets）
python setup.py bdist_wheel \
    --qtpaths=C:\Qt\6.x\msvc2019_64\bin\qtpaths6.exe \
    --module-subset=Core,Gui,Widgets \
    --no-qt-tools \
    --parallel=8

# 预期 wheel 大小
# Core+Gui+Widgets DLL: 34.25 MB
# + pyd 文件: ~18 MB（QtCore.pyd 3.4MB + QtGui.pyd 4.0MB + QtWidgets.pyd 5.9MB）
# + shiboken6: 2.71 MB
# + plugins/platforms: 1 MB
# + MSVC 运行时: ~2 MB
# 估计 wheel 大小: 约 55-65 MB（压缩前）
```

**重要发现**：`opengl32sw.dll` 是 6.11+ 中新增的，如果基于 6.8.x 或更早版本构建，可避免这 20 MB 的软件渲染器。

### 10.7 最终推荐方案（基于实测数据）

#### 推荐方案：方案B（安装后裁剪）+ 方案C（PyInstaller 排除）组合

**理由**：
1. PyInstaller 对 6.8.0 的实测显示，如果安装包本身已经干净（无 QML），打包产物约 **60-67 MB**，比预期好
2. 6.11.1 因为 opengl32sw.dll，基线直接是 97 MB，更需要裁剪
3. 对于 6.11.1，先物理删除 `opengl32sw.dll`（19.68 MB）再打包，可从 97 MB 降至约 **77 MB**

**立即可实施的步骤**：

```powershell
# Step 1: 安装 Essentials（选用 6.8.x 版本可避免 opengl32sw.dll 问题）
pip install "PySide6-Essentials==6.8.0"

# Step 2: 物理删除不需要的文件
$p = python -c "import PySide6; import os; print(os.path.dirname(PySide6.__file__))"
# 删除 QML/Quick（约 32 MB）
Remove-Item "$p\Qt6Qml.dll", "$p\Qt6QmlCompiler.dll", "$p\Qt6QmlModels.dll" -ErrorAction SilentlyContinue
Remove-Item "$p\Qt6Quick*.dll" -ErrorAction SilentlyContinue
Remove-Item "$p\QtQml.pyd", "$p\QtQuick*.pyd" -ErrorAction SilentlyContinue
# 删除 Designer（8 MB）
Remove-Item "$p\Qt6Designer.dll", "$p\Qt6DesignerComponents.dll", "$p\QtDesigner.pyd" -ErrorAction SilentlyContinue
# 删除 opengl32sw.dll（若存在，6.11+）
Remove-Item "$p\opengl32sw.dll" -ErrorAction SilentlyContinue

# Step 3: PyInstaller 打包
pyinstaller --onedir app.py
# 预期产物：~55-60 MB（仅 Core+Gui+Widgets）
```

#### 最大化压缩（从源码构建）

若需要 < 40 MB 的打包产物，需从源码构建 `--module-subset=Core,Gui,Widgets`，主要节省来自：
- 去除 Qt6Network.dll（1.69 MB）
- 去除 libcrypto（4.95 MB）
- 去除所有 imageformats 插件（约 3 MB）
- 去除 ucrtbase.dll 等可选依赖

**最终大小对比总结**：

| 方案 | 预期 PyInstaller 产物 | 工程难度 |
|------|---------------------|---------|
| 完整 PySide6（Addons + Essentials） | 300-400 MB | 低 |
| 仅 Essentials 6.8.0，无裁剪 | **66.56 MB（实测）** | 低 |
| 仅 Essentials 6.8.0 + PyInstaller 排除 | **59.08 MB（实测）** | 低 |
| 仅 Essentials 6.11.1，无裁剪 | **96.74 MB（实测）** | 低 |
| 仅 Essentials 6.11.1 + 删除 opengl32sw.dll | ~77 MB（估算） | 低 |
| 源码构建 Core+Gui+Widgets | ~40-50 MB（估算） | 高 |

---

## 11. C++ 级别精简方案深度分析

### 11.1 typesystem XML 裁剪可行性

**结论：理论可行，但工程成本极高，存在隐藏依赖风险。**

Shiboken 使用 typesystem XML 文件定义哪些 C++ 类生成 Python 绑定。关键机制：

- **`<object-type name="QFoo"/>`**：删除此条目后，该类不生成 `.pyd` 中的 Python 类，直接减小 `.pyd` 大小。
- **`<rejection class="QFoo"/>`**：显式拒绝生成某个类，效果等同于删除条目。
- **`generate="no"` 属性**：保留类型引用（供其他类的方法签名解析），但不生成实际绑定，是更安全的方式。

**隐藏依赖问题**：
- 若 `QBar` 的某个方法返回 `QFoo*`，而 `QFoo` 已被 reject，shiboken 编译时会报错或生成不完整的绑定。
- QtWidgets 的类之间交叉引用密集（如 `QLayout`、`QSizePolicy`、`QAbstractItemDelegate` 等），随意删除会引发级联错误。
- 实际操作需要为每个被删除类在所有引用它的方法上添加 `<modify-function>` 或 `<remove>` 标注，工程量可观。

**已知参考**：目前无公开项目系统地对 PySide6 做 typesystem 裁剪。shiboken 官方文档提及 `rejection` 节点，但仅用于去除特定函数/枚举值，整类级别的裁剪没有官方示例。QGIS 等项目做过自定义 Python 绑定层，但是用完整 typesystem 而非裁剪。

**实际可节省量**：QtWidgets.pyd 实测 5.9 MB，其中包含约 100+ 个 Widget 类。即使去掉 50% 的类，节省估计不超过 2-3 MB，性价比极低。**不推荐作为主要优化手段。**

---

### 11.2 Qt feature flags 可关闭列表（widgets 应用）

**结论：部分 feature 可安全关闭，但需从源码构建 Qt，整体工程量很大。**

Qt6 通过 CMake `-DFEATURE_foo=OFF`（configure 层为 `-no-feature-foo`）控制功能开关。对纯 Widgets GUI 应用可考虑关闭的功能：

| Feature Flag | 影响 | 估计节省 | 安全性 |
|---|---|---|---|
| `-no-feature-accessibility` | 禁用无障碍支持 | 小（<0.5MB） | 安全（桌面应用） |
| `-no-feature-gestures` | 禁用手势识别 | 小 | 安全（非触屏应用） |
| `-no-feature-gif` | 禁用 GIF 格式 | 小 | 安全（若不用 GIF） |
| `-no-feature-ico` | 禁用 ICO 格式支持 | 极小 | 有风险（Windows 图标） |
| `-no-feature-dbus` | 禁用 D-Bus | ~1 MB | 安全（Windows 上无用） |
| `-no-feature-ssl` | 禁用 SSL/TLS | ~5 MB（去 libcrypto） | 视应用需求 |
| `-no-feature-sql-*` | 禁用各 SQL 驱动 | 小 | 安全（若不用数据库） |
| `-no-feature-printing` | 禁用打印支持 | ~0.7 MB | 安全（若不用打印） |

**关键注意**：
- feature 之间存在依赖链，关闭一个可能级联影响其他 feature，需逐一测试。
- PySide6 的 typesystem XML 中部分类（如 `QPrinter`）有条件编译保护，关闭对应 Qt feature 后，需同步修改 typesystem 或添加 `<rejection>`，否则 shiboken 编译失败。
- Qt configure 的完整 feature 列表只能通过在 Qt 源码目录运行 `configure -list-features` 获取；各模块的 `configure.cmake` 文件定义了本模块的 feature，如 `qtbase/src/widgets/configure.cmake`。

**整体评估**：通过 Qt feature 裁剪，理论上可在源码构建基础上额外节省 5-10 MB（主要来自去除 libcrypto、dbus、printing），但需要同时构建自定义 Qt + 自定义 PySide6，工程成本极高。

---

### 11.3 UPX 压缩 Qt DLL 的实际效果评估

**结论：Qt DLL 的 UPX 压缩存在严重兼容性风险，不推荐用于 Qt 平台插件；对普通 Qt DLL 效果有限且有崩溃风险。**

**已知问题**：
- UPX issue #107（2017年，但问题延续至今）：对 `qwindows.dll`（Qt Windows 平台插件）使用 UPX 会导致二进制结构损坏，应用启动时报错 "could not find or load the Qt platform plugin 'windows'"。
- 根本原因：现代 Qt DLL 的 PE 结构包含 3-4 个 segment（用于 RELRO、TLS 等），UPX 历史上只支持 2 个 segment，会拒绝或静默损坏此类文件。
- PyInstaller 官方在非 Windows 平台默认禁用 UPX（"known compatibility problems"）。

**在 Windows 上的实际情况**：
- UPX 通常可以压缩普通 Qt DLL（如 `Qt6Core.dll`、`Qt6Gui.dll`），压缩率约 40-50%。
- 但加载时需要 UPX 解压缩，增加启动时间（大 DLL 可能增加数百毫秒）。
- 必须用 `--upx-exclude "qwindows.dll"` 排除平台插件。
- Qt6 64-bit DLL 中某些 DLL（含 Qt Quick 等模块）可能包含不兼容 UPX 的 PE 结构。

**实测参考**（来自社区报告）：
- 对 ~60 MB 的 PySide6 产物使用 UPX，排除 `qwindows.dll` 后，实际压缩约 20-25 MB（节省 ~35%）。
- 但有报告显示部分 Qt6 DLL 压缩后运行时崩溃，稳定性不如 PySide2 时代。

**推荐做法**：如要使用 UPX，先对全部产物进行压缩测试，用 `--upx-exclude "Qt*.dll"` 排除所有 Qt DLL，仅压缩 Python DLL 和 .pyd 文件，节省约 5-10 MB，风险可控。

---

### 11.4 shiboken 静态链接分析

**结论：shiboken6 可以以静态库形式链接，但官方构建默认为动态链接；静态链接会增加每个 .pyd 的大小，总体积反而增大，不适合多模块场景。**

**shiboken6 的组件结构**：
- `libshiboken6.abi3.dll`（0.35 MB）：运行时绑定支持库
- `shiboken6.exe`（生成器，构建时工具，运行时不需要）
- PySide6 的每个 `.pyd` 在运行时动态链接 `libshiboken6.abi3.dll`

**静态链接可行性**：
通过 CMake `-DBUILD_SHARED_LIBS=OFF` 可构建静态版 libshiboken。但实际分析：
- `libshiboken6` 静态库约 1-2 MB（估算）。
- PySide6 有 ~20 个 `.pyd` 文件，若每个都静态链接，总增加 20-40 MB，远超动态链接节省的 0.35 MB。
- 官方构建从未使用此选项，相关 CMake 路径未经测试，可能有编译错误。

**实际意义**：对于 `--module-subset=Core,Gui,Widgets` 的极简构建（只有 3 个 .pyd），静态链接可以消除 `libshiboken6.abi3.dll` 作为独立依赖，但 3 × 1.5 MB = 4.5 MB vs 原来 0.35 MB，反而增加 ~4 MB。**不推荐。**

**正确的 shiboken 优化方向**：shiboken6 运行时本身已经很小（0.35 MB），优化重点应放在 PySide6 的 `.pyd` 文件大小而非 shiboken 本身。

---

### 11.5 现有参考项目（OVITO 等）

**OVITO（科学可视化软件）**：
- 官方 Build Instructions 披露了模块选择：`Core,Gui,Widgets,Xml,Network,Svg,OpenGL,OpenGLWidgets`。
- **Windows 平台**：直接使用官方 `PySide6-Essentials`（v6.10.3），未做自定义 typesystem 裁剪。
- **Linux 平台**：自行从源码编译（PySide6 v6.8.3 + Qt 6.8.3 + Python 3.12），使用 `--parallel=8` 构建，但仍未披露 typesystem 修改细节。
- **macOS**：自行编译 v6.10.3，支持 `x86_64;arm64` 通用二进制。
- **关键发现**：OVITO 没有做 typesystem 级别的裁剪，仅使用模块子集限制。说明即使是专业 C++ 科学软件团队，也选择了"够用的最小模块集"而非深度裁剪，印证了 typesystem 裁剪的工程成本过高。

**其他已知项目**：
- **ctismer/pyside6-6.4**：个人项目，对 PySide6 6.4 进行了一些打包实验，未涉及 typesystem 修改。
- **PySide6-Essentials 官方包**：Qt 官方将 PySide6 拆分为 Essentials + Addons 两包，已是官方层面的"最小化"尝试，Essentials 约 200 MB 安装大小。
- **lliurex/pyside6**：Debian/Ubuntu 发行版的打包，使用系统 Qt，不适用于独立分发。

**结论**：目前无公开项目实现了 typesystem 级别的 PySide6 裁剪。模块子集（`--module-subset`）是业界唯一成熟的 C++ 层面优化手段。

---

### 11.6 极限估算：各优化手段叠加后的理论最小产物大小

基于实测数据（10.4节）和本节研究，以 PyInstaller onedir 模式为基准：

| 优化层次 | 累计产物大小 | 手段 | 工程难度 |
|---|---|---|---|
| 基准（Essentials 6.8.0 无排除） | 66.56 MB | - | 极低 |
| + PyInstaller 排除可选模块 | 59.08 MB（实测） | `--exclude-module` | 极低 |
| + 使用 6.8.0（避开 opengl32sw.dll） | 已包含在上行 | 选版本 | 极低 |
| + 源码构建 Core+Gui+Widgets only | ~42-48 MB（估算） | `--module-subset=Core,Gui,Widgets` | 高 |
| + Qt feature 裁剪（去 ssl/dbus/printing） | ~36-42 MB（估算） | `-DFEATURE_ssl=OFF` 等 | 极高 |
| + UPX（仅压缩 .pyd 和 python311.dll） | ~33-38 MB（估算） | `--upx-dir` + upx-exclude | 中 |
| + strip debug symbols（Linux 习惯，Windows 需要 PDB 分离） | 无显著效果 | - | - |

**理论硬下限分析**（无法再压缩的必须文件）：

| 必须文件 | 大小 |
|---|---|
| Qt6Core.dll | 5.81 MB |
| Qt6Gui.dll | 8.81 MB |
| Qt6Widgets.dll | 6.20 MB |
| QtCore.pyd | 3.43 MB |
| QtGui.pyd | 3.98 MB |
| QtWidgets.pyd | 5.90 MB |
| python311.dll | 5.53 MB |
| shiboken6.abi3.dll | 0.35 MB |
| qwindows.dll（平台插件） | 0.87 MB |
| MSVC 运行时（msvcp140等） | ~2.0 MB |
| base_library.zip | 1.38 MB |
| _bootlocale + 其他必要 .pyd | ~1.0 MB |
| **合计** | **~45 MB** |

注：上表假设 libcrypto（4.95 MB）可通过关闭 Qt SSL feature 去除。若保留 libcrypto，硬下限约 50 MB。

**最终结论**：
- **无需自定义构建的可达目标**：约 59 MB（已实测）。
- **自定义构建 Qt+PySide6 的可达目标**：约 40-45 MB（理论），工程成本极高（数天工作量）。
- **低于 35 MB 的目标**：需要 Qt feature 裁剪 + UPX + 极简模块，目前无公开成功案例，可行性存疑。
- typesystem 裁剪、shiboken 静态链接对最终产物大小贡献极小（各 <3 MB），不值得投入。

**推荐路径**：维持实测 59 MB 方案（Essentials 6.8.0 + PyInstaller 排除），如需进一步压缩，优先尝试源码构建 `Core+Gui+Widgets` 模块子集，预期降至 42-48 MB。

---

## 第12节：C++ Qt 与 Python PySide6 体积差距的根源分析

> 详细报告见 `cpp_vs_python_size.md`，本节为摘要。

### 12.1 C++ Qt 的实际极限

C++ Qt Widgets 应用静态链接（MSVC Release + LTO + feature 裁剪）后，.exe 约 **5-8 MB**（未压缩），UPX 后约 **2-4 MB**。动态链接方案需附带 Qt DLL，总计约 **24-25 MB**——与 PySide6 硬下限中的 Qt DLL 层完全重合。

Qt 官方 Qt Lite 项目通过 400+ feature 开关可将 ROM 占用裁减最高 77%，但这主要针对嵌入式场景；桌面 Widgets 应用的 feature 裁剪空间有限（主要收益是去掉 SSL、SVG 等，约 5-10 MB）。

### 12.2 差距的结构性来源

PySide6 PyInstaller 最优产物（~45 MB 理论值）与 C++ 静态链接（~8 MB）的差距约 **5-6 倍**，组成如下：

| 额外层次 | 大小 | 能否消除 |
|---|---|---|
| Qt DLL 层（双方共有） | ~21.7 MB | 不能（C++ 静态链接通过 DCE 消除，Python 不行） |
| Python 解释器 + 标准库 | ~7.9 MB | 结构性，Nuitka 有限改善 |
| shiboken + .pyd 绑定层 | ~13.7 MB | 部分（手写极简绑定可降至 2-4 MB） |
| SSL 库 | ~4.9 MB | 工程可消除（关闭 Qt SSL feature） |

**根本限制**：Python C extension 架构使用共享 .pyd，链接器无法跨模块做 dead-code elimination——即使只用 QLabel，QFileDialog 等 200 个类的绑定代码也全部存在。这是与 C++ 静态链接最本质的架构差异。

### 12.3 弥合差距的方案评估

| 方案 | 预期效果 | 工程成本 | 结论 |
|---|---|---|---|
| PyInstaller 排除 + 版本选择 | 59 MB（已实测） | 极低 | 已完成，推荐 |
| 模块子集构建（Core+Gui+Widgets） | ~42-48 MB | 高 | 最值得尝试的下一步 |
| Qt feature 裁剪（去 SSL） | 额外 -5 MB | 极高 | 性价比低 |
| UPX 压缩 | 额外 -5-10 MB | 低 | 稳定性风险 |
| Nuitka 编译 | 无明显改善（~60-80 MB） | 高 | 不推荐用于体积优化 |
| 手写极简绑定（PyO3/cffi） | 理论极限 ~25-30 MB | 极高 | 等同重新开发绑定层 |
| RustPython/GraalPy | 当前不可行 | - | 3-5 年内不现实 |

### 12.4 结论

差距是**结构性与工程性的叠加**。结构性部分（Python 解释器 ~8 MB + 绑定双重层 ~10 MB）在现有 CPython + shiboken 架构下无法消除，约 **15-18 MB 的不可削减底线**存在。

Python PySide6 在现有工具链下无法接近 C++ 静态链接体积（<10 MB），但与 C++ 动态链接方案（~25 MB）的差距可通过深度优化缩小至 **1.7-2 倍**（~45 MB vs ~25 MB）。

若最终产物体积是项目最高优先级，应重新评估技术栈而非继续在 PySide6 上优化。当前项目的合理目标是将体积降至 **40-48 MB**（通过模块子集构建实现）。
