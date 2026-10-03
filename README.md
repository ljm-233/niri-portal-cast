# niri-portal-cast

给 niri 打补丁，让 QQ、飞书等 Electron 客户端的屏幕共享能用。没有它时，niri 上共享给这些客户端根本没有画面。

补丁做三件事：宣告 shm 格式、补门户能力位、限制帧率与采集分辨率。三个工具随包安装。

## 装

Release 里有编译好的包：<https://github.com/ljm-233/niri-portal-cast/releases>

```
sudo pacman -U niri-portal-cast-*.pkg.tar.zst     # 提示替换官方 niri，选 y
```

自己构建：clone 后 `makepkg -si`；重复构建要先 `rm -rf src pkg`（补丁会新建文件）。换回官方版：`sudo pacman -R niri-portal-cast && sudo pacman -S niri`。

## 用

```
niri-portal-cast-tune              # 看/改档位（帧率与分辨率上限）
niri-portal-cast-tune menu         # 弹菜单分开选：① 分辨率 ② 帧率
niri-portal-cast-tune brake off|on      # 关 / 开内存刹车（包内默认为随会话自启）
niri-portal-doctor                 # 共享不出画面时先跑它；退出码 0 = 正常，1 = 有问题
niri-shm-attrib                    # 看内存涨在哪个进程；随会话自启，超阈值自动掐流
```

改完档位**重开一次共享就生效，不用重启 niri**（限制值是每次开始共享时读的）。

## 内存暴涨怎么办

1. 先降档：`niri-portal-cast-tune 1080p`，或只降帧率 `niri-portal-cast-tune fps 30`
2. 还涨就 `niri-portal-cast-tune safe`（6fps + 960×600，最保守）
3. 想知道涨的是谁：`niri-shm-attrib` 输出 CSV，看 `*_res` 与 `*_drm` 两列

涨的通常是客户端自己留的（QQ 的 `--type=ppapi` 进程），本包只压速率与每帧字节，不修客户端的泄漏。刹车超过阈值会掐掉采集流（等于关掉共享，不杀进程）；不想要它：`systemctl --user disable --now niri-shm-attrib`。

选档位看这张实测表，判据是**上限要低于客户端在该尺寸下能编码的帧率**，差值就是堆积速率：

| 采集尺寸 | 每帧 | 客户端实测可编码 | 建议档位 |
|---|---|---|---|
| 2560×1600（默认） | 16.4 MB | ~6 fps | `safe`、`saver` |
| 1820×1138（`1080p`） | 8.3 MB | ~14 fps | `fps 10` |
| 1214×758（`720p`） | 3.7 MB | ~22 fps | `fps 20` |
| 960×600（`saver`） | 2.3 MB | 仍有约 25 MB/s 堆积 | 长共享会被刹车掐断 |

## 配置

```kdl
screencasting {
    frame-rate-hz 60      // 帧率上限，5-120，默认 60，超范围静默钳位
    max-pixels 4096000    // 采集分辨率上限（像素数），默认 4096000 = 2560×1600
}
```

不写就用默认值。`max-pixels` 是每帧字节的旋钮：宣告尺寸按它等比缩小，渲染结果缩放到该尺寸后才交给客户端。档位名：`smooth 2.5k 2k 1080p balanced 720p saver safe`，只改一项用 `niri-portal-cast-tune fps 30` 或 `size 1920x1080`（`off` = 不限制）。

## 已知限制

- niri 不宣告 DMA-BUF 导出，客户端只能走 SHM 拷贝，每帧整帧传一次。
- 稳定与否取决于客户端编码得动多少帧；压不到它能力以下就会堆积。
- **不要写 `max-shm-buffers`**：补丁已删掉这个选项，写了 niri 会直接拒绝启动。
- `transparent_hugepage=shmem:never` 这类内核命令行写法无效，内核会忽略它，实际策略仍是 `advise`。
- PKGBUILD 锁的是上游 commit `ed22699d`，不要换成 tag（补丁打在 tag 上有 6 个 hunk 失败）。

## 详细报告

根因、实测数据、给上游的说明：`docs/qq-share-leak.md`（包内也装一份在 `/usr/share/doc/niri-portal-cast/`）。

## 许可证

GPL-3.0-or-later，与 niri 本身一致。
