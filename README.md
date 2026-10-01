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

改动两个文件，共 222 行：

- `src/dbus/mutter_screen_cast.rs` — 新增 `available_source_types` 与
  `available_cursor_modes` 属性
- `src/screencasting/pw_utils.rs` — 恢复上游的 dmabuf/shm 分裂路径，固定 30fps，
  并把 shm buffer 池限制在 32 个以内

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

上游 PR #1791 里有类似的 SHM 改动，但截至打包时尚未并入 main。

## 与 niri-shm-sharing 的区别

AUR 上的 `niri-shm-sharing` 同样给 niri 打SHM 补丁，区别在于：

- 它只处理了 shmem fallback，没有宣告 `AvailableSourceTypes` 和
  `AvailableCursorModes`。缺了这两项，`xdg-desktop-portal-gnome` 会报告零能力
  并拒绝所有 `SelectSources` 调用，表现为选择框里只有「整个屏幕」。
- 它没有采集帧率上限。
- 它 pin 在 `8ed0da44`，比这里的基线旧。

## 许可证

GPL-3.0-or-later，与 niri 本身一致。
