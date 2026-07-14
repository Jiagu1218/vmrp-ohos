# game.ext SDK Dispatch Table Index 映射

通过扫描所有 `MOVS R1, #imm; BL sdk_dispatch (0xEB72A0)` 模式，
提取出 game.ext 使用的 SDK table index。

## 调用模式

`sdk_dispatch(code, table_index, param1, param2)` 调用格式：
- `code` (R0): 1 = 普通调用, 2 = timer, 10 = sub-MRP 启动等
- `table_index` (R1): SDK 函数编号
- `param1` (R2), `param2` (R3): 附加参数
- 栈参数: `[sp+0]=param4, sp+4=param5, sp+8=param6, sp+C=param7]`

## Table Index 汇总

### code=1 (普通调用) 使用的 table index

| Index | 十进制 | 出现次数 | 推测函数 | 依据 |
|-------|--------|----------|----------|------|
| 0x00 | 0 | 1 | 初始化/版本 | EB81DC: sdk_dispatch(1, 0, 0, 0) |
| 0x01 | 1 | 多 | 事件处理 | 几乎每个 dispatch 调用链中都出现 |
| 0x02 | 2 | 2 | timer 事件 | EAF2EA |
| 0x04 | 4 | 1 | pause/resume | EAF6AA |
| 0x07 | 7 | 1 | ext 事件 | EBD464 |
| 0x0A | 10 | 14 | sub-MRP dispatch | EB7D3A, EBD58E, EBD5A8 等大量 |
| 0x20 | 32 | 3 | mr_c_load | EB3012, EB3056 (初始化函数) |
| 0x26 | 38 | 1 | mr_c_stop/mr_c_free | EB828E |
| 0x64 | 100 | 1 | tbl_alloc_timer_node | EB9624 内部使用 |
| 0x100 | 256 | 多 | mr_malloc | 几乎每个函数开头 |
| 0x101 | 257 | 1 | mr_free (ext) | EAF2E4 |
| 0x102 | 258 | 1 | mr_realloc | EAF2DE |
| 0x103 | 259 | 1 | mr_getMemoryFree | EAFCB4 |
| 0x10E | 270 | 1 | mr_drawText/屏幕绘制 | EAF6A8 |
| 0x120 | 288 | 5 | mr_open (读) | EB3012, EBA6F4 等 |
| 0x121 | 289 | 9 | mr_read | EB0EA0, EBA66C, EBD39E 等 |
| 0x128 | 296 | 1 | mr_seek | EAF36A |
| 0x129 | 297 | 3 | mr_write | EAF106, EBA6E2, EAF68E |
| 0x130 | 304 | 1 | mr_close | EBDB46 |
| 0x131 | 305 | 3 | mr_info/mr_getLen | EAF0DE, EBDB10, EBA6BA |
| 0x132 | 306 | 2 | mr_getScreenInfo | EB81E2, EBD6CC |
| 0x133 | 307 | 1 | mr_getScreenWidth | EBD660 |
| 0x134 | 308 | 1 | mr_getScreenHeight | EBD5A4 |
| 0x135 | 309 | 5 | mr_setScreenSize/画布 | EB7B86, EBD58A, EBD646 等 |
| 0x1B4 | 436 | 3 | mr_timerStart | EAF568, EAF5AC, EAF5F4 |
| 0x1B5 | 437 | 4 | mr_timerStop | EAF1F2, EAF4F0, EAF516, EAF53C |
| 0x1BF | 447 | 2 | mr_timerGetTime | E866A6, E867CC |
| 0x1C9 | 457 | 1 | mr_connectSync/网络读 | EB8250 |
| 0x1CA | 458 | 1 | mr_connect/网络连接 | EB8234 |
| 0x1CB | 459 | 1 | mr_closeSocket/网络关 | EB8264 |
| 0x1FF | 511 | 2 | mr_getNetworkInfo | EBA716, EBD45C |

### code=0x0A (10, sub-MRP dispatch) 使用的 table index

| Index | 说明 | 调用点 |
|-------|------|--------|
| 0x14A | pack index 'J' (0x4A) | EB7D38 (netpay start) |
| 0x135 | 子模块画布设置 | EBD58A, EBD646, EBD6B2, EBDAE8, EB7B86 |
| 0x130 | 子模块关闭 | EBDB46 |
| 0x131 | 子模块信息查询 | EBDB10 |
| 0x132 | 子模块屏幕信息 | EBD6CC |
| 0x133 | 子模块宽度 | EBD660 |
| 0x134 | 子模块高度 | EBD5A4 |

## 重要发现

1. **code=10 dispatch 不是简单的 sub-MRP 启动**
   它实际上是 game.ext 对其**子模块**（如 netpay.mrp）的 SDK 函数调用接口。
   当 code=10 时，R1 不是 table index，而是**pack 索引字符**（如 'J' = 0x4A）。
   这与 code=1 的 table index 语义完全不同。

2. **0xEB3030 初始化函数**使用 `sdk_dispatch(1, 0x20, 0, 0xA, ...)`，
   即 table[0x20] = mr_c_load。这验证了 table[0x20] = load 的映射。

3. **format_path (0xEB81D0)** 实际是网络资源加载器，使用:
   - table[0x132] = getScreenInfo (获取屏幕参数)
   - table[0x1CA] = connect (连接服务器)
   - table[0x1C9] = connectSync (同步读取响应)
   - table[0x1CB] = closeSocket (关闭连接)
   - table[0x126] = stop/cleanup

4. **compact timer 相关**:
   - table[0x1B4] = timerStart
   - table[0x1B5] = timerStop
   - table[0x1BF] = timerGetTime

5. **文件 I/O**:
   - table[0x120] = open (读模式)
   - table[0x121] = read
   - table[0x128] = seek
   - table[0x129] = write
   - table[0x130] = close
   - table[0x131] = getInfo/getLength

6. **内存管理**:
   - table[0x100] = malloc
   - table[0x101] = free
   - table[0x102] = realloc
   - table[0x103] = getMemoryFree
