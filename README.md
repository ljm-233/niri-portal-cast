# niri-shm

niri 加上让 Electron 客户端（QQ、飞书等）能通过 xdg-desktop-portal 屏幕共享的补丁。

AUR 上有一个功能部分重叠的 `niri-shm-sharing`，区别见下方说明。

## 为什么需要这个补丁

没有这个补丁时，niri 下的屏幕共享对 Electron 客户端完全不可用：

1. Electron 不会导入 DMA-BUF，所以 niri 必须显式提供 shm 格式。不带 `VideoModifier`
   的格式会被当成普通线性 dmabuf，被 pipewire 以 "no more input formats" 拒绝。
2. niri 没有在 `org.gnome.Mutter.ScreenCast` 上暴露 `AvailableSourceTypes` 和
   `AvailableCursorModes`，`xdg-desktop-portal-gnome` 因此报告零能力，拒绝所有
   `SelectSources` 调用。

补丁还限制了采集帧率。`VideoFramerate` 为 0/1 时 pipewire 理解为「不限速」，会按输出
刷新率推帧，软件 H.264 编码器来不及消费，剩余的裸帧会堆积。

## 内容

三个 patch：

- `0001-` — 新增 `available_source_types` 与 `available_cursor_modes` 属性，
  恢复上游的 dmabuf/shm 分裂路径，限制采集帧率
- `0002-` — 把帧率改为 `config.kdl` 里的 `screencasting { frame-rate-hz }`
  配置项，范围 30-120，默认 60
- `0003-` — 移除 shm buffer 池上限（见下方「关于 buffer 池」）

## 配置

```kdl
screencasting {
    frame-rate-hz 60
}
```

不写这个块就用默认 60。超出 30-120 范围的值会被静默钳位到边界，不报错。

配置在 niri 启动时读取，改完要重开共享才生效。

实测（Arch Linux，niri Wayland 会话，QQ 通过 portal 共享单个窗口，2560x1600）：
pipewire 协商到 60/1，运行 5 分半，Shmem 在 0.8-1.5 GiB 之间波动无单向爬升。

## 关于 buffer 池

本包**不限制** shm buffer 池数量。早期的版本有一个 `max-shm-buffers`
配置项和对应的驱逐逻辑，现已移除。

原因是那个逻辑防的是不存在的机制。pipewire 通过 `StreamFlags::ALLOC_BUFFERS`
协商 buffer 数量，niri 只分配被要求的那些，池子不会无限增长。上游维护者也指出了
这一点（niri-wm/niri#4655）。实测印证：在 60 Hz 下共享 5 分半，驱逐逻辑一次都
没有触发过。

## 安装现成的包

Release 里有编译好的包：

https://github.com/ljm-233/niri-shm/releases

```
sudo pacman -U niri-shm-git-*.pkg.tar.zst
```

## 自己构建

```
makepkg -si
```

装好后会提示替换官方 `niri`（本包 `provides` 和 `conflicts` 都声明了 `niri`），
选 `y`。

## 跟随上游新版本

```
git clone https://github.com/niri-wm/niri.git
cd niri
git am /path/to/0001-*.patch
# 有冲突就解决后 git am --continue
git format-patch -1 --stdout > 新的patch文件
```

然后更新 `PKGBUILD` 里的 `_version`、`_patched`，以及 patch 文件名和
`b2sums`（`b2sum -g *.patch`）。

## 已知状态

补丁 commit `c4c01f82`，上游基线 `1f03391e`（main，2026-09-25）。

注意这不是 niri 26.04 正式版：v26.04 tag 打于 2026-04-25，基线比它晚161 个
提交。这161 个里包含 `pw_utils: retain SHM mappings for buffer lifetime`、
`pw_utils: borrow SHM buffers when rendering and clearing` 等对 SHM 处理的
重构。把这个补丁打到 v26.04 tag 上会有 6 个 hunk 应用失败，所以 PKGBUILD
锁的是具体 commit 而非 tag。

上游 PR #1791「Support shm sharing」已于 2026-09-12 合并。本包在此之上补了两点：
上游合并的版本仍然不宣告 `AvailableSourceTypes` / `AvailableCursorModes`，帧率也仍是
`0/1`（不限速）。

## 与 niri-shm-sharing 的区别

AUR 上的 `niri-shm-sharing`（维护者 onez3r0，补丁来自 `rucnyz/niri`）同样给 niri
打 SHM 补丁，只改 `src/screencasting/pw_utils.rs` 一个文件。区别在于：

- **它不宣告 `AvailableSourceTypes` 和 `AvailableCursorModes`**。这两个属性定义在
  `src/dbus/mutter_screen_cast.rs`，它的补丁没碰那个文件。缺了它们，
  `xdg-desktop-portal-gnome` 会向 niri 读到零能力，拒绝所有 `SelectSources` 调用，
  表现为选择窗口时只有「整个屏幕」可选。
- **它的 `VideoFramerate` 宣告为 `{num: 0, denom: 1}`**，也就是不限速。pipewire 会按
  输出刷新率推帧，而 Electron 端的软件 H.264 编码器来不及消费，剩余裸帧持续堆积。
  本包通过 `screencasting { frame-rate-hz }` 给采集侧一个可配置的上限。
- **它的 `pkgver` 写作 `26.04`**，实际 pin 在 commit `8ed0da44`；本包写作
  `26.04.161.gc4c01f82`，如实反映基线比v26.04 tag 晚161 个提交。

实测（Arch Linux，niri Wayland 会话，QQ 通过 portal 共享）：

- 只装 `niri-shm-sharing` 时，选择窗口里无法选单个窗口，只能共享整屏。
- 换成本包后选择窗口可用，共享期间内存稳定（QQ 13 进程 RSS 合计约 2.6 GB），
  不再出现共享一开始就爆内存卡死。

如果你要的只是「能整屏共享」，两个包都可以；如果需要选单个窗口，或者内存一开共享
就往上涨，换成这个。

## 许可证

GPL-3.0-or-later，与 niri 本身一致。
