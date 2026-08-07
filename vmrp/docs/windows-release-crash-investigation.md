# Windows Release 崩溃排查记录

## 问题与复现

- 平台：Windows x64，MSVC 14.51.36231，Visual Studio 18 2026 生成器。
- 配置：`Release`（`/O2 /Ob2 /DNDEBUG`）。
- 样本：`test/fixtures/optwar.mrp`，大小 477683 字节；未修改二进制资源。
- 命令：在 `build/Release` 下执行 `./skyengine.exe ./mythroad/optwar.mrp`。
- 结果：稳定以 `0xC0000005` 崩溃在 `0x00007FF6C937DDCA`。

## 已确认事实

1. `mrp_open()` 已完成并返回非空 `vm_state`。
2. 崩溃发生在 `mrp_open_base(vm_state)` 内，早于 `mrp_open_string()`，也早于加载和执行 MRP 内的 `start.mr`。
3. `dsm_init()` 已调用 `mr_baselib_init()`；基础库函数表并非未初始化。
4. Debug 构建不会在此处崩溃，问题与 Release 优化或 `NDEBUG` 改变的代码语义相关。
5. 当前 Release 可执行文件没有 PDB；将通过带符号的优化构建、异常上下文和 `dumpbin` 反汇编互相校验崩溃指令。

## 根因

异常日志和 Release 反汇编给出了同一条因果链：

1. 故障 RVA 为 `0x4B42A`，位于 `src/mythroad/src/mr_table.c` 的 `resize()`，指令是读取旧数组元素的 `cmp dword ptr [r14+rdi*8], 0`。
2. 故障访问目标为 `0xFFFFFFF800000000`；`nasize` 和循环索引为 `0x80000000`，而表的旧数组指针为 `NULL`、旧数组大小为 0。
3. `nasize` 来自 `computesizes()`。纯字符串键表没有数组键时，旧实现以 `n == -1` 为哨兵，并用 `(n == -1) ? 0 : twoto(n)` 产生数组大小。
4. MSVC 14.51 `/O2` 的机器码没有保留 `n == -1` 分支，而是无条件执行 `shl 1, n`。x64 把移位数 `-1` 屏蔽为 31，得到 `0x80000000`，使 `resize()` 错误进入数组收缩循环并越界读取。
5. Debug 机器码保留了条件分支，因此 Debug 不崩溃。问题与 MRP 内容无关；基础库首次向纯字符串键的全局表注册函数即可触发。

修复不关闭优化，也不增加 Windows 特判。`computesizes()` 改为直接维护始终非负的 `optimal_size`：没有数组键时为 0，找到合适的数组分区时更新为 `2^i`。这保持原表扩容算法的结果，同时消除会被编译器错误降级的负数哨兵与条件移位组合。

## 验证计划

1. [完成] 生成带 PDB 的优化构建并采集异常寄存器、模块基址和源码行。
2. [完成] 反汇编 `mrp_open_base` 到 `resize()` 的调用链，确认失败访存的基址和来源。
3. [进行中] 验证修复后的 Release 机器码不再产生 `0x80000000`，并检查 MRP 启动画面。
4. [待完成] 分别构建并运行 Windows Debug、Release，以及相关 `optwar` e2e/PPM 验证。
