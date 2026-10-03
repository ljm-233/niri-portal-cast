#!/bin/bash
# niri-portal-cast-tune -- 一条命令改共享的画质/内存档位，不用手编 config.kdl。
#
# 三道安全网：
#   1. 新内容先写临时文件并 niri validate，通过才原子替换（niri 看不到写了一半的文件）
#   2. 写进去后回头查 journal：如果**运行中的** niri 拒绝这份配置，自动回滚
#   3. 运行中的 niri 若比磁盘上的二进制旧（比如刚升级还没重启），它不认识的选项
#      （max-pixels）会被自动跳过，只改它认识的帧率
#
# 限制值是每次开始共享时读的，所以改完**重开一次共享就生效，不用重启 niri**。
#
# 用法：
#   niri-portal-cast-tune              # 看当前设置
#   niri-portal-cast-tune menu         # 分开选：① 分辨率 → ② 帧率
#   niri-portal-cast-tune menu-res     # 只弹分辨率
#   niri-portal-cast-tune menu-fps     # 只弹帧率
#   niri-portal-cast-tune 1080p|2k|2.5k|720p|smooth|balanced|saver|safe
#   niri-portal-cast-tune fps 30       # 只改帧率
#   niri-portal-cast-tune size 1920x1080   # 只改分辨率（off = 不限制）
#   niri-portal-cast-tune brake        # 看内存刹车状态（= brake status）
#   niri-portal-cast-tune brake off    # 关掉内存刹车（停服务并清掉手工挂的残留）
#   niri-portal-cast-tune brake on     # 打开内存刹车（阈值 = 开机基线 + 2 GiB）

set -uo pipefail
cfg="${XDG_CONFIG_HOME:-$HOME/.config}/niri/config.kdl"

die() { printf '%s\n' "$*" >&2; exit 1; }

