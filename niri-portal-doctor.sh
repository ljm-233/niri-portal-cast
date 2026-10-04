#!/usr/bin/env bash
# niri-portal-doctor -- 诊断 portal 屏幕共享不出画面的原因。
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
elif have pacman && pacman -Qo /usr/bin/niri >/dev/null 2>&1; then
	owner=$(pacman -Qo /usr/bin/niri 2>/dev/null | head -1)
	if printf '%s' "$owner" | grep -q 'niri-portal-cast'; then
		pkgver=$(printf '%s' "$owner" | grep -oE 'niri-portal-cast[^ ]*' | head -1)
		ok "二进制来自 $pkgver"
	else
		warn "/usr/bin/niri 来自 ${owner##* }，不是本包，多半是官方原版"
		printf '       原版 niri 不宣告 shm 格式，Electron 客户端完全拿不到画面。\n'
		printf '       本包的名字是 niri-portal-cast；如果装过旧版 niri-shm-git，\n'
		printf '       先 sudo pacman -Rns niri-shm-git 再装。\n'
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
head_ "【四】帧率配置是否生效"

# 补丁是在 PipeWire::new() 里一次性把帧率抓走的（见 0002 补丁），而 PipeWire 在
# niri 启动时构造。于是「写进 config.kdl」和「真正在推流」是两件事：只读配置文件
# 会把没生效的值报成正常，`niri msg action load-config-file` 也改不动它。这里两个
# 值都查，并明确说哪个算数。
# 取 journal 里最近一次真实协商结果，返回「epoch 帧率」。帧率要匹配第一个
# `framerate:` 片段：整行里还有 pixel_aspect_ratio 等别的 num:，贪心匹配会取错。
last_negotiated_fps() {
	have journalctl || return 0
	local line ep rate
	line=$(journalctl --user -u niri.service --since '-30min' --no-pager -o short-unix 2>/dev/null |
		grep 'framerate: spa_fraction { num:' | tail -1)
	[ -n "${line:-}" ] || return 0
	ep=${line%% *}
	rate=$(printf '%s' "$line" | grep -oE 'framerate: spa_fraction \{ num: [0-9]+' |
		head -1 | grep -oE '[0-9]+$')
	printf '%s %s\n' "${ep%%.*}" "${rate:-0}"
}

# 合成器的启动时刻，用来判断配置是不是启动之后才改的。
compositor_start() {
	if have systemctl; then
		local ts
		# LC_ALL=C: systemd 按当前 locale 格式化这个时间戳，中文 locale 下会
		# 变成「六 2026-10-03 ...」，date -d 解析不了。
		ts=$(LC_ALL=C systemctl --user show niri.service -p ActiveEnterTimestamp --value 2>/dev/null)
		if [ -n "${ts:-}" ] && [ "$ts" != "n/a" ]; then
			LC_ALL=C date -d "$ts" +%s 2>/dev/null && return 0
		fi
	fi
	if have pgrep; then
		local p
		p=$(pgrep -x niri 2>/dev/null | head -1)
		if [ -n "${p:-}" ]; then
			stat -c %Y "/proc/$p" 2>/dev/null && return 0
		fi
	fi
	return 0
}

cfg="$confdir/niri/config.kdl"
# 补丁把范围钳在 5-120（niri-config/src/screencasting.rs 的 FRAME_RATE_MIN/MAX）。
# 下限从 30 降到 5 是因为实测客户端（QQ 的 ppapi 进程）在整屏下只编码得动约
# 6 fps，30 的上限永远高于它的消费能力，堆积就只能按比例减慢、停不下来。
rate_min=5
rate_max=120
cfg_rate=""
if [ -r "$cfg" ] && grep -qE '^[[:space:]]*frame-rate-hz' "$cfg"; then
	cfg_rate=$(grep -oE 'frame-rate-hz[[:space:]]+[0-9]+' "$cfg" | head -1 | grep -oE '[0-9]+')
fi

