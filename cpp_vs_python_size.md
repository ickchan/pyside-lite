# C++ Qt 与 Python PySide6 体积差异深度分析

**研究日期**: 2026-05-31  
**研究背景**: 基于已有的 PySide6 最小化构建研究（research_notes.md 第1-11节），进一步分析 C++ Qt 的理论极限以及 Python 能否弥合差距。

---

## 1. C++ Qt 应用的理论极限

### 1.1 动态链接方案（依赖系统 Qt DLL）

| 文件 | 大小 |
|---|---|
| 应用 .exe（仅包含业务逻辑） | ~50-200 KB |
| Qt6Core.dll | ~5.8 MB |
| Qt6Gui.dll | ~8.8 MB |
| Qt6Widgets.dll | ~6.2 MB |
| qwindows.dll（平台插件） | ~0.9 MB |
| MSVC 运行时 | ~2.0 MB |
| **发行总计（需附带 DLL）** | **~24-25 MB** |

Qt DLL 尺寸与 PySide6 硬下限中相同的 Qt DLL 完全一致——PySide6 需要同等的 Qt 运行库。

### 1.2 静态链接方案（configure -static）

静态链接将应用 + Qt 代码合并为单一 .exe，链接器通过 dead-code elimination 只保留实际调用的符号。

**实测/社区数据汇总**：

- Hello World（QLabel 显示文本，MSVC Release）：静态链接 .exe **约 7-15 MB**
- 用户报告未优化时达 15 MB，认为偏大
- 应用 UPX 压缩后可降至 **~3-4 MB**
- Qt 官方博客（Qt 6.8 binary size series）：对最简 QML Window+Text 静态构建，-optimize-size + LTO 可在各平台实现显著压缩（具体数字在图表中，文字部分未披露），但官方提及可裁减 ROM 占用 **最高达 77%**（主要针对嵌入式/Qt Lite 场景）

**Qt `-no-feature-xxx` 精简极限**：

Qt 提供 400+ feature 开关（`-DFEATURE_xxx=OFF`）。仅保留 QMainWindow、QLabel、QPushButton 所需最小功能集时：
- 关闭 SSL/TLS、打印、数据库、网络、SVG、动画等模块
- 关闭 accessiblity、拼写检查、国际化支持等
- Qt 官方 Qt Lite 项目声称可裁减 ROM 至原来的 23%（即节省 77%）

**实际可期望的极限**（仅 Core+Gui+Widgets，feature 深度裁剪，MSVC Release + LTO）：

| 优化程度 | 静态 .exe 大小 |
|---|---|
| 默认 Release 无优化 | ~15-20 MB |
| -optimize-size + LTO | ~8-12 MB |
| + Qt feature 深度裁剪 | ~5-8 MB |
| + UPX 压缩 | ~2-4 MB |

**结论**：C++ Qt 静态链接 Widgets 应用，工程极限约 **5-8 MB**（未压缩），UPX 后可降至 **2-4 MB**。

---

## 2. 体积差异分层分析

### 2.1 层次分解表

```
基准：C++ Qt 静态链接（feature 裁剪 + LTO）     ~5-8 MB
==========================================================

Python PySide6 (PyInstaller onedir) 成本拆解：

  A. Qt 运行库（与 C++ 相同）
     Qt6Core.dll                               5.8 MB
     Qt6Gui.dll                                8.8 MB
     Qt6Widgets.dll                            6.2 MB
     qwindows.dll                              0.9 MB
     小计                                    ~21.7 MB

  B. Python 解释器层
     python311.dll                             5.5 MB
     base_library.zip（标准库核心）             1.4 MB
     必要 .pyd（_ssl, _ctypes 等）              1.0 MB
     小计                                     ~7.9 MB

  C. shiboken 绑定运行时
     shiboken6.abi3.dll                        0.4 MB
     小计                                     ~0.4 MB

  D. PySide6 Python 绑定层（.pyd 文件）
     QtCore.pyd                                3.4 MB
     QtGui.pyd                                 4.0 MB
     QtWidgets.pyd                             5.9 MB
     小计                                    ~13.3 MB

  E. 加密库（Qt SSL 依赖，可关闭）
     libcrypto-3-x64.dll                       4.9 MB
     小计                                     ~4.9 MB

  F. MSVC 运行时
     msvcp140 等                               2.0 MB

总计（无 SSL）：~45 MB
总计（含 SSL）：~50 MB
```

**实测基准（research_notes.md 第10节数据）**：
- PyInstaller + PySide6-Essentials 6.8.0（排除可选模块后）：**59 MB** onedir
- 理论硬下限（仅 Core+Gui+Widgets）：**~45 MB**

