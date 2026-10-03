# niri-portal-cast

给 niri 打补丁，让 xdg-desktop-portal 的屏幕采集在它上面真正能用。

没有这个补丁时，niri 下的屏幕共享对 Electron 客户端（QQ、飞书等）**完全不可用**——不是画面黑，是根本没有画面。三个补丁修「niri 愿不愿意交画面」和「交多快、交多大」，三个工具负责诊断、调档和刹车。**本包不修内存泄漏**——包里没有一行释放或回收客户端缓冲的代码，它做的是把速率与每帧字节压到客户端消费得下的范围（根因见「实测与根因」）。

## 为什么上游不行
三个互相独立的原因，缺一不可：

**一、不宣告 shm 格式。** Electron 不导入 DMA-BUF，只认 shm。niri 在 `org.gnome.Mutter.ScreenCast` 上没有暴露 shm 格式，那些不带 `VideoModifier` 的格式会被当成普通线性 dmabuf，被 PipeWire 以 "no more input formats" 拒绝。

**二、不宣告能力位。** `AvailableSourceTypes` 和 `AvailableCursorModes` 没有实现，`xdg-desktop-portal-gnome` 因此读到零能力，**拒绝所有 `SelectSources` 调用**。表现是选择窗口时只有「整个屏幕」可选。

**三、帧率不限速。** `VideoFramerate` 宣告为 `0/1` 就是「不限速」，PipeWire 按输出刷新率推帧，而客户端消费不掉——多出来的帧留在客户端自己的 GPU 缓冲里，内存一路涨到机器卡死。

## 装什么版本
- **`niri-portal-cast`（本包）**：三个补丁（shm 宣告、能力位、限帧率与限采集尺寸）+ 三个工具。
- AUR `niri-shm-sharing`：只覆盖 shm 宣告这一步（补丁只改 `src/screencasting/pw_utils.rs`），没有能力位与帧率上限。

## 配置

```kdl
screencasting {
    frame-rate-hz 60      // 帧率上限，范围 5-120，默认 60，超范围静默钳位
    max-pixels 4096000    // 采集分辨率上限（像素数），默认 4096000 = 2560×1600
}
```

两块都不写就用默认值。**限制值是每次开始共享时读的**：改完 `frame-rate-hz` / `max-pixels`，**重开一次共享就生效，不用重启 niri**。核实「到底协商成了什么」看 journal，不要看配置文件：

```
journalctl --user -u niri.service --since '-30min' | grep -E 'framerate|size: spa_rectangle'
```

**不要写 `max-shm-buffers`。** 补丁 0003 已把它删掉（它防的是一个不存在的机制：buffer 数由 PipeWire 协商，niri 只按 `StreamFlags::ALLOC_BUFFERS` 分配）。niri 的配置解析拒绝未知节点，写了这个键 **niri 会直接拒绝启动**，journal 里只有一行 `× unexpected node 'max-shm-buffers'`。

### 采集分辨率（patch 0004）
`max-pixels` 是**每帧字节**的旋钮：宣告出去的尺寸按这个像素上限等比缩小，渲染结果再缩放到该尺寸后才交给客户端。每帧小了，客户端编码器才追得上（挑多大见下表）。

这里同时修掉一个真 bug：上限机制从 0001 就在，但它只缩小了**宣告**的尺寸——damage tracker 按输出尺寸建、`render_to_shmbuf` 也按输出尺寸校验缓冲。任何大于上限的输出（比如 4K 屏）触发上限后，每帧都是 `invalid buffer size`，**一个画面都出不来**；本机屏幕正好 2560×1600，所以从没触发过。现在渲染侧会真的缩放（`Renderer::blit`，保留 SyncPoint），光标元数据同步缩放。

## 工具
三个命令都随包安装，都只读状态或只改配置，不重启任何东西。

### `niri-portal-doctor`
共享不出画面时先跑它（通话中跑也安全）。退出码 0 = 没有阻塞性问题，1 = 有。七节：会话环境 → 二进制来自哪个包 → 桌面门户 → **帧率是否真的生效** → 采集请求与出流 → Shmem 与 shmem 大页策略 → 音频图（有线和蓝牙输出同时在线是采集崩掉的常见原因）。

