# niri-shm

niri 加上让 Electron 客户端（QQ、飞书等）能通过 xdg-desktop-portal 屏幕共享的补丁。

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

## 构建

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

基于 niri v26.04（`c4c01f82`）。上游 PR #1791 里有类似的 SHM 改动，
但截至打包时尚未并入 main。

## 许可证

GPL-3.0-or-later，与 niri 本身一致。