read_vals() {
	cur_fps=$(grep -oE '^[[:space:]]*frame-rate-hz[[:space:]]+[0-9]+' "$cfg" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
	cur_px=$(grep -oE '^[[:space:]]*max-pixels[[:space:]]+[0-9]+' "$cfg" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
	: "${cur_fps:=60}" "${cur_px:=4096000}"
}

size_to_px() { awk -v s="$1" 'BEGIN{ split(s,a,"x"); if (a[1]<=0 || a[2]<=0) exit 1; printf "%d", a[1]*a[2] }'; }
px_to_size() { awk -v px="$1" 'BEGIN{ w=int(sqrt(px*2560/1600)/2)*2; h=int(px/w/2)*2; printf "%dx%d", w, h }'; }

show() {
	read_vals
	local size="全分辨率"
	[ "$cur_px" -lt 4096000 ] 2>/dev/null && size="$(px_to_size "$cur_px")"
	printf '当前：帧率上限 %s fps，分辨率上限 %s（%s 像素）\n' "$cur_fps" "$size" "$cur_px"
	printf '改档位：niri-portal-cast-tune menu   （或 1080p / 2k / fps 30 / size 1920x1080）\n'
}

journal_has() { journalctl --user -u niri.service --since "$1" --no-pager 2>/dev/null | grep -q "$2"; }

# 运行中的合成器是否已经拒绝过 max-pixels（说明它是升级前的旧进程）
running_lacks_max_pixels() {
	journalctl --user -u niri.service --since '-30min' --no-pager 2>/dev/null |
		grep -q 'unexpected node .max-pixels.'
}

# 只动 screencasting { } 里的这两行，其它内容（含注释）原样保留。
# px 传空字符串 = 顺手把 max-pixels 那行删掉。
apply_raw() {
	local fps="$1" px="$2"
	[ -f "$cfg" ] || die "找不到 $cfg"
	[ -n "$fps" ] || die "帧率没给"
	local bak="$cfg.bak-$(date +%s)" tmp="$cfg.tune-$$"
	cp -p "$cfg" "$bak" || die "备份失败，中止"

	awk -v fps="$fps" -v px="$px" '
		BEGIN { inblk = 0; seen_fps = 0; seen_px = 0; seen_blk = 0 }
		!inblk && /^[ \t]*screencasting[ \t]*\{/ { inblk = 1; seen_blk = 1; print; next }
		inblk && /^[ \t]*\}/ {
			if (!seen_fps) print "\tframe-rate-hz " fps
			if (!seen_px && px != "") print "\tmax-pixels " px
			inblk = 0; print; next
		}
		inblk && /^[ \t]*max-pixels/ { if (px != "") { print "\tmax-pixels " px; seen_px = 1 } next }
		inblk && /^[ \t]*frame-rate-hz/ { print "\tframe-rate-hz " fps; seen_fps = 1; next }
		{ print }
		END {
			if (!seen_blk) {
				print ""
				print "screencasting {"
				print "\tframe-rate-hz " fps
				if (px != "") print "\tmax-pixels " px
				print "}"
			}
		}
	' "$cfg" > "$tmp" || { rm -f "$tmp"; die "生成新配置失败"; }

	if ! niri validate -c "$tmp" >/tmp/tune-validate.log 2>&1; then
		rm -f "$tmp"
		printf '新配置本机 niri 不接受，你的文件没有被改动。原因：\n' >&2
		tail -5 /tmp/tune-validate.log >&2
		exit 1
	fi

	mv -f "$tmp" "$cfg" || { rm -f "$tmp"; die "替换失败"; }   # 原子替换
	printf '已写入：%s fps%s（备份 %s）\n' "$fps" \
		"$( [ -n "$px" ] && printf '，%s 像素上限' "$px" )" "$bak"

	# 闭环：磁盘上的 niri 说合法，不代表**正在跑的那个**也认。查 journal。
	sleep 3
	if journal_has '-6s' 'error loading config'; then
		cp -p "$bak" "$cfg"
		printf '\n运行中的 niri 拒绝了这份配置，已自动回滚。它给出的原因：\n' >&2
		journalctl --user -u niri.service --since '-6s' --no-pager 2>/dev/null |
			grep -E "unexpected node|error parsing|╰─▶" | tail -3 >&2
		printf '（多半是它比磁盘上的二进制旧：重启 niri 之后新选项才生效）\n' >&2
		exit 1
	fi
	printf '→ 重开一次屏幕共享即生效，不用重启 niri。\n'
}

# 对外入口：旧的合成器不认 max-pixels 时只改帧率，免得写了又被它拒绝
apply() {
	local fps="$1" px="$2"
	if [ -n "$px" ] && running_lacks_max_pixels; then
		printf '注意：运行中的 niri 还不认识 max-pixels（它比磁盘上的二进制旧）。\n' >&2
		printf '这次只改帧率，并把配置里多余的 max-pixels 清掉；重启 niri 之后分辨率档才能用。\n' >&2
		apply_raw "$fps" ""
		return $?
	fi
	apply_raw "$fps" "$px"
}

pick_res() {
	command -v fuzzel >/dev/null || die "没装 fuzzel；用：size 1920x1080 或 1080p / 2k / 2.5k"
	local pick
	pick=$(printf '全分辨率 2560x1600\n2.5k 2560x1600\n2k 2560x1440\n1080p 1920x1080\n1280x800\n720p 1280x720\n960x600\n' |
		fuzzel --dmenu --prompt '① 分辨率上限: ' --lines 7) || return 1
	pick=${pick%% *}   # 菜单项带说明文字，只取第一段（否则下面的匹配永远不中）
	case "$pick" in
		全分辨率|2.5k) echo 4096000 ;;
		2k)        echo 3686400 ;;
		1080p)     echo 2073600 ;;
		1280x800)  echo 1024000 ;;
		720p)      echo 921600 ;;
		960x600)   echo 576000 ;;
		*) return 1 ;;
	esac
}

pick_fps() {
	command -v fuzzel >/dev/null || die "没装 fuzzel；用：fps 30"
	local pick
	pick=$(printf '60 fps\n30 fps\n20 fps\n15 fps\n10 fps\n6 fps\n' |
		fuzzel --dmenu --prompt '② 帧率上限: ' --lines 6) || return 1
	local fps=${pick%% *}
	case "$fps" in ''|*[!0-9]*) return 1 ;; esac
	echo "$fps"
}

# ---------------------------------------------------------------------------
# 内存刹车开关：只管 systemd 用户服务与残留采样进程，不碰 frame-rate-hz / max-pixels
# 只认真正在跑的采样进程：它的第一个命令词必须是 niri-shm-attrib（或指向它的路径）。
# 不能用 pgrep -f 直接通杀 —— 外层 shell 的命令行里只要提到这个名字就会被误杀（实测踩过）。
brake_pids() {
	local p cmd
	for p in $(pgrep -f 'niri-shm-attrib' 2>/dev/null); do
		[ "$p" = "$$" ] && continue
		[ "$p" = "${PPID:-0}" ] && continue
		cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
		case "$cmd" in
			*/niri-shm-attrib[[:space:]]*|niri-shm-attrib[[:space:]]*) printf '%s\n' "$p" ;;
		esac
	done
}

