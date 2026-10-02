#!/usr/bin/env bash
# niri-shm-doctor -- 诊断 portal 屏幕共享不出画面的原因。
#
# Electron 客户端（QQ、飞书等）发起 portal 屏幕共享，选择框弹出，点「分享」，然后
# 两种情况之一发生：
#
#   - 画面一直转圈，什么都不来
#   - 选择框根本不弹
#
# 两者从外面看一模一样，但根因完全不同。本脚本逐项打印整条链路的状态，指出第一个
# 断掉的地方。它只读状态，从不重启任何东西，所以通话中跑也安全。
#
# 退出码 0 表示没有阻塞性问题，1 表示有。

set -uo pipefail

if [ -t 1 ]; then
	R=$'\033[31m' G=$'\033[32m' Y=$'\033[33m' B=$'\033[0m'
else
	R="" G="" Y="" B=""
fi

problems=0
notes=()

ok()    { printf '  %s正常%s  %s\n' "$G" "$B" "$1"; }
info()  { printf '  %s提示%s  %s\n' "$B" "$B" "$1"; }
warn()  { printf '  %s注意%s  %s\n' "$Y" "$B" "$1"; notes+=("$1"); }
bad()   { printf '  %s故障%s  %s\n' "$R" "$B" "$1"; problems=$((problems + 1)); }
head_() { printf '\n%s\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

confdir="${XDG_CONFIG_HOME:-$HOME/.config}"

# ---------------------------------------------------------------------------
head_ "【一】会话环境"

if [ "${XDG_SESSION_TYPE:-}" != "wayland" ]; then
	bad "当前不是 Wayland 会话（XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-未设置}）"
	printf '       niri 只能在 Wayland 下运行。\n'
else
	ok "Wayland 会话（${XDG_CURRENT_DESKTOP:-未知}）"
fi

if [ "${XDG_CURRENT_DESKTOP:-}" = "niri" ]; then
	ok "合成器是 niri"
else
	warn "合成器是 ${XDG_CURRENT_DESKTOP:-未知}，不是 niri"
	printf '       本包的 shm 补丁只对 niri 有效。\n'
fi

# ---------------------------------------------------------------------------
head_ "【二】二进制是否带补丁"

if ! have niri; then
	bad "PATH 里找不到 niri"
elif strings /usr/bin/niri 2>/dev/null | grep -q 'frame_rate_hz'; then
	ok "二进制带有屏幕共享补丁"
elif have pacman && pacman -Qo /usr/bin/niri >/dev/null 2>&1; then
	owner=$(pacman -Qo /usr/bin/niri 2>/dev/null | head -1)
	if printf '%s' "$owner" | grep -q 'niri-shm'; then
		pkgver=$(printf '%s' "$owner" | grep -oE 'niri-shm[^ ]*' | head -1)
		ok "二进制来自 $pkgver"
	else
		warn "/usr/bin/niri 不来自 niri-shm，多半是官方原版"
		printf '       原版 niri 不宣告 shm 格式，Electron 客户端完全拿不到画面。\n'
	fi
else
	warn "无法判断 /usr/bin/niri 是否带补丁"
	printf '       原版 niri 不宣告 shm 格式，Electron 客户端完全拿不到画面。\n'
	printf '       确认一下装的是哪个包。\n'
fi

# 补丁版本会把打过补丁的 commit 通过 --version 报出来，用来交叉核对运行中的
# 合成器和已安装的二进制是不是同一个。
if have niri; then
	commit=$(niri msg version 2>/dev/null | grep -oE '\(([0-9a-f]{7,40})\)' | head -1 | tr -d '()')
	[ -n "${commit:-}" ] && info "合成器 commit $commit"
fi

# ---------------------------------------------------------------------------
head_ "【三】桌面门户"

if ! have busctl; then
	warn "缺少 busctl，无法检查门户（装 systemd）"
elif ! busctl --user list 2>/dev/null | grep -q 'org.freedesktop.portal.Desktop'; then
	bad "会话总线上没有 org.freedesktop.portal.Desktop"
	printf '       客户端在到达 niri 之前就失败了。\n'
	printf '       systemctl --user restart xdg-desktop-portal xdg-desktop-portal-gnome\n'
else
	ok "门户已在会话总线上"
fi

npc="$confdir/xdg-desktop-portal/niri-portals.conf"
if [ -f "$npc" ]; then
	if grep -q 'UseIn=false' "$npc"; then
		bad "niri-portals.conf 禁用了 niri 采集后端"
		printf '       UseIn=false 会把所有请求交给别的门户后端，那些在 niri 下\n'
		printf '       根本无法采集屏幕。\n'
	else
		ok "niri 门户后端已启用"
	fi
fi

# ---------------------------------------------------------------------------
head_ "【四】帧率配置"

cfg="$confdir/niri/config.kdl"
if [ -r "$cfg" ] && grep -qE '^[[:space:]]*frame-rate-hz' "$cfg"; then
	rate=$(grep -oE 'frame-rate-hz[[:space:]]+[0-9]+' "$cfg" | head -1 | grep -oE '[0-9]+')
	ok "帧率设为 ${rate:-?} Hz"
	if [ -n "${rate:-}" ] && { [ "$rate" -lt 1 ] || [ "$rate" -gt 240 ]; }; then
		warn "帧率 $rate 超出 1-240，niri 会静默钳位"
	fi
elif [ -r "$cfg" ]; then
	warn "$cfg 里没有 frame-rate-hz"
	printf '       niri 会用内置默认值。要显式指定就加上：\n'
	printf '           screencasting { frame-rate-hz 60 }\n'
else
	warn "找不到 niri 配置 $cfg"
fi

# ---------------------------------------------------------------------------
head_ "【五】采集状态"

if have wpctl; then
	video_streams=$(wpctl status 2>/dev/null | grep -cE 'Stream/Output/Video')
	if [ "$video_streams" -gt 0 ]; then
		ok "当前有 $video_streams 路视频流"
	else
		info "当前没有视频流，共享时再跑一次本脚本"
	fi
fi

if have journalctl; then
	rm_count=$(journalctl --user -u niri.service --since '-30min' --no-pager 2>/dev/null | grep -c 'record_monitor')
	neg_count=$(journalctl --user -u niri.service --since '-30min' --no-pager 2>/dev/null | grep -c 'negotiated')
	if [ "$rm_count" -eq 0 ]; then
		info "最近 30 分钟没有任何采集请求"
		printf '       niri 根本没被叫到，问题在上游：门户选择框或者客户端本身。\n'
	elif [ "$neg_count" -eq 0 ]; then
		bad "有 $rm_count 次采集请求，但 0 次格式协商"
		printf '       客户端要了屏幕，然后在告诉 niri 它想要什么格式之前就放弃了。\n'
		printf '       常见原因是选择框被关掉，或者协商途中 PipeWire 出了事件（音频\n'
		printf '       设备切换、蓝牙连上）把整个图拆了。\n'
		printf '       解法：只留一个音频输出，然后重新共享。\n'
	else
		ok "$rm_count 次请求，$neg_count 次格式协商"
	fi
fi

# ---------------------------------------------------------------------------
head_ "【六】内存"

if [ -r /proc/meminfo ]; then
	shmem=$(awk '/^Shmem:/{printf "%.2f", $2/1048576}' /proc/meminfo)
	ok "Shmem ${shmem} GiB"
	if awk "BEGIN{exit !($shmem > 4)}"; then
		warn "Shmem 超过 4 GiB"
		printf '       长时间共享会在这里分配缓冲区。如果一直涨不回落，就调低帧率。\n'
	fi
fi

# ---------------------------------------------------------------------------
head_ "【七】音频图"

if ! have wpctl; then
	warn "缺少 wpctl，装 pipewire-utils"
else
	# 两种音频输出同时在线是采集线程崩掉或者直接放弃的头号原因：WirePlumber
	# 在两者之间切换默认设备，PipeWire 重建整个图，客户端手里握的句柄全部失效。
	wired=$(wpctl status 2>/dev/null | grep -cE 'usb-.*analog-stereo|analog-stereo$')
	bt=$(wpctl status 2>/dev/null | grep -cE 'bluez_output')
	if [ "$wired" -gt 0 ] && [ "$bt" -gt 0 ]; then
		bad "有线和蓝牙音频输出同时在线"
		printf '       WirePlumber 会在两者之间换默认设备，PipeWire 重建整个图，\n'
		printf '       采集线程的句柄就全失效了。表现是：选择框弹出，点共享，然后崩掉\n'
		printf '       或者立刻退出。\n'
		printf '       解法：拔掉其中一个，只留一种输出。\n'
	else
		ok "只有一种音频输出（有线=$wired 蓝牙=$bt）"
	fi
fi

# ---------------------------------------------------------------------------
printf '\n'

if [ "$problems" -eq 0 ] && [ "${#notes[@]}" -eq 0 ]; then
	printf '%s全部检查通过%s\n' "$G" "$B"
	exit 0
fi

if [ "$problems" -eq 0 ]; then
	printf '%s%d 项提醒，没有阻塞性问题%s\n' "$Y" "${#notes[@]}" "$B"
	exit 0
fi

printf '%s%d 项阻塞性问题，%d 项提醒%s\n' "$R" "$problems" "${#notes[@]}" "$B"
exit 1
