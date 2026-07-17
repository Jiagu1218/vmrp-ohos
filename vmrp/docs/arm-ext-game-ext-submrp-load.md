# game.ext 逆向分析：sub-MRP 加载机制

## 概览

game.ext 是 gzwdzjs (悟空传之大闹天宫) 的核心 ARM ext 模块，运行在 vmrp 的
ARM 解释器上。它实现了 MRP SDK 的完整 C 接口，包括 pack 文件系统、子 MRP 启动、
网络支付等功能。

本文档聚焦 **sub-MRP 加载链** — 即 game.ext 如何将 `*J` 命令转化为新 DSM 实例
的完整流程。

## 关键地址表

| 地址 | 函数 | 说明 |
|------|------|------|
| `0xEB43F4` | `main_event_loop` | 主事件循环，调用 load_sub_mrp |
| `0xE8B160` | `load_sub_mrp` | sub-MRP 加载入口 |
| `0xE8B0CC` | `parse_star_J` | 解析 `*J,path` 格式 |
| `0xE8B068` | `parse_restart_cmd` | 解析 `restart` 命令 |
| `0xEB94F0` | `strchr_not_null` | 查找字符串中首个匹配字符 |
| `0xEB9540` | `alloc_timer_node` | 分配 0x20 字节定时器节点 |
| `0xEB9624` | `tbl_dispatch_100` | table[100] 分发（核心 dispatch） |
| `0xEB9590` | `linked_list_remove` | 双向链表节点删除 |
| `0xEB7390` | `mr_free` | 释放内存 |
| `0xE9B14C` | `mr_open_read` | 打开文件读取 |
| `0xE9B0B8` | `lookup_m0_index` | 在 m0 列表中查找文件索引 |
| `0xEB7E74` | `dsm_call_entry` | DSM 入口调用包装 |
| `0xEB72A0` | `sdk_dispatch` | SDK 函数间接分发 |
| `0xEB7CF4` | `start_netpay` | 启动 netpay.mrp 子模块 |
| `0xEB4D54` | `post_load_init` | 加载后初始化（设置 DSM 环境等） |
| `0xEB4BCC` | `get_current_dsm_state` | 获取当前 DSM 状态/数据区 |
| `0xEB483C` | `check_loop_condition` | 检查主循环条件 |

## 关键字符串

| 地址 | 字符串 | 用途 |
|------|--------|------|
| `0xEBF160` | `"mtk"` | MTK 平台标识前缀 |
| `0xEBF1A0` | `".mrp"` | MRP 文件扩展名 |
| `0xEBF1A8` | `"*J,games"` | sub-MRP 加载命令前缀 |
| `0xEBF184` | `"*B"` | 另一种 pack 引用格式 |
| `0xEC1504` | `"restart"` | 重启当前 DSM 命令 |
| `0xEBF3C8` | `"netpay.mrp"` | 网络支付子模块 |
| `0xEBF170` | `"MSEG"` | 段文件格式标识 |
| `0xEBF178` | `"local.seg"` | 本地段文件 |
| `0xEBF188` | `"default.seg"` | 默认段文件 |
| `0xEBF194` | `"firm.seg"` | 固件段文件 |
| `0xEBF1BF` | `"runState.sav"` | 运行状态保存文件 |
| `0xEBF1D0` | `"20.rep"` | 20x20 区域报告文件 |
| `0xEBF1E4` | `"ydqtwo"` | 游戏标识(悟空传) |
| `0xEBF1EC` | `"applist"` | 应用列表 |
| `0xEBF1F4` | `"cookie"` | Cookie 存储 |
| `0xEBF210` | `"cookie.mrp"` | Cookie 子模块 |

## 详细流程

### 1. 主事件循环 (`0xEB43F4`)