### 2.2 为什么 .pyd 文件那么大？

PySide6 的 `QtWidgets.pyd`（5.9 MB）远大于 C++ 应用中等效的业务层代码，原因：

1. **全量类绑定**：shiboken6 为 Qt Widgets 模块中 **所有** C++ 类（QWidget、QPushButton、QLabel、QListWidget……共 200+ 类）生成包装代码。每个类需要：
   - `PyTypeObject` 结构体（Python 类型系统注册）
   - 每个方法的分发函数（处理 Python→C++ 参数转换）
   - 类型检查、引用计数桥接、异常转换代码
   - 信号/槽机制的元对象桥接代码

2. **无 dead-code elimination**：.pyd 是共享库（DLL），链接器无法跨模块裁剪，即使应用只用了 QLabel，QFileDialog 等 199 个类的代码也全部存在。

3. **与 nanobind/pybind11 对比**：nanobind 比 pybind11 生成的绑定代码小 3-10x；shiboken6 的代码生成策略更保守（兼容性优先），体积偏大。

4. **双重 Qt 层**：.pyd 文件本身链接 Qt DLL（如 Qt6Widgets.dll），加上 Python 包装层，所以总存储是 Qt DLL + 绑定层，而纯 C++ 静态链接只有一份。

---

## 3. 缩小差距的可行方案

### 方案排序（实际效果 / 工程成本 比）

#### Tier 1：高性价比，已有成熟工具

**方案 A：模块子集构建（已研究，最推荐）**
- 手段：源码构建 PySide6，`--module-subset=Core,Gui,Widgets`
- 效果：从 ~59 MB → **~42-48 MB**（估算）
- 工程成本：高（需配置 Qt + shiboken 构建环境，约 1-3 天）
- 可行性：已有先例，Qt 官方支持

**方案 B：PyInstaller 手工排除 + 版本选择**
- 手段：`--exclude-module` 排除不用的 PySide6 模块 + 使用 PySide6 6.8（无 opengl32sw.dll）
- 效果：从 ~66 MB → **~59 MB**（已实测）
- 工程成本：极低（1小时内）
- 可行性：已验证

#### Tier 2：中等性价比

**方案 C：Nuitka 编译**
- 原理：Python 代码 → C++ → 原生机器码，消除解释器开销
- 理论优势：可做静态分析，只打包实际 import 的符号；消除 Python 解释器层（-5.5 MB）
- 实际局限：
  - Nuitka 仍需包含 shiboken 运行时和完整 .pyd 文件（无法跨 .pyd 做 DCE）
  - 社区报告 onefile 模式 PySide6 应用约 **80-100 MB**（含 Qt DLL），比 PyInstaller 还大
  - standalone 模式可能接近 PyInstaller，但无量化数据
  - 编译时间极长（数十分钟）
- **结论**：对体积无明显改善，性能提升约 2-4x，但不是体积方案

**方案 D：UPX 压缩**
- 手段：对 .pyd 和 .dll 执行 UPX 压缩
- 效果：理论可压缩 40-60%，但 Qt DLL 压缩后启动时 CPU 解压有延迟；部分 Qt DLL 不适合 UPX（容易崩溃）
- 实际效果：对合适文件约可减少 **5-10 MB**
- 工程成本：低，但需测试稳定性

#### Tier 3：研究方向，工程成本极高

**方案 E：Qt feature 裁剪（配合模块子集）**
- 手段：在构建 Qt 时禁用 SSL、打印、数据库、SVG 等 feature
- 效果：主要收益是去掉 `libcrypto-3-x64.dll`（-4.9 MB）和部分 Qt DLL 体积减小
- 工程成本：极高（需从源码构建整个 Qt，数天工作量）
- 可行性：技术上可行，但投入产出比低

**方案 F：手写最小绑定（PyO3/cffi）**
- 原理：只为 10-20 个最常用 Qt 类（QMainWindow、QLabel、QPushButton 等）手写 Python 绑定，绑定层本身极小
- 效果：绑定层可能只需 **1-3 MB**（vs shiboken 的 13 MB），节省 ~10 MB
- 工程成本：极高（需维护手写绑定，兼容性差，缺乏信号/槽完整实现）
- 可行性：存在技术可行性（如 PyO3 + Qt C++ 桥接），但无成熟项目

**当前项目（pyside-lite）的方向**：本质上是方案 F 的一种路径尝试。

#### Tier 4：理论方向，当前不可行

