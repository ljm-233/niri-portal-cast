# QQ 屏幕共享内存暴涨的定位（可直接贴上游）

环境：Arch Linux + **niri**（自编译，`niri-portal-cast` 补丁）+ `linuxqq-wayland-fix` 0.2.8-1 + QQ 3.2.34-53644，
整屏 2560×1600（eDP-1），客户端走 portal 采集。

## 现象

一开屏幕共享，`/proc/meminfo` 的 `Shmem` 就一路涨，几十秒到十几 GiB，整机卡死。共享一停立刻回落。

## 定位方法（都可复现）

- **按进程归属**：读每个进程 `/proc/PID/smaps_rollup` 的 `Pss_Shmem`（注意 `smaps_rollup` 里**没有** `Shmem:` 字段）、
  `/proc/PID/fd` 里 `memfd:`/`/dev/shm/`/`/dmabuf:` 的 fd 与大小、以及 `/proc/PID/fdinfo/*` 里 i915 的
  `drm-total-system0`（GEM）。
- 关键前提：**i915 的 GEM 是 shmem 记账的，但不进任何进程的 smaps**。在本机上 `Shmem` 总量 1484 MiB，
  而所有进程 `Pss_Shmem` 之和只有 268 MiB —— 差额就是 GPU 侧对象。只看 smaps 会得出「没有人在占」的错误结论。

## 数据

整屏共享，`Shmem` 与某**单个** QQ 子进程的 GEM 一比一同步增长：

| 时刻 | Shmem | QQ 的 GEM |
|---|---|---|
| +0 s | 1.234 GiB | 0.051 GiB |
| +3 s | 1.984 GiB | 0.875 GiB |
| +6 s | 2.996 GiB | 1.967 GiB |
| +9 s | **4.654 GiB** | **3.575 GiB** |

同期 niri 完全不动：GEM 平在 0.59 GiB、fd 数平在 124、memfd 声明量平在 1.077 GiB；
portal 也不动，它那 6 个 1 GiB 的 Vulkan memfd 常驻始终为 0。
`pw-cli destroy` 掉采集流节点后 3 秒内 Shmem 从 4.65 回落到 1.20 GiB，**进程没有退出**。

跑这个的进程是：**`qq --type=ppapi`**（收帧+编码的那个），它加载了 `libqq-wl-portal/clipbridge/screenshot/borderfix`。
取它的 DRM client：

```
$ grep -H drm-client-id /proc/$(pgrep -f 'type=ppapi'|head -1)/fdinfo/* | grep -v ':0$'
/proc/1428382/fdinfo/42:drm-client-id:	234
```

## 与帧尺寸/帧率的关系（同机实测）

| 采集尺寸 | 帧率 | 每帧 | 客户端 GEM 增速 |
|---|---|---|---|
| 2560×1600 | 30 | 16.4 MB | **398 MB/s**（≈ 每秒 24 帧被留住） |
| 1820×1138 | 30 | 8.3 MB | 135 MB/s |
| 1214×758 | 30 | 3.7 MB | 29 MB/s |
| 960×600 | 15 | 2.3 MB | **25 MB/s** |

把帧缩小 7 倍、帧率砍半，增速只从 398 降到 25 —— 说明除了按帧的部分，还有一个**与画面大小基本无关的
固定驻留速率（约 25 MB/s）**。

## 已排除

- **不是 niri**：整段过程里 niri 的 GEM / fd / memfd 声明量全平；也没有一次
  `no available buffer in pw stream`（说明客户端并没有占着 niri 的 PipeWire 缓冲，而是自己拷一份留下）
- **不是 portal / PipeWire**：`xdg-desktop-portal-gnome` 的 GEM 平（0.034 GiB），它持有的 memfd 常驻为 0
- **不是内核参数**：`transparent_hugepage=shmem:never` 在这台内核上是无效写法
  （`huge_memory: transparent_hugepage= cannot parse, ignored`），实际策略一直是默认的 `advise`，
  所以「THP 已关」这个前提不成立（但它也不是主因）

## 内存对象长什么样（卡在这里）

- 客户端 `/proc/PID/fd` 里 **`/dmabuf:` 数量恒为 0**，而 GEM 涨到 1 GiB —— 说明它用的是 **GEM handle**
  （`DRM_IOCTL_GEM_CREATE` 的句柄，不开 fd），这也解释了为什么 fd 表、`smaps`、`fincore` 全都看不到
- `/sys/kernel/debug/dri/1/i915_gem_objects` 只给全系统汇总：`1620 shrinkable objects, 1434402816 bytes`
  （平均 ≈ 885 KB/个，混合尺寸），**没有按客户端拆分**
- `/sys/kernel/debug/dri/1/clients` 是**文件不是目录**，所以拿不到 per-client 的对象清单

## 建议的排查方向（客户端侧）

1. 在 **niri（纯 shm 路径）** 下复现：维护者在 GNOME 上测不出来，很可能因为 GNOME 走 dmabuf；
   Electron 客户端不认 DMA-BUF，niri 只能宣告 shm —— **这条 shm 路径可能就是必要条件**
2. 盯 `--type=ppapi` 进程里每帧的处理链路：收到 PipeWire 帧之后是否每次都 `GEM_CREATE` / 建 EGLImage /
   建纹理而**从不释放**（24 帧/秒 × 16 MB 正好对上 398 MB/s）
3. 若无法复现，可用上面那组命令采一份 niri 环境下的数据对比

---

采集工具（本机自用，含自动刹车，防冻机）：`niri-shm-attrib`（`niri-portal-cast` 包内）
