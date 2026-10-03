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
	-h|--help) sed -n '2,26p' "$0"; exit 0 ;;
	*) die "不认识的档位：$1（用 menu / menu-res / menu-fps / 1080p / 2k / 2.5k / fps N / size WxH）" ;;
esac
