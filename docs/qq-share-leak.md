# QQ 屏幕共享内存暴涨：结论与验证

环境：Arch + niri（`niri-portal-cast` 补丁）+ `linuxqq-wayland-fix` 0.2.8-1 + QQ 3.2.34-53644，整屏 2560×1600。

## 结论

1. **不是 `linuxqq-wayland-fix`。** 通读 `src/qq-wl-portal.c`（v0.2.9，859 行）：全库不碰 GPU/DRM/EGL/dma-buf
   （`egl|gl*|gbm|drm|memfd_create|mmap|dma_buf|wl_shm|va_` 检索为空）。每帧路径 `wrap_dequeue`（`:590-642`）
   只做一次 CPU `memcpy` 到复用缓冲（`:628`），**每帧零分配**。三处分配都有对应 free：`calloc` 56 B/流
   （`:554` → `:586` free）、`malloc` 16 B/次 pulse 查询（`:827`/`:850` → `:798`/`:813` free）、
   `realloc` 仅在 `packed_size < need` 时发生（`:614`，条件 `:613`，`need = row*height`，`:605`/`:612`）。
2. **那 16.4 MB 也不是它。** `:614` 那块尺寸恰好等于实测的每帧 16.4 MB，但它是 glibc 的大块 `malloc`
   （匿名 mmap，记 `AnonPages`）—— **既不是 `Shmem`，也不是 i915 GEM**，而且只分配一次、之后复用、
   流销毁时 free。
3. **是 QQ 自带的 `avsdk/broadcast-core.so` 的 GL PBO 路径。** 上游自己在 `:475-483` 的注释里记了它的写法：
   `memcpy(pbo, datas[0].data, width*height*4)`（pbo = GL pixel buffer object）。该二进制导入 65 个 `gl*`
   符号：`glGenBuffers`/`glBufferData`/`glMapBuffer`/`glUnmapBuffer`/`glDeleteBuffers`、
   `glGenTextures`/`glTexImage2D`/`glTexSubImage2D`/`glDeleteTextures`/`glReadPixels`，以及
   `eglCreateImageKHR`/`eglDestroyImageKHR`/`glEGLImageTargetTexture2DOES`。
4. **逐条对上实测**：GL buffer/texture 就是 i915 GEM，且以 **GL name** 引用而不是 fd —— 所以
   `/proc/PID/fd` 里 `/dmabuf:` 恒为 0、`smaps` 里看不到，只有 `/proc/PID/fdinfo/*` 的 `drm-total-system0` 在涨；
   2560×1600 RGBA = 16,384,000 B = 每帧 16.4 MB；每秒 24 帧不释放 = 398 MB/s。

## 一条命令验证

`docs/glprobe.c`（本仓库内，`LD_PRELOAD` 计数 GL 调用，每行输出 `[glprobe] <微秒> <函数> <字节>`）：

```bash
gcc -shared -fPIC -o /tmp/glprobe.so docs/glprobe.c -ldl   # 需要 gcc 与 libdl

# 完全退出 QQ 后，用它启动：
LD_PRELOAD=/tmp/glprobe.so linuxqq-wayland-fix 2>/tmp/gl.log

# 开一次共享，跑 20 秒左右，然后：
grep -c glGenBuffers   /tmp/gl.log
grep -c glDeleteBuffers /tmp/gl.log
awk '/glBufferData/{s+=$NF} END{print s/1048576" MB"}' /tmp/gl.log
```

**判据**：`glBufferData` 累计 ≈ 20 s × 398 MB/s ≈ **8 GB**，而 `glDeleteBuffers` 远少于 `glGenBuffers`
→ 直接指到 broadcast-core 的 PBO 路径。

## 实测数据

| 档位（采集尺寸 / 帧率） | 每帧 | 客户端 `qq --type=ppapi` 的 GEM 增速 |
|---|---|---|
| 2560×1600 / 30 | 16.4 MB | **398 MB/s**（≈ 每秒 24 帧被留住） |
| 1820×1138 / 30 | 8.3 MB | 135 MB/s |
| 1214×758 / 30 | 3.7 MB | 29 MB/s |
| 960×600 / 15 | 2.3 MB | **25 MB/s**（与帧大小基本无关的地板） |

- `Shmem`（`/proc/meminfo`）与该进程的 GEM **一比一同步增长**：9 秒 1.234 → 4.654 GiB（GEM 0.051 → 3.575 GiB）
- 同期 niri 与 portal **完全不动**（GEM、fd 数、memfd 声明量全平），也没有出现一次
  `no available buffer in pw stream`
- 掐掉采集流后 3 秒内回落（4.65 → 1.20 GiB），**进程没有退出**

## 一个会把人带偏的坑

i915 的 GEM 是 shmem 记账的，但**不进任何进程的 `smaps`**：本机 `Shmem` 总量 1484 MiB，
而所有进程 `Pss_Shmem` 之和只有 268 MiB。只看 `smaps` 会得出「没有人在占内存」的错误结论。

## 不确定项

- 静态上**无法证明**「每帧 `glGenBuffers` 而从不 `glDeleteBuffers`」：该二进制里 `glDeleteBuffers`
  有 9 处引用、`glGenBuffers` 有 7 处，从引用数判断不了 —— 所以上面那个实验是必须跑的。
- 「GNOME 走 dmabuf 所以不复现」是**未经实验证实的推测**，我们没有做过 GNOME / dmabuf 的对照。

## 下一步

查 `broadcast-core.so` 里 PBO 与纹理的生命周期：每帧是否 `glGenBuffers` / `glTexImage2D` /
`eglCreateImageKHR`，而对应的 `glDeleteBuffers` / `glDeleteTextures` / `eglDestroyImageKHR` 从未调用
（或只在尺寸变化时调用一次）。