```
main_event_loop():
    // 清空本地栈变量
    memset(stack, 0, 0x10)
    
    // 初始化阶段
    init_sound()           // 0xEAC048
    init_display()         // 0xEAB928
    
    loop:
        if check_loop_condition() != 0:  // 0xEB483C
            goto exit_loop               // 0xEB4544
            
        dsm_state = get_current_dsm_state()  // 0xEB4BCC
        
        // 检查键盘事件
        key = check_key_event(0x1A, 1)   // 0xE87194
        
        // 处理键盘状态
        if key_pressed:
            handle_key()                 // 0xEBCC94
            
        // 检查定时器事件  
        check_timer(0x33, 1)             // 0xE871E0
        if timer_fired:
            call_dsm_entry(DSM_EVENT, 0, 0, 0)  // 0xEB7E74
            
        // 检查是否需要加载新 DSM
        if check_need_load() != 0:       // 0xEB483C
            goto exit_loop
            
        // 获取当前路径
        dsm_state = get_current_dsm_state()  // 0xEB4BCC
        current_path = get_path()            // 0xE87314
        
        // 格式化显示
        format_path(dsm_state, current_path)  // 0xEB3CCC
        
        if path != NULL:
            // 检查是否是特殊路径
            if strcmp(path, "*J,games") == 0:  // GOT 间接
                format_with_mtk_prefix(path)
                // ... 处理 *J,games 特殊路径
            
        // 加载 sub-MRP
        dsm_state = get_current_dsm_state()  // 0xEB4BCC
        result = load_sub_mrp()               // 0xE8B160 ★
        
        if result == 0:
            goto loop_exit  // 成功，退出循环
            // (实际上跳到 0xEB4432 = 清理并返回)
            
        // 加载失败，尝试后续
        post_result = post_load_init()  // 0xEB4D54
        if post_result != 0:
            goto loop_exit
            
        // 继续尝试加载 applist/cookie 等
        dsm_state = get_current_dsm_state()
        result2 = load_applist()        // 0xE99AFC
        ...
```

### 2. sub-MRP 加载 (`0xE8B160`)

```c
int load_sub_mrp(char *path) {
    // R4 = GOT[0x4E4] — 状态结构体
    // R7 = GOT[0x684] — pack_filename 缓冲区
    
    state = R9 + GOT[0x4E4];
    state->offset_0x10 = -1;              // 标记未初始化
    memset(R9 + GOT[0x684], 0, 0x10);     // 清空 pack_filename
    
    if (path == NULL)
        return -1;
    
    // 分支 1: 路径是 "*J,games" 字面量
    if (strcmp(path, "*J,games") == 0) {
        memcpy(pack_filename, "mtk", 3);  // 写 "mtk" 前缀
        state->offset_0x0C = 0;
        tbl_dispatch_100(state, 100, -1, NULL);  // EB9624
        return 0;  // (实际跳到 0xE8B1D0 = pop 返回)
    }
    
    // 分支 2: 尝试 *J 格式解析
    if (parse_star_J(path) == 0) {         // E8B0CC
        // 成功解析了 "*J,<pack_path>" 格式
        // parse_star_J 已经处理了路径复制和 table dispatch
        return 0;
    }
    
    // 分支 3: 直接路径 — 尝试作为文件打开
    fd = mr_open_read(path, 2, state->offset_0x10);  // E9B14C
    if (fd != -1) {
        // 成功打开，分配定时器节点并 dispatch
        node = alloc_timer_node();                    // EB9540
        state->offset_0x0C = node;
        tbl_dispatch_100(node, 100, fd, NULL);        // EB9624
        return 0;
    }
    
    // 分支 4: 文件打开失败 — 在 m0 文件列表中查找
    m0_char = lookup_m0_index(state->offset_0x10);   // E9B0B8
    if (m0_char == -1) {
        // 查找也失败 — 可能是 restart 命令
        parse_restart_cmd(state->offset_0x10);        // E8B068
        return 0;
    }
    
    // 分支 5: 在 m0 中找到 — 写入 *J 格式到 pack_filename
    node = alloc_timer_node();                        // EB9540
    pack_fn = R9 + GOT[0x4E4] + 0x14;
    pack_fn[0] = '*';                                 // 0xE8B216
    pack_fn[1] = m0_char;                             // 0xE8B218 (m0索引字符)
    pack_fn[2] = 0;                                   // 0xE8B21A
    state->offset_0x0C = node;
    tbl_dispatch_100(pack_fn, 100, m0_char, NULL);    // EB9624
    return 0;
}
```

### 3. `*J` 格式解析 (`0xE8B0CC`)

