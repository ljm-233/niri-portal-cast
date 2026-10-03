# niri-portal-cast

给 niri 打补丁，让 xdg-desktop-portal 的屏幕采集在它上面真正能用。

没有这个补丁时，niri 下的屏幕共享对 Electron 客户端（QQ、飞书等）**完全不可用**——
连整屏都共享不出来，不是画面黑，是根本没有画面。

## 为什么上游不行

三个互相独立的原因，缺一不可：

**一、niri 不宣告 shm 格式。** Electron 不导入 DMA-BUF，只认 shm。niri 在
`org.gnome.Mutter.ScreenCast` 上没有暴露 shm 格式，那些不带 `VideoModifier` 的
格式会被当成普通线性 dmabuf，被 PipeWire 以 "no more input formats" 拒绝。

**二、niri 不宣告能力位。** `AvailableSourceTypes` 和 `AvailableCursorModes`
没有实现，`xdg-desktop-portal-gnome` 因此读到零能力，**拒绝所有 `SelectSources`
调用**。表现是选择窗口时只有「整个屏幕」可选。

**三、帧率不限速。** `VideoFramerate` 宣告为 `0/1` 就是「不限速」，PipeWire 按
输出刷新率推帧，软件 H.264 编码器来不及消费，剩余裸帧在 shm 里堆积。一开共享
内存就往上涨，几秒内涨到几个 GiB，桌面卡死。

**这个包不修内存泄漏。** 它限帧率，治的是「帧产生速度超过消费速度」导致的堆积，
不是任何意义上的泄漏。包里没有一行释放或回收代码。

## 装什么版本

| 版本 | 说明 |
|---|---|
`niri-portal-cast` | 本包。见下。 |
AUR `niri-shm-sharing` | 只改 `src/screencasting/pw_utils.rs`。宣告能力缺失（原因二没修），帧率仍不限速。 |

简单说：`niri-shm-sharing` 只做到「能整屏共享」，本包能做到「能选单个窗口」并且
共享期间内存不涨。

实测（Arch Linux，niri Wayland 会话，QQ 通过 portal 共享单个窗口）：

- 只装 `niri-shm-sharing`：选择窗口里无法选单个窗口，只能共享整屏
- 装本包：窗口可选，pipewire 协商到 `60/1`，跑 5 分半 Shmem 在 0.8-1.5 GiB 之间
  波动，无单向爬升

> **2026-10-03 复验：上面这组数字在当时的 `-7` 构建上没有复现，结论按未确认处理。**
> 同一天重启后实测：共享开始 30 秒内 Shmem 从 1.2 GiB 涨到 11.5 GiB，共享结束立刻
> 回落到 0.4 GiB，帧率上限没能把它压住。
>
> **已经排除的原因：不是基线漂移。** `-7` 的 rebase（`1f03391e` → `ed22699d`）只带来
> 5 个上游提交，全部在 `tty`/gamma 和一个 GitHub 模板里，`src/screencasting/` 与
> `src/render_helpers/` 一个字节都没动；那批 `pw_utils` 的 SHM 生命周期改动
> （`6b02f427`、`6e6e829c` 等）在旧基线里就已经存在。所以「上游 SHM 重构引入泄漏」
> 不成立，别照这个方向查。
>
> 还没排除的差异：**旧那组数字是共享单个窗口，这次泄漏是整屏（`record_monitor`
> eDP-1，2560×1600）**；以及 0003 删掉的那个池子上限（实测它的驱逐循环从未触发过，
> 所以理论上不该有影响）。机制仍未确认，不在确认前动补丁。

限帧的效果可以在 journal 里直接对比。同一天两次共享，同一台机器：

```
# 没有限帧（旧构建）
framerate: spa_fraction { num: 0, denom: 1 }              # 不限速
max_framerate: spa_fraction { num: 240000, denom: 1000 } # 240 Hz

# 有本包
framerate: spa_fraction { num: 60, denom: 1 }
max_framerate: spa_fraction { num: 60, denom: 1 }
```

不限速那次系统可用内存从 12 GB 掉到 1 GB 以内，机器卡到没法操作，niri 进程本身
没有崩溃（journal 里 0 次 OOM）；限帧后跑几分钟 Shmem 稳定在 1.1-1.2 GiB 零漂移。

**两个数字都要看**，`framerate` 和 `max_framerate` 一起降下来才是真的限住了，
只降一个不管用。

## 配置

```kdl
screencasting {
    frame-rate-hz 60
}
```

范围 5-120，默认 60。超出范围的值会被静默钳位到边界，不报错。