【四】不看「配置文件里写了什么」就报正常：它拿配置值与 journal 里最近一次实际协商到的帧率对比，再按两者时间戳判断先后——配置比最近一次共享新则**提示**「下次共享生效」（这是正常的，不是故障）；配置更旧却还对不上则**故障**，并提示重开一次共享、确认二进制来自本包。

【六】除 Shmem 外还核对 shmem 大页策略：内核可能把 `transparent_hugepage=shmem:xxx` 这种写法整个丢掉（dmesg 里是 `transparent_hugepage= cannot parse, ignored`），命令行里写了不等于生效，所以它比对 sysfs 实际值与命令行声明，不一致就报注意。本机就是这样：命令行写 `shmem:never`，实际策略是 `advise`。

通用的 [`wayland-cast-doctor`](https://github.com/ljm-233/wayland-cast-doctor) 不绑定合成器（Hyprland / Sway / GNOME / KDE 都能跑），两边不冲突；建议先跑本包这个（它知道打了什么补丁），确认没问题再跑通用的那个。

### `niri-portal-cast-tune`
一条命令改档位，不用手编 `config.kdl`：

```
niri-portal-cast-tune                    # 看当前设置
niri-portal-cast-tune menu               # 分开选：① 分辨率 → ② 帧率
niri-portal-cast-tune menu-res|menu-fps  # 只弹分辨率 / 只弹帧率
niri-portal-cast-tune 1080p|2k|2.5k|720p|smooth|balanced|saver|safe
niri-portal-cast-tune fps 30             # 只改帧率
niri-portal-cast-tune size 1920x1080     # 只改分辨率（off = 不限制）
```

档位 = 帧率 / `max-pixels`：`smooth` 60/4096000、`2.5k` 30/4096000、`2k` 30/3686400、`1080p` 30/2073600、`balanced` 30/1024000、`720p` 30/921600、`saver` 15/576000、`safe` 6/576000。

它只改 `screencasting { }` 那一段（其余内容含注释原样保留），三道安全网：新内容先写临时文件并 `niri validate`，通过才**原子替换**（niri 的文件监视器不会看到写了一半的配置）；写完后回查 journal，**正在运行的那个 niri** 若不接受就自动回滚并打印它给的原因；运行中的 niri 比磁盘上的二进制旧（刚升级还没重启）时，自动跳过对方不认识的选项。每次改动都留 `config.kdl.bak-<时间戳>`。

### `niri-shm-attrib` 与刹车
按进程归属 shmem / GEM，回答「涨的是谁的内存」：

```
niri-shm-attrib                        # 2 秒一次，只采样
niri-shm-attrib 0.5 300 --guard 3      # 0.5 秒一次，Shmem 超 3 GiB 自动刹车
```

CSV 里判泄漏看 `*_res`（常驻共享页，来自 `smaps_rollup` 的 `Pss_Shmem`）与 `*_drm`（GPU 侧，`smaps` 里看不到的那部分）；`*_alloc` 可能远大于 `res`，因为 memfd 可以 ftruncate 成很大却一页都没碰过。

**刹车**针对「人工来不及反应」。触发时按固定顺序做三件事：① 把当时的完整进程表（alloc / res / fd / GEM）写进 dump 文件并把 CSV `sync` 落盘（真冻了也能事后复盘）；② `pw-cli destroy` 掉 `Stream/Output/Video` 节点（等价于对面把共享关掉，**不动客户端进程**）；③ 3 秒后若还在涨，才杀 `qq` 进程（`--no-kill` 可关掉这一步）。只有**真的存在采集流**时才动手（没有流时 Shmem 高是别人的账，掐流没意义、杀客户端更是误伤），且上限必须高于当前占用，否则拒绝启动。退出码 2 = 触发过刹车，64 = 上限低于当前占用、没启动。

它**随会话自动启动**：包里带了 `/usr/lib/systemd/user/default.target.wants/niri-shm-attrib.service`
软链，systemd 会自己解析，不需要你跑 `enable`（`.install` 脚本里跑 `systemctl --user` 不可靠 ——
那个上下文没有用户总线）。

- 关掉它：`systemctl --user disable --now niri-shm-attrib`
- 只改阈值：`systemctl --user edit niri-shm-attrib`，改 `ExecStart` 里的 `--guard`（默认 6 GiB）

```
systemctl --user enable --now niri-shm-attrib     # 重启 niri、重新登录都自动带上
systemctl --user edit niri-shm-attrib             # 想更早刹车就改 ExecStart 里的 --guard
```

默认不开是因为「自动掐掉别人正在用的共享」不该替用户决定；但手动挂的那份**跟着会话走**，niri 一重启就会被一起杀掉（SIGTERM），不开服务就得每次重挂。

## 实测与根因
2026-10-03 在本机（Arch + niri Wayland，QQ 通过 portal 共享**整屏** 2560×1600）实测：

- `/proc/meminfo` 的 Shmem 与 **QQ 自己的 `--type=ppapi` 进程**持有的 i915 GEM **1:1 同步上涨**：8 秒内 QQ 的 GEM 从 0.47 GiB 涨到 3.58 GiB，Shmem 同步涨 3.42 GiB。
- **niri 侧全程不动**：GEM 平在 0.59 GiB、fd 数平在 124、memfd 声明量平在 1.077 GiB；portal 也平，它那 6 个 1 GiB 的 Vulkan memfd 常驻始终是 0。
- 速率 398 MB/s ÷ 16.4 MB/帧 = **每秒 24.2 帧被留住**，而帧率上限是 30 fps——即客户端只编码得动约 6 fps，其余全留在它自己的 GPU 缓冲里；**流一停就放掉**。
- 这几次里 niri 一次 `no available buffer in pw stream` 都没报，说明客户端不是占着 niri 的 PipeWire 缓冲，而是每帧复制一份到自己那边。

结论：**上涨的内存属于客户端，不属于 niri**。所以本包能做的是把速率与每帧字节压到客户端消费能力以下——压不到就等于没治。

### 挑档位不用试错：实测「尺寸 → 客户端可编码帧率」

| 采集尺寸 | 每帧 | 客户端实测可编码 | 对应档位 |
|---|---|---|---|
| 2560×1600（默认上限） | 16.4 MB | ~6 fps | `safe` / `saver` |
| 1820×1138（`1080p`） | 8.3 MB | ~14 fps | `fps 10` |
| 1214×758（`720p`） | 3.7 MB | ~22 fps | `fps 20` |
| 960×600（`saver`） | 2.3 MB | ~35 fps（外推） | 30 fps 也稳 |
| 960×600 + 15fps（实测） | 2.3 MB | **~4 fps** | 仍以 ~25 MB/s 增长 |

判据只有一条：**设的上限要低于客户端在该尺寸下能编码的帧率**，差值就是堆积速率。

**但压到最小档也压不到零。** 960×600 + 15fps（每秒产出 15 帧、每帧 2.3 MB）实测仍以
**~25 MB/s** 增长 —— 客户端有一个与画面大小基本无关的固定驻留速率。我们的两个杠杆把最坏
情况从 398 MB/s 压到 25 MB/s（16 倍），剩下的地板在客户端内部，合成器侧没有更多可做的：
长共享会被刹车掐断（不冻机），短共享够用。限帧率只按比例减缓；分辨率降下来客户端每秒能吃的帧数才上去，但不是线性——面积缩到约 1/4.5，帧率能力只涨约 3.7 倍。

压到客户端能力以下，实测就是平的：`frame-rate-hz 6` + 整屏，连续 12 秒 Shmem 1.55 → 1.59 GiB、QQ 的 GEM 平在 0.17 GiB（同条件 30 Hz 时 8 秒涨 3.1 GiB）。刹车也实测有效，触发后 2 秒退干净、进程没死：

```
16:21:07  Shmem 2.36 GiB  流 120
16:21:12  Shmem 2.50 GiB  ← 触发
16:21:14  Shmem 1.21 GiB  流 none
```

## 分工与边界

| 层 | 谁负责 | 内容 |
|---|---|---|
| 合成器 | **本包** | 宣告 shm 格式与 `AvailableSourceTypes`/`AvailableCursorModes`、限帧率、限采集分辨率 |
| 客户端 | [linuxqq-wayland-fix](https://github.com/SHORiN-KiWATA/linuxqq-wayland-fix) | 让 QQ 走 portal 选源、收帧、行跨度、剪贴板、截图 |
| portal / PipeWire | 系统 | 协商格式与缓冲 |

本包保证「niri 愿意把画面交出去、速率与分辨率可控」；**客户端拿到画面之后怎么收，不在本包范围内**。内存异常时按这个顺序处理：① `niri-portal-cast-tune 1080p`（或 `fps 30`），把每帧字节或速率压到客户端吃得下；② 还涨就 `niri-portal-cast-tune safe`，并用 `niri-shm-attrib` 确认是哪个进程在涨；③ 若确认是客户端侧（`qq` / `--type=ppapi`），那属于客户端，本包只能减缓、不能根治。

## 安装
Release 里有编译好的 x86_64 包：https://github.com/ljm-233/niri-portal-cast/releases

```
sudo pacman -U niri-portal-cast-*.pkg.tar.zst
```

会提示替换官方 `niri`（`provides` 和 `conflicts` 都声明了），选 `y`。换回官方版：`sudo pacman -R niri-portal-cast && sudo pacman -S niri`。

## 自己构建

```
git clone https://github.com/ljm-233/niri-portal-cast.git
cd niri-portal-cast
makepkg -si
```

重复构建要留神：补丁 0002 会**新建** `niri-config/src/screencasting.rs`，而 makepkg 复用 `src/` 时 `git reset` 不会清掉这个未跟踪文件，于是第二次 `makepkg -f` 会报 `The next patch would create the file ..., which already exists`。用 `makepkg -C`（cleanbuild）或先 `rm -rf src pkg`。

## 跟随上游新版本
PKGBUILD 锁的是具体 commit（`_upstream`）而非 tag：基线是 main 的 `ed22699d`，比 v26.04 tag 晚 165 个提交，补丁打在 tag 上会有 6 个 hunk 失败。更新步骤：

```
git clone https://github.com/niri-wm/niri.git && cd niri
git checkout <新的基线 commit>
git am /path/to/0001-*.patch          # 有冲突就解决后 git am --continue
git format-patch -1 --stdout > 新的patch文件
```

然后更新 PKGBUILD 里的 `_upstream`、`_patched`、`pkgver`、patch 文件名和 `b2sums`（用 `makepkg -g` 从 `source=()` 生成，不要用 `b2sum -g`），最后 `makepkg --printsrcinfo > .SRCINFO`。

## 已知状态
- 补丁 commit `61dc3de4`，上游基线 `ed22699d`（main，2026-10-01）；**这不是 niri 26.04 正式版**。
- 包版本号是**构建日期 + 当天序号**（形如 `2026.10.3-13`），不反映上游版本：日期版本在 pacman 里严格递增，而语义版本会排在旧的 `26.04.165.g61dc3de4` 后面，每次安装都得 `--allow-downgrade`。
- 上游 PR #1791「Support shm sharing」已合并，但上游版本仍不宣告 `AvailableSourceTypes` / `AvailableCursorModes`，帧率也仍是 `0/1`。
- 包 `provides`/`conflicts` 声明为 `niri` 以替换官方包；`options=(!debug !lto)`。

## 客户端侧泄漏的完整定位

`docs/qq-share-leak.md` 是一份可以直接贴到上游 issue 的说明：现象、可复现的定位方法、
1:1 的数据、四个档位的实测增速、已排除项（niri / portal / PipeWire / THP 那个假参数），
以及给客户端侧的三条排查方向。它同时也解释了为什么「只看 `smaps` 会得出没人在占内存」的错误结论
—— i915 的 GEM 是 shmem 记账但不进任何进程的 smaps。

## 许可证
GPL-3.0-or-later，与 niri 本身一致。