```c
int parse_star_J(char *path) {
    // 检查前缀 "*J,"
    if (path[0] != '*' || path[1] != 'J' || path[2] != ',')
        return -1;  // 不是 *J 格式
    
    pack_path = path + 3;  // 跳过 "*J,"
    
    // 查找路径中的空字符或特定分隔符
    end = strchr_not_null(pack_path);  // EB94F0
    
    if (end == NULL)
        return -1;
    
    path_len = end - pack_path;
    
    // 将 pack 路径复制到 GOT[0x684] 缓冲区
    memcpy(GOT[0x684], pack_path, path_len);  // 通过 R9 间接
    
    // 追加 ".mrp" 后缀
    memcpy(GOT[0x684] + path_len, ".mrp", 4);
    
    // 打开文件获取句柄
    fp = fopen(GOT[0x684], ...);           // 通过 GOT 函数指针
    
    // 读取文件到 DSM 数据区
    fread(sp_buf, fp, ...);                // 通过 GOT 函数指针
    
    // 将文件长度存入状态
    state->offset_0x10 = file_length;
    
    return 0;  // 成功
}
```

### 4. restart 命令解析 (`0xE8B068`)

```c
void parse_restart_cmd(int param) {
    // 清空本地状态
    memset(stack_buf, 0, 0x14);
    stack_buf[0x14] = 0;
    
    // 标记重启状态
    R9 + GOT[some_flag] = 1;
    
    // 调用 SDK 分发
    mr_setRestart(0x0A, 1, &stack_buf[0x14]);  // E87B44
    
    // 执行清理操作
    cleanup_1();   // 0xEB9DE8
    cleanup_2();   // 0xE88CE8
    cleanup_3();   // 0xE89484
    cleanup_4();   // 0xE9AD50
    
    // 设置新 DSM 状态
    stack[0] = param;
    stack[1] = 0;
    stack[2] = 2;  // DSM_TYPE = 2
    
    // 请求新的 DSM
    mr_requestNewDSM(0x112, 4, stack);  // EA05CC
    
    // 等待 DSM 就绪
    mr_waitDSMReady(stack, 4);           // EAD52C
}
```

### 5. `*J` 格式写入（pack_filename 构造）

核心代码在 `0xE8B20C-0xE8B224`：

```asm
0xE8B20E: MOVS R2, #0x2A        ; '*' (0x2A)
0xE8B210: ADD  R1, SB           ; R1 = R9 + GOT_base
0xE8B212: ADDS R1, #0x14        ; R1 = &pack_filename (R9 + GOT + 0x14)
0xE8B216: STRB R2, [R1]         ; pack_filename[0] = '*'
0xE8B218: STRB R6, [R1, #1]     ; pack_filename[1] = m0_index_char
0xE8B21A: MOVS R2, #0           ; null terminator
0xE8B220: ADDS R2, R1, #0       ; R2 = pack_filename 地址
0xE8B222: MOVS R1, #0x64        ; R1 = 100 (table index)
0xE8B224: BL   tbl_dispatch_100 ; 调用核心 dispatch
```

### 6. table[100] 分发 (`0xEB9624`)

```c
int tbl_dispatch_100(void *node, int table_idx, void *data, void *extra) {
    // node 是刚分配的 0x20 字节结构
    // table_idx = 100
    
    if (node == NULL)
        return 0;
    
    // 检查 SDK 状态
    struct_ptr = GOT[0x3C_offset];     // 通过 PC-relative + SB
    state = struct_ptr->offset_0x5C;
    sdk = state->offset_0x08;
    sdk_state = *sdk;
    
    if (sdk_state == 3 || sdk_state == 4)
        return 0;  // SDK 忙碌
    
    // 验证 table_idx
    if (node[0x08] != 0x... )  // 魔数验证
        return 0;
    
    if (table_idx < 0)
        return 0;
    
    // 存储参数
    if (table_idx > 0)
        node[0x10] = table_idx;
    
    // 获取基地址
    base = struct_ptr->offset_0x38 + 0x80;
    base_addr = base[0x04]();          // 调用函数获取基址
    node[0x0C] = base_addr + table_idx;
    
    // 存储额外参数
    node[0x14] = data;
    node[0x18] = extra_from_stack;
    node[0x1C] = stack_param;
    
    // 从链表中移除 node（如果已在链中）
    linked_list_remove(node);          // EB9590
    
    // 插入到活跃链表
    // 检查主链表或备用链表
    list_head = GOT[...];
    if (list_head != 0) {
        // 按地址排序插入
        insert_sorted(node, list_head);
    }
    
    return 0;
}
```