### 下限为什么是 5 而不是 30

2026-10-03 用本仓库的 `niri-shm-attrib.sh` 实测（整屏 2560×1600，QQ 共享）：

- 共享 8 秒内，QQ 的 `--type=ppapi` 进程持有的 i915 GEM 从 0.47 GiB 涨到 3.58 GiB，
  同期 `/proc/meminfo` 的 Shmem 涨 3.42 GiB —— **一一对应**；
- niri 侧完全不动：GEM 平在 0.59 GiB、fd 数平在 124、memfd 声明量平在 1.077 GiB；
  portal 也平，它那 6 个 1 GiB 的 Vulkan memfd 常驻始终是 0；
- 增长速率 398 MB/s ÷ 16.4 MB/帧 = **每秒 24.2 帧被留住**，而帧率上限是 30 fps，
  即客户端只编码得动约 6 fps，其余全留在它自己的 GPU 缓冲里（流一停就放掉）。

`niri` 在这几次里一次 `no available buffer in pw stream` 都没报，说明客户端并不是
占着 niri 的 PipeWire 缓冲，而是每帧复制一份到自己那边。所以限帧率只能**按比例
减慢**堆积：压不到客户端消费能力以下就等于没治。30 的下限让 `frame-rate-hz 10`
根本写不进去，因此降到 5。

### 实测验证（2026-10-03 15:11）

装上 `-9` 并把 `frame-rate-hz` 设为 6 之后，整屏共享连续 12 秒：

```
时刻       Shmem    QQ 最大 GEM   niri GEM   协商帧率
15:11:52   1.55 GiB   0.17 GiB     0.45 GiB      6
15:12:04   1.59 GiB   0.17 GiB     0.47 GiB      6
```

两边都不再增长。同一条件下 30 Hz 时是 8 秒 +3.1 GiB（约 400 MB/s），12 秒本该
再涨近 5 GiB。`niri-portal-doctor` 的【四】同时报「帧率 6 Hz 已生效（最近一次
实际协商也是 6 Hz）」——那条检查存在的意义就是不再出现「以为限了、其实没生效」。

代价说清楚：远端拿到的就是 6 fps。但在 30 Hz 下它本来也只编码得动约 6 fps，多
出来的帧只是把延迟越堆越长、把内存堆到卡死。所以这里的取舍是「同样的画面帧率，
换掉堆积」。想要更流畅只有两条路：共享单个窗口（每帧小 5-10 倍，客户端吃得下），
或者给补丁加采集分辨率缩放。

### 采集分辨率可以压（patch 0004）

```kdl
screencasting {
    frame-rate-hz 30
    max-pixels 1024000    // 1280×800；960×600 用 576000，默认 4096000 = 2560×1600
}
```

宣告出去的尺寸会按这个像素上限等比缩小，渲染结果再缩放到该尺寸后才交给客户端。
每帧字节按面积下降，客户端编码器就追得上，于是既能保住 30 fps 又不再堆积——这比把
帧率压到 6 更接近「正解」，代价是画面分辨率低。

**这里同时修掉一个真 bug。** 上限机制（`cap_capture_size`）从 0001 就在，但它只缩小
了**宣告**的尺寸：damage tracker 是按输出尺寸建的，`render_to_shmbuf` 也按输出尺寸
校验缓冲。任何超过 2560×1600 的输出（比如 4K 屏）一旦触发上限，每帧都会
`invalid buffer size` —— 一个画面都出不来。作者自己的屏正好是 2560×1600，所以从没
触发过。现在渲染侧会真的缩放（`Renderer::blit` 带 filter、保留 SyncPoint），光标
元数据同步缩放。

**另外：限制值是每次开始共享时读的**，不再是 niri 启动时读一次。所以改完
`frame-rate-hz` / `max-pixels` **重开一次共享即可生效，不用重启 niri**。

不写这个块就用默认 60。

**配置在 niri 启动时读取**，改完要重启 niri 才生效，共享中改无效。补丁是在
`PipeWire::new()` 里一次性取走这个值的，而 PipeWire 在 niri 启动时构造，所以
`niri msg action load-config-file` 也改不动它——它只重载界面相关的配置。判断
「到底生效了没有」不要看配置文件，看 journal：

```
journalctl --user -u niri.service --since '-30min' | grep 'framerate: spa_fraction'
```

那里的 `num` 才是 PipeWire 真正拿到的帧率。