brake_status() {
	local en act procs
	if command -v systemctl >/dev/null 2>&1; then
		en=$(systemctl --user is-enabled niri-shm-attrib 2>/dev/null || true)
		act=$(systemctl --user is-active niri-shm-attrib 2>/dev/null || true)
		case "$en" in enabled) en="已启用" ;; disabled) en="已禁用" ;; *) en="${en:-未知}" ;; esac
		case "$act" in active) act="运行中" ;; inactive) act="未运行" ;; *) act="${act:-未知}" ;; esac
	else
		en="systemd 不可用"; act="systemd 不可用"
	fi
	procs=$(brake_pids | wc -l)
	printf '内存刹车：服务 %s / %s，实际在跑的采样进程 %s 个\n' "$en" "$act" "$procs"
	if [ "$act" = "运行中" ]; then
		printf '  共享内存失控时自动掐流，不会冻机。关闭：niri-portal-cast-tune brake off\n'
	else
		printf '  当前没有刹车，内存失控时只能靠降档自保。开启：niri-portal-cast-tune brake on\n'
	fi
}

brake_off() {
	local pids p running=no
	if command -v systemctl >/dev/null 2>&1; then
		systemctl --user is-active niri-shm-attrib >/dev/null 2>&1 && running=yes
		systemctl --user disable --now niri-shm-attrib >/dev/null 2>&1 || true
	fi
	# 只清 niri-shm-attrib 自己的残留进程：先列出再杀，绝不按名字通杀别的程序
	pids=$(brake_pids)
	if [ -n "$pids" ]; then
		running=yes
		printf '清理残留采样进程（只匹配 niri-shm-attrib）：%s\n' "$(printf '%s' "$pids" | tr '\n' ' ')"
		for p in $pids; do
			[ "$p" = "$$" ] && continue
			kill "$p" 2>/dev/null || true
		done
	else
		printf '没有残留的手工采样进程。\n'
	fi
	if [ "$running" = no ]; then
		printf '刹车本来就是关的。\n'
		return 0
	fi
	printf '刹车已关闭：共享不再被自动掐流（内存失控时就只能靠降档自保了）。\n'
}

brake_on() {
	command -v systemctl >/dev/null 2>&1 || die "systemd 不可用，无法开启刹车"
	if systemctl --user enable --now niri-shm-attrib >/dev/null 2>&1; then
		printf '刹车已开启（阈值 = 开机基线 + 2 GiB）。\n'
	else
		die "开启失败，手工试：systemctl --user enable --now niri-shm-attrib"
	fi
}

[ $# -gt 0 ] || { show; exit 0; }

case "$1" in
	smooth)   apply 60 4096000 ;;
	1080p)    apply 30 2073600 ;;
	2k|1440p) apply 30 3686400 ;;
	2.5k)     apply 30 4096000 ;;
	720p)     apply 30 921600 ;;
	balanced) apply 30 1024000 ;;
	saver)    apply 15 576000 ;;
	safe)     apply 6 576000 ;;
	fps)      read_vals; apply "${2:?缺帧率}" "$cur_px" ;;
	size)
		read_vals
		case "${2:-}" in
			off) apply "$cur_fps" 4096000 ;;
			*)   apply "$cur_fps" "$(size_to_px "${2:?缺尺寸}")" ;;
		esac ;;
	menu-res) read_vals; px=$(pick_res) || die "没选或没识别，什么都没改"; apply "$cur_fps" "$px" ;;
	menu-fps) read_vals; fps=$(pick_fps) || die "没选或没识别，什么都没改"; apply "$fps" "$cur_px" ;;
	menu)
		# 两步各起一个进程：同一个进程里连着开两次 fuzzel，某些环境下第二次拿不到输入焦点
		read_vals
		px=$(pick_res) || die "① 没选或没识别，什么都没改"
		apply "$cur_fps" "$px" || exit $?
		printf '② 接着选帧率……\n'
		exec "$0" menu-fps ;;
	brake)
		case "${2:-status}" in
			off)    brake_off ;;
			on)     brake_on ;;
			status|"") brake_status ;;
			*)      die "不认识的参数：brake $2（用 brake / brake on / brake off）" ;;
		esac ;;
	-h|--help) sed -n '2,26p' "$0"; exit 0 ;;
	*) die "不认识的档位：$1（用 menu / menu-res / menu-fps / 1080p / 2k / 2.5k / fps N / size WxH）" ;;
esac