### 7. netpay.mrp 启动 (`0xEB7CF4`)

```c
int start_netpay(int param1, int param2, int param3, int param4) {
    // param1 (R0) 被忽略，使用固定参数
    
    state = R9 + GOT[0xF8AC];
    if (state->offset_0x2C == 1)  // 已初始化
        return -1;  // (0xFFFFFFFF)
    
    // 保存额外参数
    state->offset_0x54 = stack_param;  // 来自 [SP+0x30]
    
    // 格式化 "netpay.mrp" 路径
    path_ptr = "netpay.mrp";  // PC-relative string at 0xEC12DC
    result = network_load(path_ptr, ...);  // 0xEB81D0
    
    if (result < 0x1B)  // 0xFF6C = -148 (加载失败阈值)
        goto skip;
    
    // 检查文件是否存在（通过 table[0x20] = mr_c_load）
    exists = check_file_exists();  // 0xEB3030
    if (exists != 0)
        goto skip;
    
    // 调用 SDK dispatch 启动子模块
    // 参数: code=10, R1='J'(0x4A), param3, param4
    result = sdk_dispatch(10, 0x4A, param3, param4);  // 0xEB72A0
    
    return result;
}
```

注：netpay.mrp 出现在 4 个不同位置（0xEBF3C8, 0xEC02A4, 0xEC089C, 0xEC12DC），
可能对应不同的调用上下文（本地加载 vs 网络下载后加载）。

## SDK dispatch 机制 (`0xEB72A0`)

### 两种 dispatch 模式

**模式 A: code=1, table_index=SDK函数编号**

game.ext 通过 `sdk_dispatch(1, table_index, ...)` 调用 SDK 函数：
- table[0x100] = malloc, [0x101] = free, [0x102] = realloc
- table[0x120] = open, [0x121] = read, [0x128] = seek, [0x129] = write, [0x130] = close
- table[0x1B4] = timerStart, [0x1B5] = timerStop, [0x1BF] = timerGetTime
- table[0x1CA] = connect, [0x1C9] = connectSync, [0x1CB] = closeSocket
- 完整映射见 `arm-ext-game-ext-sdk-table.md`

**模式 B: code=10, R1=pack索引字符（sub-MRP 调用）**

当 code=10 时，R1 不是 table index，而是 pack 索引字符（如 `'J' = 0x4A`）。
这是 game.ext 对其**子模块**（netpay.mrp 等）的 SDK 函数调用接口。

```
sdk_dispatch(code, R1_param, param1, param2):
    R4 = code          (1=SDK调用, 10=sub-MRP调用)
    R5 = R1_param      (code=1: table_index, code=10: pack字符)
    R6 = param1
    R7 = param2
    
    // 加载 dispatch 结构
    R2 = PC-relative data struct
    R3 = [R2, #0x3C]      → 第一级结构
    R0 = [R3, #0xC]       → 第二级结构
    R7 = [R0, #0x28]      → 函数指针!
    
    // 设置栈参数
    [SP+0xC] = 2          → dispatch type
    [SP+0x8] = R1_param   → table_index 或 pack字符
    [SP+0x4] = code       → 1 或 10
    [SP+0x0] = param2     → 来自调用者
    
    // 调用
    BLX R7  →  call(code, R1_param, param1, param2,
                     [stack: param2, code, R1_param, 2])
```

这个 dispatch 链对应 vmrp 宿主端的 `arm_ext_executor.c` 中的处理路径。
code=10 最终触发 `mr_c_load` 或等效操作，code=1 通过 SDK table 路由到具体函数。

## `*B` 格式

### 写入模式

`*B` 的写入模式在 game.ext 中有 13+ 处，统一格式：

```asm
MOVS R0, #0x42           ; 'B'
ADD  R3, SP, #offset     ; 栈缓冲区
STRB R0, [R3, #N]        ; buf[N] = 'B'
STRB Rn, [R3, #N+1]      ; buf[N+1] = index_char (如 0 表示默认)
...
BL   dispatch_B          ; 0xE91064
```

### dispatch_B 函数 (`0xE91064`)