**不要写 `max-shm-buffers`。** 补丁 0003 已经把它删掉了，理由见该补丁的提交信息
（它防的是一个不存在的机制：buffer 数由 PipeWire 协商，niri 只按
`StreamFlags::ALLOC_BUFFERS` 分配）。niri 的配置解析拒绝未知节点，写了这个键
**niri 会直接拒绝启动**，journal 里只有一行：

```
× unexpected node `max-shm-buffers`
```

`niri-portal-doctor` 的【四】会同时报出配置值和最近一次实际协商值，能确认合成器
启动时刻时，两者不一致按故障处理；拿不到启动时刻时只提醒，不做断言。

## 排查脚本

包会装一个 `niri-portal-doctor`。共享不出画面时先跑它：

```
niri-portal-doctor
```

它只读状态，不重启任何东西，通话中跑也安全。逐项检查会话环境、二进制是否带补丁、
门户后端、帧率配置**是否真的生效**（范围 5-120）、niri 是否收到采集请求、Shmem 占用与 shmem 大页
策略，以及音频图，并指出第一个断掉的地方。

【四】不看「配置文件里写了什么」就报正常：它拿配置值和 journal 里最近一次实际协商
到的 `framerate: spa_fraction` 对比，并用合成器启动时刻判断配置是不是启动之后才改的。
配置没生效、且有 journal 佐证时报故障——那正是「限了帧但内存照涨」的典型原因；只有
文件时间戳可疑时降级成提醒，因为 mtime 分不出改的是哪一行。

【六】顺带核对 shmem 大页策略：内核可能把 `transparent_hugepage=shmem:xxx` 这种写法
整个丢掉（dmesg 里是 `transparent_hugepage= cannot parse, ignored`），命令行里写了
不等于生效，所以它比对 sysfs 的实际值与命令行声明，不一致就报注意。

退出码 0 表示没有阻塞性问题，1 表示有。

要按进程归属查「是谁在占 shmem」用仓库里的 `niri-shm-attrib.sh`（只读采样，见该
脚本头部说明）。

