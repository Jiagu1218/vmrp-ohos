# 网络下载提速优化

## 背景

模拟器中浏览器/应用的下载速度很慢（约 15-30 KB/s），影响用户体验。
通过分析网络数据通路，定位了两个主要瓶颈并修复。

## 卡点分析

### 数据通路

模拟器网络栈是**裸 socket**（非 HTTP 库），分两条路径：

1. **Lua DSM 路径**：`mr_tcp_target.c:meth_receive` → `mr_recv` → `my_recv` → `checkReadable(select 50ms)` → `recv()`
   - 受 `BUF_SIZE=1500` 限制（每次最多 1500 字节）
2. **ARM EXT 路径**：`arm_ext_executor.c case 87` → `mr_recv` → `my_recv` → `checkReadable(select 50ms)` → `recv()`
   - 不受 `BUF_SIZE` 限制，直接 recv 到 ARM 客户机内存

两条路径最终都汇入 `network.c` 的 `my_recv` / `my_send`。

### 第一卡点：checkReadable / checkWritable 的 50ms select 超时

```c
// network.c:877-898  checkReadable
struct timeval timeout = { .tv_sec = 0, .tv_usec = 1000 * 50 };  // 50ms
int ret = select(max_sd + 1, &readfds, NULL, NULL, &timeout);
```

- 有数据时 `select` 立即返回（不受超时影响）
- **无数据时等满 50ms 才返回 0**
- `my_recv` 和 `my_send` 各调一次 → 每次 recv 往返最多浪费 100ms

### 第二卡点：高频路径大量 printf

```c
// network.c:956, 963, 979  my_recv 里每次 recv 打 3 行 printf
printf("my_recv(s:%d, fd:%d, len:%d): checkReadable=%d\n", ...);
printf("my_recv(s:%d): recv=%d, errno=%d\n", ...);
printf("my_recv data: [%s]\n", preview);
```

每次 recv 往返 3+ 行 printf，I/O 开销在毫秒级。

### 第三卡点：CMWAP 代理模拟首次连接冻结

MRP 应用 CMWAP 模式连 `10.0.0.172` 时，`my_send` 第一次调用同步执行 DNS + 阻塞 connect（最多 2 秒），冻结整个 worker 线程。仅影响首次连接。

### 第四卡点：timer tick 驱动频率

ARM ext 路径 timer interval 固定 50ms（`mythroad.c:4342`），guest 代码只在 timer 回调里运行 recv。

## 修复内容

### 修复 1：select 超时 50ms → 5ms（OHOS_NET_SPEEDUP）

`scripts/CMakeLists.txt` 新增 `OHOS_NET_SPEEDUP` 补丁块，修改 `network.c`：

- `checkReadable`：`.tv_usec = 1000 * 50` → `1000 * 5`
- `checkWritable`：`.tv_usec = 1000 * 50` → `1000 * 5`

有数据时照常立即返回，无数据时空等从 50ms 降到 5ms。

### 修复 2：高频 printf → VMRP_NET_LOG（OHOS_NET_SPEEDUP）

将 `my_send`（2 行）和 `my_recv`（3 行）共 5 处 printf 替换为已有的 `VMRP_NET_LOG` 宏。

`VMRP_NET_LOG`（`network.c:70-78`）默认不输出，仅设了 `VMRP_NETWORK_LOG` / `VMRP_LOG` 环境变量时才写 stderr。低频路径（connect/socket/close/getHostByName）的 printf 保持不变。

### 修复 3：proxy.51mrp.com DNS 映射跟上游一致

`entry/src/main/cpp/vmrp_engine.cpp` 中 DNS Map：

```
proxy.51mrp.com->127.0.0.1  →  proxy.51mrp.com->159.75.119.124
```

之前被改成了 `127.0.0.1`（本地无代理服务时下载直接失败），改回上游默认值 `159.75.119.124`。

## 未修复（已知但不改）

| 卡点 | 原因 |
|------|------|
| `BUF_SIZE=1500` | 仅影响 Lua 路径，ARM EXT 路径不受限；增大需 guest 配合且增加内存 |
| timer interval 50ms | 由 ARM ext 代码控制，宿主层改动风险高 |
| CMWAP 首次连接冻结 | 改异步需引入状态同步复杂度，且只影响首次连接 |

## 涉及文件

- `scripts/CMakeLists.txt` — `OHOS_NET_SPEEDUP` 补丁块（select 超时 + printf）
- `entry/src/main/cpp/vmrp_engine.cpp` — DNS Map proxy.51mrp.com 修正
- `scripts/build_libvmpp_ohos.bat:186` — `network.c` 已在 `:restore_patched` 列表中

## 代理服务器说明

模拟器使用裸 socket，**不受系统代理（VPN/Wi-Fi代理/全局代理）影响**：
- 不读 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` 等环境变量
- 不用 libcurl 等自动处理系统代理的库
- 不做 SOCKS5 / HTTP CONNECT 隧道（CMWAP 的 CONNECT 解析仅模拟运营商网关）

MRP 应用自己的业务代理通过 DNS Map 映射（`proxy.51mrp.com` 等），这是应用层逻辑，与系统代理无关。