```c
int dispatch_B(char *pack_ref, int callback_flag) {
    // pack_ref = "*B<index>", 如 "*B\0" 或 "*BA"
    
    // 获取当前 ext 数据
    ext_data = get_ext_data();          // 0xEB751C -> struct+0x80+0x04
    index = ext_data.get_index();       // 0xEADED4 (复杂函数)
    
    // 格式化路径
    sprintf(path_buf, "/%s/%d", index); // "%d" at 0xEC0A20
    
    // 打开并读取文件
    fd = mr_open(path_buf, 0x0A);       // 0xEB7D60
    file_data = mr_read();              // 0xEB63C4
    
    // 调用 DSM 入口
    dsm_call_entry(DSM_CODE, pack_ref, 1, &callback);  // 0xEB7E74
    // DSM_CODE = 0x4B4 (1204) — 来自 GOT 间接
    
    // 如果有回调，执行
    if (callback) callback(param1, param2);
    
    // 清理
    mr_close();                         // 0xEB8B90
    
    return result;
}
```

### `*B` 与 `*J` 的区别

| 特征 | `*J` | `*B` |
|------|------|------|
| 格式 | `*J,<path>` | `*B<index_char>` |
| Pack | J = m0/games pack | B = seg/资源 pack |
| 引用 | MRP 子模块 | seg 段文件 |
| 路径 | 从 `*J,` 后提取完整路径 | 通过索引查 seg 表 |
| 关联字符串 | `"*J,games"`, `"mtk"` | `"*B"`, `"default.seg"`, `"firm.seg"` |
| Dispatch | `tbl_dispatch_100` (0xEB9624) | `dispatch_B` (0xE91064) |
| DSM code | code=10 | code=0x4B4 |
| 调用次数 | 1 处写入 | 13+ 处写入 |

### `*B` 出现位置

| 地址 | 上下文 | index_char |
|------|--------|-----------|
| 0xE87272 | 文件加载 | R0=0x42, [SP+4]=B, [SP+5]=0 |
| 0xE87A28 | 菜单/事件处理 | [SP+0]=B, [SP+1]=0 |
| 0xE90390 | 主循环 seg 加载 | [SP+0x14]=B, [SP+0x15]=0 |
| 0xE98EA0 | 显示/渲染 | [SP+0x34]=B, [SP+0x35]=? |
| 0xE991BE | 资源管理 | [SP+0x24]=B, [SP+0x25]=0 |
| 0xEA7FB8 | UI 控件 | [SP+0x14]=B, [SP+0x15]=? |
| 0xEB2C36 | 初始化 | [SP+0x34]=B, [SP+0x35]=0 |
| 0xEB4F38 | Cookie 处理 | [SP+0x60]=B, [SP+0x61]=0 |
| 0xEB550A | 支付/网络 | [SP+0x34]=B, [SP+0x35]=? |
| 0xEB5876 | 子模块 dispatch | [SP+0x20]=B, [SP+0x21]=? |
| 0xEB5B62 | 子模块 dispatch 2 | [SP+0x20]=B, [SP+0x21]=? |
| 0xEB5DC6 | 子模块 dispatch 3 | [SP+0x20]=B, [SP+0x21]=? |
| 0xEBB5F8 | 网络/支付 | [SP+0x40]=B, [SP+0x41]=0 |
| 0xEBCE14 | 主循环 | [SP+0x60]=B, [SP+0x61]=? |
| 0xEBCF28 | 事件处理 | [SP+0x38]=B, [SP+0x39]=? |

## MTK 前缀

`"mtk"` 在 0xEBF160 处出现。当 `*J,games` 作为字面路径传入时，
game.ext 会将 pack_filename 设为 `"mtk"` 而非从路径提取。
这表明 MTK 平台的默认 pack 引用约定是 `"mtk"` 前缀。

## MSEG/seg 文件系统

### 字符串表 (0xEBF160 集群)

```
0xEBF160: "mtk"
0xEBF164: "%d-%d-%d"
0xEBF170: "MSEG"         ← 段文件魔数
0xEBF178: "local.seg"    ← 本地段文件
0xEBF184: "*B"           ← B pack 引用
0xEBF188: "default.seg"  ← 默认段文件
0xEBF194: "firm.seg"     ← 固件段文件
0xEBF1A0: ".mrp"
0xEBF1A8: "*J,games"
0xEBF1B4: "_1X"
0xEBF1B8: "/%s"
0xEBF1BC: "l1XrunState.sav"
0xEBF1D0: "20.rep"
0xEBF1E4: "ydqtwo"
0xEBF1EC: "applist"
0xEBF1F4: "cookie"
0xEBF1FC: "dsm"
```