live_line=$(last_negotiated_fps)
live_epoch=${live_line%% *}
live_rate=${live_line##* }
# 没有记录时两者都是空串；只有一个字段说明解析异常，宁可不用。
if [ "$live_line" = "$live_epoch" ]; then live_rate=""; fi

if [ -n "${cfg_rate:-}" ]; then
	cfg_mtime=$(stat -c %Y "$cfg" 2>/dev/null)
	start_at=$(compositor_start)

	# 配置里超出范围的值会被钳到边界，所以「真正该跑多少」是钳位后的值。
	cfg_effective=$cfg_rate
	if [ "$cfg_rate" -lt "$rate_min" ]; then cfg_effective=$rate_min; fi
	if [ "$cfg_rate" -gt "$rate_max" ]; then cfg_effective=$rate_max; fi
	if [ "$cfg_effective" != "$cfg_rate" ]; then
		warn "帧率 ${cfg_rate} 超出补丁的 ${rate_min}-${rate_max}，会被静默钳到 ${cfg_effective}"
	fi

	# journal 里那条记录可能早于本次合成器启动（上一轮测试留下的），那它就不
	# 代表现在的值，不能拿它下结论。
	if [ -n "${live_rate:-}" ] && [ -n "${start_at:-}" ] && [ "${live_epoch:-0}" -lt "$start_at" ]; then
		info "journal 里最近一次协商 ${live_rate} Hz 早于本次合成器启动，不作为现行值"
		live_rate=""
	fi

	if [ -n "${live_rate:-}" ]; then
		if [ "$live_rate" = "$cfg_effective" ]; then
			ok "帧率 ${cfg_effective} Hz 已生效（最近一次实际协商也是 ${live_rate} Hz）"
		elif [ -n "${cfg_mtime:-}" ] && [ -n "${live_epoch:-}" ] && [ "$cfg_mtime" -gt "$live_epoch" ]; then
			# 限制值是每次开始共享时读的，所以「配置比上次共享新」= 下次共享生效，不是故障。
			info "配置 ${cfg_effective} Hz 比最近一次共享新，下次共享生效（上次是 ${live_rate} Hz）"
		else
			bad "最近一次实际协商到的是 ${live_rate} Hz，不是配置的 ${cfg_effective}"
			printf '       限制值是每次开始共享时读的，正常情况下重开一次共享就会跟上。\n'
			printf '       一直对不上说明这个补丁没在生效：确认二进制来自 niri-portal-cast\n'
			printf '       （见【二】），并看 journal 里的 framerate 是不是真的没变。\n'
		fi
	elif [ -n "${cfg_mtime:-}" ] && [ -n "${start_at:-}" ] && [ "$cfg_mtime" -gt "$start_at" ]; then
		warn "配置写了 ${cfg_rate} Hz，但 config.kdl 是合成器启动之后改的"
		printf '       帧率只在 niri 启动时读一次。这次改动如果碰过 frame-rate-hz，\n'
		printf '       要重启会话才生效。\n'
	elif [ -n "${start_at:-}" ]; then
		ok "帧率配置 ${cfg_rate} Hz（合成器启动之后没改过）"
	else
		info "帧率配置 ${cfg_rate} Hz（拿不到合成器启动时刻，是否生效无法判断）"
	fi
elif [ -r "$cfg" ]; then
	warn "$cfg 里没有 frame-rate-hz"
	printf '       niri 用补丁的内置默认值（60）。要显式指定就加上：\n'
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
	# Count sessions that actually reached Streaming, not log lines matching
	# 'negotiated'. A successful shm negotiation does not print that word; it
	# shows up as "negotiated inefficient shm stream" only when the stream is
	# up. Counting the former flagged working sessions as failures.
	stream_count=$(journalctl --user -u niri.service --since '-30min' --no-pager 2>/dev/null | grep -c 'Paused -> Streaming')
	if [ "$rm_count" -eq 0 ]; then
		info "最近 30 分钟没有任何采集请求"
		printf '       niri 根本没被叫到，问题在上游：门户选择框或者客户端本身。\n'
	elif [ "$stream_count" -eq 0 ]; then
		bad "有 $rm_count 次采集请求，但 0 次格式协商"
		printf '       客户端要了屏幕，然后在告诉 niri 它想要什么格式之前就放弃了。\n'
		printf '       常见原因是选择框被关掉，或者协商途中 PipeWire 出了事件（音频\n'
		printf '       设备切换、蓝牙连上）把整个图拆了。\n'
		printf '       解法：只留一个音频输出，然后重新共享。\n'
	else
		ok "$rm_count 次请求，$stream_count 次成功出流"
		# 帧率用【四】里已经取好并做过新鲜度判定的那个值：客户端走的哪条路
		# （modifier 0 且 flags 0x0 是本包宣告的 shm 路，其余是带硬件
		# modifier 的 dmabuf）报表里也有，但这里只报真正当数的帧率。
		if [ -n "${live_rate:-}" ]; then
			ok "最近一次协商到的帧率 ${live_rate} Hz"
		fi
	fi
fi

# ---------------------------------------------------------------------------
head_ "【六】内存与 shmem 大页策略"

if [ -r /proc/meminfo ]; then
	shmem=$(awk '/^Shmem:/{printf "%.2f", $2/1048576}' /proc/meminfo)
	shmem_hp=$(awk '/^ShmemHugePages:/{printf "%.2f", $2/1048576}' /proc/meminfo)
	if awk "BEGIN{exit !($shmem > 4)}"; then
		warn "Shmem ${shmem} GiB（其中大页 ${shmem_hp} GiB）"
		printf '       长时间共享会在这里分配缓冲区。一直涨不回落就先调低帧率，\n'
		printf '       并确认配置真的生效（见【四】），再判断是谁在占（见仓库里的\n'
		printf '       niri-shm-attrib.sh，它按进程归属）。\n'
	elif [ -n "${shmem:-}" ]; then
		ok "Shmem ${shmem} GiB（其中大页 ${shmem_hp} GiB）"
	fi
fi

# 命令行里写了不等于内核就认。有些内核对 transparent_hugepage=shmem:xxx 这种写法
# 直接 "cannot parse, ignored"，只在 dmesg 里说一句，sysfs 里仍然是默认值。所以
# 这里比对实际策略，而不是相信 /proc/cmdline。
if [ -r /sys/kernel/mm/transparent_hugepage/shmem_enabled ]; then
	shmem_thp=$(sed 's/.*\[\([a-z_]*\)\].*/\1/' /sys/kernel/mm/transparent_hugepage/shmem_enabled)
	cmd_thp=$(tr ' ' '\n' < /proc/cmdline 2>/dev/null | grep -m1 '^transparent_hugepage=.*shmem' || true)
	if [ -n "${cmd_thp:-}" ]; then
		want_thp=${cmd_thp##*:}
		if [ "$want_thp" = "$shmem_thp" ]; then
			ok "shmem 大页策略 $shmem_thp（与内核命令行 $cmd_thp 一致）"
		else
			warn "内核命令行写着 $cmd_thp，实际策略是 $shmem_thp —— 这个参数被内核丢掉了"
			printf '       被丢掉的参数不会报错，只在 dmesg 里有一行\n'
			printf '       "transparent_hugepage= cannot parse, ignored"。\n'
			printf '       要真的改掉，开机后写 sysfs，例如：\n'
			printf '       w /sys/kernel/mm/transparent_hugepage/shmem_enabled - - - - never\n'
			printf '       （放 /etc/tmpfiles.d/thp-shmem.conf，systemd-tmpfiles --create 即可）\n'
		fi
	else
		info "shmem 大页策略 $shmem_thp（内核命令行没有设置，用的是默认值）"
	fi
fi

# 在线音频输出计数：逐个 wpctl inspect 判定，避免 wpctl status 的两个坑 ——
#   ① Settings 里列的是 WirePlumber「记住的」默认设备，设备不在线也在；
#   ② 在线 sink 在 wpctl status 里是描述文字，不是 node.name。
# 输出：<有线数> <蓝牙数> <蓝牙档位>
audio_graph_outputs() {
	local id info wired=0 bt=0 prof=""
	for id in $(wpctl status 2>/dev/null | grep -oE '^[^0-9]*[0-9]+\.' | grep -oE '[0-9]+'); do
		info=$(wpctl inspect "$id" 2>/dev/null) || continue
		case "$info" in
			*'media.class = "Audio/Sink"'*) ;;
			*) continue ;;
		esac
		case "$info" in
			*'node.name = "alsa_output.'*) wired=$((wired + 1)) ;;
			*'node.name = "bluez_output.'*)
				bt=$((bt + 1))
				[ -n "$prof" ] || prof=$(printf '%s\n' "$info" | grep 'api.bluez5.profile' | head -1 | sed 's/.*= *//; s/"//g')
				;;
		esac
	done
	printf '%s %s %s\n' "$wired" "$bt" "$prof"
}

