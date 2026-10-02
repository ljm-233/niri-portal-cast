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

## 配置

```kdl
screencasting {
    frame-rate-hz 60
}
```

范围 30-120，默认 60。超出范围的值会被静默钳位到边界，不报错。

不写这个块就用默认 60。

**配置在 niri 启动时读取**，改完要重启 niri 才生效，共享中改无效。

## 排查脚本

包会装一个 `niri-portal-doctor`。共享不出画面时先跑它：

```
niri-portal-doctor
```

它只读状态，不重启任何东西，通话中跑也安全。逐项检查会话环境、二进制是否带补丁、
门户后端、帧率配置、niri 是否收到采集请求、Shmem 占用，以及音频图，并指出第一个
断掉的地方。

退出码 0 表示没有阻塞性问题，1 表示有。

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

补丁 commit `c4c01f82`，上游基线 `1f03391e`（main，2026-09-25）。

**这不是 niri 26.04 正式版。** v26.04 tag 打于 2026-04-25，基线比它晚 161 个提交，
这 161 个里包含 `pw_utils: retain SHM mappings for buffer lifetime` 等对 SHM 处理的
重构。所以 `pkgver` 写作 `26.04.161.gc4c01f82`，如实反映这一点。

上游 PR #1791「Support shm sharing」已于 2026-09-12 合并。本包在此之上补了两点：
上游合并的版本仍然不宣告 `AvailableSourceTypes` / `AvailableCursorModes`，帧率也仍是
`0/1`。

## 许可证

GPL-3.0-or-later，与 niri 本身一致。