### MRP 文件头解析 (`0xE8EFD0`)

```c
int parse_mrp_header(int file_id, int mode) {
    // 分配文件映射缓冲区
    buf = mr_map_file(file_id);         // 0xEB73E8
    
    // 设置地址范围校验
    R9[0x30] = buf + 0x140000;          // 高地址
    R9[0x34] = buf - 0x140000;          // 低地址（包装为 unsigned）
    
    if (buf == NULL) return -1;
    
    // 读取 8 字节大端序 MRP 文件头 (buf+0xC0)
    // buf+0xC0: 4 字节 = 文件 ID (big-endian)
    // buf+0xC4: 4 字节 = 文件大小 (big-endian)
    id   = (buf[0xC0]<<24) | (buf[0xC1]<<16) | (buf[0xC2]<<8) | buf[0xC3];
    size = (buf[0xC4]<<24) | (buf[0xC5]<<16) | (buf[0xC6]<<8) | buf[0xC7];
    
    // 验证文件 ID
    if (id != file_id) return -1;
    
    // 返回文件索引
    return buf[SP+1];  // 从栈变量读取
}
```

## DSM 状态格式化 (`0xEBDCCC`)

```c
int format_dsm_state(int table_idx, char *path) {
    // 打开 MRP 文件
    fd = mr_open_file(0xC3501, 1);      // 0xE8EFD0 (MRP 头解析)
    
    if (table_idx == 0x64) {            // 100 = *J,games 表
        if (strcmp(path, "*J,games") == 0) {
            // 这是 *J,games 路径
            // 检查索引范围
            if (fd + offset < 0x35) {   // 53 个文件限制
                // 调用 DSM 入口
                dsm_call_entry(DSM_CODE, 0, &count, &list);  // 0xEB7E74
                // 遍历文件列表
                for (i = 0; i < count; i++) {
                    // 地址范围检查
                    if (list[i] >= R9[0x30] || list[i] <= R9[0x34]) {
                        // 有效地址
                    } else {
                        // 无效地址，需要重新映射
                        memcmp(list[i], path, 3);  // 验证路径
                    }
                }
            }
        }
    }
    return 0;
}
```

## Cookie 子模块

### 字符串表

```
0xEBF1F4: "cookie"
0xEBF210: "cookie.mrp"
0xEBF23F: "cookie.mrp"
0xEBF390: "cookie"
0xEBF4F8: "cookie.inf"
0xEBFD40: "cookie_str.rc"
0xEC0EA0: "cookie"       ← 网络模块上下文
0xEC0EA8: "%4d%2d%2d%2d%2d%2d"  ← 日期格式
```

### 调用链

Cookie 处理在主事件循环的 `*B` dispatch 路径中触发（0xEB4F38），
通过 `dispatch_B("*B\0")` 加载 cookie.mrp 子模块。

在 0xEC0EA0 附近的字符串集群显示 cookie 与系统时间和日期格式化相关：
- `"system/systime"` — 系统时间
- `"%4d%2d%2d%2d%2d%2d"` — 日期时间格式
- `"*B"` — seg pack 引用
- `"list2.db"` — 应用列表数据库
- `"comroot.itm"`, `"payroot.itm"` — 支付/社区根项目

## 主字符串表 (0xEBF160-0xEBF1FC)

这是 game.ext 的核心字符串集群，按功能分组：

| 偏移 | 字符串 | 功能 |
|------|--------|------|
| +0x00 | `"mtk"` | 平台标识 |
| +0x04 | `"%d-%d-%d"` | 数字格式 |
| +0x10 | `"MSEG"` | 段文件魔数 |
| +0x18 | `"local.seg"` | 本地段 |
| +0x24 | `"*B"` | B pack 引用 |
| +0x28 | `"default.seg"` | 默认段 |
| +0x34 | `"firm.seg"` | 固件段 |
| +0x40 | `".mrp"` | MRP 扩展名 |
| +0x48 | `"*J,games"` | J pack 引用 |
| +0x54 | `"_1X"` | 1x 缩放标记 |
| +0x58 | `"/%s"` | 路径格式 |
| +0x5C | `"l1XrunState.sav"` | 运行状态 |
| +0x70 | `"20.rep"` | 区域报告 |
| +0x84 | `"ydqtwo"` | 游戏标识 |
| +0x8C | `"applist"` | 应用列表 |
| +0x94 | `"cookie"` | Cookie |
| +0x9C | `"dsm"` | DSM |