**方案 G：RustPython / GraalPy**
- RustPython 尚不支持 C extension（shiboken 依赖 CPython C API），无法运行 PySide6
- GraalPy 虽有 C extension 兼容层，但 PySide6 未在其上测试，稳定性未知
- **结论**：当前不可行，3-5 年内不现实

**方案 H：C++ Qt 嵌入 Python**
- 反向思路：以 C++ Qt 为主体，内嵌 Python 解释器（libpython）作为脚本层
- 可实现更小的基础体积（C++ 壳 + 必要 Qt DLL + libpython），理论约 15-20 MB
- 但这意味着放弃纯 Python 开发体验

**方案 I：其他轻量 GUI 框架**
| 框架 | PyInstaller 打包大小 | 说明 |
|---|---|---|
| tkinter | ~34 MB（onefile）/ ~87 MB（onedir） | 依赖系统 Tcl/Tk，Windows 需附带 |
| wxPython | ~35-50 MB | 依赖系统 GTK/Win32 API |
| PySide6（本项目） | ~45-59 MB | 依赖 Qt DLL |
| Dear PyGui | ~20-30 MB | 基于 Dear ImGui，无原生控件 |

tkinter 体积小于 PySide6，但 UI 能力和外观差距悬殊。

---

## 4. 最终结论

### 4.1 差距有多大？

| 方案 | 最小体积 | 备注 |
|---|---|---|
| C++ Qt 静态链接（feature 裁剪 + LTO） | ~5-8 MB | 单文件 .exe |
| C++ Qt 动态链接（附带 DLL） | ~24-25 MB | 需分发 DLL |
| PySide6 PyInstaller（已优化） | ~59 MB（实测） | onedir，无 WebEngine |
| PySide6 PyInstaller（理论极限） | ~45 MB（估算） | 仅 Core+Gui+Widgets，去 SSL |
| PySide6 Nuitka（不明显改善） | ~60-80 MB（参考） | 无实质体积优势 |

**差距**：PySide6 相比 C++ Qt 静态链接，最小体积差距约 **6-10 倍**（45 MB vs 5-8 MB）。即使与 C++ 动态链接方案（24-25 MB）相比，差距也在 **1.8-2.5 倍**。

### 4.2 差距是结构性的还是工程问题？

**结构性差距（无法消除的）**：

1. **Python 解释器层**（~7.9 MB）：只要用 CPython 运行 Python，这部分不可避免。Nuitka 可消除 python311.dll，但实际节省被其他开销抵消。

2. **双重绑定层**（~13.3 MB .pyd 文件）：shiboken6 必须为每个 C++ 类生成包装代码并存入 .pyd；在 C++ 静态链接中，未使用的类代码被链接器裁剪；而 .pyd 是动态库，无法跨模块 DCE。这是 **Python C extension 架构的根本限制**。

3. **Qt DLL 层**（~21.7 MB）：与 C++ 动态链接版本相同，PySide6 无法省去。只有 C++ 静态链接才能通过 DCE 大幅裁剪这部分。

**工程可改善的**：

1. 去掉不用的 Qt 模块（WebEngine、Multimedia 等）——已在 Tier 1 方案中实现
2. 去掉 SSL 库（-4.9 MB）——需要构建时关闭 Qt SSL feature
3. 使用更高效的绑定工具（nanobind vs shiboken）——3-10x 代码大小减少，理论可将 13.3 MB 的 .pyd 降至 2-4 MB，但需重写整个绑定层

### 4.3 能接近 C++ 体积吗？

**短期内（现有工具链）**：不能。PySide6 的实际工程极限约 45 MB，是 C++ 静态链接（8 MB）的 5-6 倍。

**从架构角度**：如果接受手写极简绑定（方案 F）+ 仅静态分析所用类 + 消除解释器层，理论上可以接近，但这本质上是在重新实现一套 Qt Python 绑定，工程量相当于从头开发。

**实践结论**：
- Python + Qt 的体积劣势是 **结构性 + 工程性的组合**，结构性部分（Python 解释器 + 绑定双重层）无法在现有架构内消除，约 15 MB 的不可削减差距。
- 最切实可行的目标：通过模块裁剪将 PySide6 打包产物降至 **40-45 MB**，这已接近理论硬下限。
- 若应用体积是最高优先级，应考虑重新评估技术栈（C++ Qt 或 tkinter），而非在 PySide6 上继续优化。

---

*本文基于 Qt 社区论坛数据、Qt 官方博客（Qt 6.8 binary size series）、PyInstaller/Nuitka 社区讨论，以及 research_notes.md 中的实测数据综合分析。*