# ---------------------------------------------------------------------------
head_ "【七】音频图"

if ! have wpctl; then
	warn "缺少 wpctl，装 pipewire-utils"
else
	# 两种音频输出同时在线是采集线程崩掉或者直接放弃的头号原因：WirePlumber
	# 在两者之间切换默认设备，PipeWire 重建整个图，客户端手里握的句柄全部失效。
	read -r wired bt prof <<<"$(audio_graph_outputs)"
	if [ "${wired:-0}" -gt 0 ] && [ "${bt:-0}" -gt 0 ]; then
		bad "有线和蓝牙音频输出同时在线"
		printf '       WirePlumber 会在两者之间换默认设备，PipeWire 重建整个图，\n'
		printf '       采集线程的句柄就全失效了。表现是：选择框弹出，点共享，然后崩掉\n'
		printf '       或者立刻退出。\n'
		printf '       解法：拔掉其中一个，只留一种输出。\n'
	elif [ "${wired:-0}" -eq 0 ] && [ "${bt:-0}" -eq 0 ]; then
		warn "没有任何在线音频输出"
		printf '       接上输出设备再跑一次，这条判断才有意义。\n'
	elif [ "${bt:-0}" -gt 0 ] && [ -n "${prof:-}" ]; then
		case "$prof" in
			*headset*|*hfp*)
				warn "蓝牙输出在通话档（$prof）"
				printf '       通话/用麦会让蓝牙切档，PipeWire 一样会重建图：共享会突然\n'
				printf '       无画面、通话可能挂不断。解法：通话时别用耳机麦，或只留 a2dp。\n' ;;
			*)
				ok "只有一种音频输出（有线=$wired 蓝牙=$bt 蓝牙档位=$prof）" ;;
		esac
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