## 与 vmrp 宿主的交互

1. game.ext 通过 `table[100]` dispatch 请求宿主加载新 DSM
2. 宿主的 `arm_ext_executor.c` 处理 `code=10` dispatch
3. 宿主解析 `pack_filename` 中的 `*J` 前缀，确定 pack 索引
4. 宿主从 MRP 包中提取子模块文件
5. 宿主创建新 DSM 实例并调用子模块入口
6. `*B` 格式通过 `dispatch_B` (0xE91064) 独立处理，不经过 table[100]
7. MRP 文件头通过 `parse_mrp_header` (0xE8EFD0) 验证，读取偏移 0xC0 处的 8 字节大端序 ID+大小

## 三层内存分配器

game.ext 使用三层分配器：
1. **LG_mem/bump** — 宿主提供的系统级分配器
2. **wrapper compact 堆** — ext wrapper 的私有堆，从 LG_mem 分配大 arena 后细分
3. **game compact 堆** — game.ext 内部的 compact 分配器，再从 wrapper arena 细分

compact 堆的 free-list 保护是 vmrp 宿主的核心安全机制，防止
timer 节点和模块映像被精灵缓冲覆盖（gzwdzjs 冻结 bug 的根因）。

## R9+0x4E4 状态结构体

GOT[0x4E4] 指向 sub-MRP 加载状态结构体，R9-relative 访问：

| 偏移 | 大小 | 含义 | 证据 |
|------|------|------|------|
| +0x00 | 4 | 链表 prev | linked_list_remove (0xEB9590) |
| +0x04 | 4 | 链表 next | linked_list_remove (0xEB9590) |
| +0x08 | 4 | 魔数/类型 | tbl_dispatch_100 校验 |
| +0x0C | 4 | timer_node 指针 | load_sub_mrp 写入 |
| +0x10 | 4 | -1(未初始化) 或 m0_index | load_sub_mrp 写入 |
| +0x14 | 16 | pack_filename 缓冲区 | `*J` 写入 (0xE8B216) |

总大小: 至少 0x24 字节

该结构体在整个 game.ext 中有 30+ 处引用（literal pool 0x4E4 出现 30+ 次），
核心用户包括 E8B160 (load_sub_mrp), E99xxx (cookie/资源管理), 
EBAxxx (UI 控件), EB9xxx (table dispatch) 等。

## 待进一步分析

- [x] 0xEB81D0 (format_path) — 实为**网络资源加载器**，非简单路径格式化
      - 调用 table[0x132] → table[0x1CA] connect → table[0x1C9] read → table[0x1CB] close
- [x] `*B` 格式的完整解析路径 — 13+ 处写入 `dispatch_B` (0xE91064) 
- [x] game.ext 的 DSM P 结构字段映射 — R9+0x4E4 状态结构体，0x24 字节
- [x] MSEG/seg 文件系统 — MRP 头解析器 0xE8EFD0，8 字节大端序 ID+大小 at +0xC0
- [x] cookie.mrp 子模块 — 通过 *B dispatch 加载，与系统时间/日期相关
- [x] 0xEBDCCC (DSM 状态格式化) — table_index=0x64 时走 *J,games strcmp 路径
- [ ] 0xEB3030 (check_file_exists) — 通过 table[0x20] = mr_c_load 检查文件
- [ ] 0xEB4D54 (post_load_init) — 加载后初始化的完整流程
- [ ] netpay.mrp 支付流程（4 处调用路径的区别）
- [ ] applist 加载和 applist2.sky-mobi.net 网络交互
- [ ] 0xEADED4 (dispatch_B 内部的索引获取函数)
- [ ] 完整的 seg 文件挂载流程（MSEG 魔数验证 → local/default/firm 段选择）