还有一个通用的
[`wayland-cast-doctor`](https://github.com/ljm-233/wayland-cast-doctor)，
不绑定任何合成器，Hyprland / Sway / GNOME / KDE 都能跑。两个不冲突，排查顺序建议
先跑 `niri-portal-doctor`——它知道本包打了什么补丁，能顺带确认 `/usr/bin/niri` 确实
来自这里；确认没问题再跑通用的那个。

输出示例：

```
【五】采集状态
  故障  有 3 次采集请求，但 0 次格式协商
       客户端要了屏幕，然后在告诉 niri 它想要什么格式之前就放弃了。
       常见原因是选择框被关掉，或者协商途中 PipeWire 出了事件（音频
       设备切换、蓝牙连上）把整个图拆了。
       解法：只留一个音频输出，然后重新共享。
```

### 第七项值得单独说

**有线和蓝牙音频输出同时在线**时，WirePlumber 会在两者之间切换默认设备，PipeWire
重建整个图，客户端手里握的句柄全部失效。表现是选择框弹出来、点共享、然后崩掉或者
300 毫秒内退出，niri 日志里只有 `Paused -> Unconnected`，没有格式协商记录。

解法：拔掉其中一个，只留一种输出。

### 共享成功时也要看一眼帧率

第五项在成功时不止报次数，还会报**实际协商到的帧率**。这个数字直接反映本包的
`frame-rate-hz` 有没有生效——正常是配置值（默认 60）。

看到 `0/1`（不限速）说明这个补丁没在生效：配置只在 niri 启动时读一次，改完
`config.kdl` 没重启是不算的。确认办法是跑第二项，它会报当前二进制来自哪个包、
commit 是多少。

## 安装现成的包

Release 里有编译好的 x86_64 包：

https://github.com/ljm-233/niri-portal-cast/releases

```
sudo pacman -U niri-portal-cast-*.pkg.tar.zst
```

会提示替换官方 `niri`（本包 `provides` 和 `conflicts` 都声明了），选 `y`。

换回官方版：

```
sudo pacman -R niri-portal-cast
sudo pacman -S niri
```

## 自己构建

```
git clone https://github.com/ljm-233/niri-portal-cast.git
cd niri-portal-cast
makepkg -si
```

重复构建要留神：补丁 0002 会**新建** `niri-config/src/screencasting.rs`，而 makepkg
复用 `src/` 时 `git reset` 不会清掉这个未跟踪文件，于是第二次 `makepkg -f` 会报
`The next patch would create the file ..., which already exists`。用 `makepkg -C`
（cleanbuild）或先 `rm -rf src pkg` 就行。

## 跟随上游新版本

PKGBUILD 锁的是具体 commit 而非 tag，原因是 v26.04 tag 上打补丁会有 6 个 hunk
失败（上游在 tag 之后重构了 SHM 映射的生命周期管理）。

更新步骤：

```
git clone https://github.com/niri-wm/niri.git
cd niri
git checkout <新的基线 commit>
git am /path/to/0001-*.patch
# 有冲突就解决后 git am --continue
git format-patch -1 --stdout > 新的patch文件
```

然后更新 PKGBUILD 里的 `_upstream`、`_patched`、`pkgver`、patch 文件名和 `b2sums`
（用 `makepkg -g` 从 `source=()` 生成，不要用 `b2sum -g`），最后
`makepkg --printsrcinfo > .SRCINFO`。

## 已知状态

补丁 commit `61dc3de4`，上游基线 `ed22699d`（main，2026-10-01）。

**这不是 niri 26.04 正式版。** v26.04 tag 打于 2026-04-25，基线比它晚 165 个提交，
这 165 个里包含 `pw_utils: retain SHM mappings for buffer lifetime` 等对 SHM 处理的
重构。所以补丁只能打在具体 commit 上，打 tag 会失败 6 个 hunk。

包的版本号是**构建日期加当天序号**（如 `2026.10.3-7`），不反映上游版本。原因是
日期版本在 pacman 里严格递增，而 `26.0.7` 这类语义版本会排在之前的
`26.04.165.g61dc3de4` 后面，每次安装都得加 `--allow-downgrade`。

上游 PR #1791「Support shm sharing」已于 2026-09-12 合并。本包在此之上补了两点：
上游合并的版本仍然不宣告 `AvailableSourceTypes` / `AvailableCursorModes`，帧率也仍是
`0/1`。

## 改档位不用手编配置

包里带一个 `niri-portal-cast-tune`：

```
niri-portal-cast-tune              # 看当前设置
niri-portal-cast-tune menu         # 分开选：① 分辨率 → ② 帧率
niri-portal-cast-tune menu-res     # 只弹分辨率
niri-portal-cast-tune menu-fps     # 只弹帧率
niri-portal-cast-tune 1080p|2k|2.5k|720p|smooth|balanced|saver|safe
niri-portal-cast-tune fps 30       # 只改帧率
niri-portal-cast-tune size 1920x1080   # 只改分辨率（off = 不限制）
```

它只改 `config.kdl` 里 `screencasting { }` 那一段，三道安全网：新内容先写临时文件并
`niri validate`，通过才**原子替换**（niri 的文件监视器不会看到写了一半的配置）；写完后
回查 journal，**正在运行的那个 niri** 若不接受就自动回滚；如果运行中的 niri 比磁盘上的
二进制旧（刚升级还没重启），它会自动跳过对方不认识的选项，只改认识的。每次改动都留
`config.kdl.bak-<时间戳>`。

限制值是**每次开始共享时读**的，所以改完重开一次共享就生效，不用重启 niri。

## 和客户端侧修复的分工

桌面共享这条链路是两半，缺一不可：

| 层 | 谁负责 | 内容 |
|---|---|---|
| 合成器 | **本包** | 宣告 shm 格式与 `AvailableSourceTypes`/`AvailableCursorModes`（Electron 不认 DMA-BUF，只有 shm 这条路）、限帧率、限采集分辨率 |
| 客户端 | [linuxqq-wayland-fix](https://github.com/SHORiN-KiWATA/linuxqq-wayland-fix) | 让 QQ 走 portal 选源、收帧、行跨度、剪贴板、截图 |
| portal / PipeWire | 系统 | 协商格式与缓冲 |

本包保证「niri 愿意把画面交出去、并且速率可控」；**QQ 拿到画面之后怎么收，不在本包范围内**。
2026-10-03 实测：共享期间上涨的内存是 **QQ 自己的 `--type=ppapi` 进程**持有的 i915 GEM
（30fps 下每秒约 24 帧被留住，与 `/proc/meminfo` 的 Shmem 1:1 同步），niri 侧全程不动。

所以内存异常时的处理顺序是：

1. `niri-portal-cast-tune 1080p`（或 `fps 30`）—— 把每帧字节或速率压到客户端吃得下；
2. 还涨就跑 `niri-portal-cast-tune safe`，再用仓库里的 `niri-shm-attrib.sh` 确认是哪个进程在涨；
3. 若确认是客户端侧（`qq` / `--type=ppapi`），那属于客户端，本包只能减缓、不能根治。

## 许可证

GPL-3.0-or-later，与 niri 本身一致。
