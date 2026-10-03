#!/bin/bash
# niri-shm-attrib.sh -- 按进程归属采样共享内存，并且带刹车。
#
# 为什么带刹车：这台机器上「一开共享内存就暴涨」，实测 30 秒从 1.2 GiB 涨到
# 11.5 GiB，人工来不及关，整机卡死。所以本脚本超过阈值会自己把采集流掐掉
# （destroy 掉那个 Stream/Output/Video 节点，等价于对方关掉共享），必要时再
# 杀客户端进程，避免整机冻住。
#
# 采样是只读的（/proc、/sys、journal、pw-dump）。唯一的破坏性动作只在触发
# 阈值时发生：destroy 视频流节点，以及 3 秒后仍在涨时杀 qq（--no-kill 关掉后者）。
#
# 用法：
#   ./niri-shm-attrib.sh                              # 2 秒一次，不设刹车
#   ./niri-shm-attrib.sh 0.5 300 --guard 3            # 0.5 秒一次，超 3 GiB 自动刹车
#   ./niri-shm-attrib.sh 0.5 300 --guard 3 > ~/coding/shm-attrib.csv
#
# 读 CSV 时看这两类列（按进程归属，单位 GiB）：
#   *_res    常驻 shmem（smaps_rollup）—— 真正占着内存的量，泄漏看这个
#   *_alloc  memfd / /dev/shm 在它 fd 表里的已声明字节 —— 谁握着就谁让这些页活着
# 注意 alloc 可能远大于 res：memfd 可以被 ftruncate 成很大但一页都没碰过（例：
# Intel Vulkan 在 portal 里建的 6×1 GiB memfd，res=0，不占内存）。所以判泄漏用
# res，alloc 用来看「谁握着 fd」。
# 触发刹车时会把当时的完整进程表写到 dump 文件（路径会打印出来）。

set -uo pipefail

interval=2
duration=0
guard=""
do_kill=1
dumpfile=""
args=()
while [ $# -gt 0 ]; do
	case "$1" in
		--guard) guard="${2:-}"; shift 2 ;;
		--no-kill) do_kill=0; shift ;;
		--dump) dumpfile="${2:-}"; shift 2 ;;
		-h|--help) sed -n '2,40p' "$0"; exit 0 ;;
		*) args+=("$1"); shift ;;
	esac
done
interval="${args[0]:-$interval}"
duration="${args[1]:-$duration}"
[ -n "$dumpfile" ] || dumpfile="${TMPDIR:-/tmp}/niri-shm-dump-$(date +%s).txt"

have() { command -v "$1" >/dev/null 2>&1; }

meminfo_val() {
	awk -v k="$1" '$1 == k { printf "%.3f", $2 / 1048576 }' /proc/meminfo
}

# 最近一次协商到的帧率：运行中进程真正拿到的值，不是配置文件里的值。
last_fps() {
	have journalctl || return 0
	journalctl --user -u niri.service --since '-10min' --no-pager 2>/dev/null |
		grep -oE 'framerate: spa_fraction \{ num: [0-9]+' | tail -1 | grep -oE '[0-9]+$'
}

# 每个进程一行：alloc_bytes res_kB pid comm memfd数
#   alloc  = 它 fd 表里 memfd//dev/shm 的已分配字节之和。谁握着 fd，谁就让这些
#            页活着，所以这是「谁在囤」的直接证据（不只是「谁创建的」）。
#   res    = smaps_rollup 的 Shmem，它映射到的常驻共享页。
#
# 性能：几百个进程时逐 fd fork 要 7 秒，会漏掉暴涨的头几秒。所以常驻 shmem 用
# 一次 awk 扫完所有 smaps_rollup，共享 fd 用一次 find 列出来、一次 stat 取全部
# 大小（stat 可以吃多个路径），全程只 fork 个位数次。
snapshot() {
	local d pid n res alloc fds path kb list size fdpath tmp
	declare -A res_of=() alloc_of=() fds_of=()

	while read -r path kb; do
		pid=${path#/proc/}
		res_of[${pid%/smaps_rollup}]=$kb
	done < <(awk '/^Shmem:/{ if ($2+0 > 0) print FILENAME, $2 }' \
		/proc/[0-9]*/smaps_rollup 2>/dev/null)

	list=$(find /proc/[0-9]*/fd -maxdepth 1 -type l \
		\( -lname '*memfd:*' -o -lname '/dev/shm/*' \) 2>/dev/null)
	if [ -n "$list" ]; then
		while read -r size fdpath; do
			tmp=${fdpath#/proc/}
			pid=${tmp%%/*}
			alloc_of[$pid]=$(( ${alloc_of[$pid]:-0} + size ))
			fds_of[$pid]=$(( ${fds_of[$pid]:-0} + 1 ))
		done < <(stat -Lc '%s %n' $list 2>/dev/null)
	fi

	for d in /proc/[0-9]*; do
		pid=${d#/proc/}
		read -r n < "$d/comm" 2>/dev/null || continue
		res=${res_of[$pid]:-0}
		alloc=${alloc_of[$pid]:-0}
		[ "$res" -gt 0 ] || [ "$alloc" -gt 0 ] || continue
		printf '%s %s %s %s %s\n' "$alloc" "$res" "$pid" "$n" "${fds_of[$pid]:-0}"
	done
}

# 采集流节点：id、谁在消费、它的 pid
video_streams() {
	have pw-dump || return 0
	have jq || return 0
	pw-dump 2>/dev/null |
		jq -r '.[] | select(.info.props["media.class"] == "Stream/Output/Video") |
			"\(.id) \(.info.props["application.name"] // "?") pid=\(.info.props["application.process.id"] // "?")"' 2>/dev/null
}

# 汇总某一类进程：allocGiB resGiB fds
agg() {
	printf '%s\n' "$1" | awk -v pat="$2" '
		$4 ~ pat { a += $1; r += $2; f += $5 }
		END { printf "%.3f %.3f %d", a/1073741824, r/1048576, f }'
}

# 按常驻 shmem 排序：这才是真正占着内存的量。alloc 大但 res=0 只是「声明了
# 大小但没碰过页」（例：Intel Vulkan 在 portal 里建的 6×1 GiB memfd）。
top_res_rows() {
	printf '%s\n' "$1" | sort -k2,2 -rn -k1,1 -rn | head -8 |
		awk '{ printf "%s(%s) res=%.3fGiB alloc=%.3fGiB fds=%s\n", $4, $3, $2/1048576, $1/1073741824, $5 }'
}

# 按已声明字节排序：谁手上握着最多 memfd。
top_alloc_rows() {
	printf '%s\n' "$1" | sort -k1,1 -rn | head -8 |
		awk '{ printf "%s(%s) alloc=%.3fGiB res=%.3fGiB fds=%s\n", $4, $3, $1/1073741824, $2/1048576, $5 }'
}

guard_trip() {
	local total="$1" snap="$2"
	printf '\n# ===== 触发刹车：Shmem %s GiB 超过上限 %s GiB =====\n' "$total" "$guard" >&2
	{
		printf 'Shmem %s GiB，上限 %s GiB，%s\n\n' "$total" "$guard" "$(date '+%F %T')"
		printf '按常驻 shmem 排序（谁真的占着内存）:\n'
		top_res_rows "$snap"
		printf '\n按已声明字节排序（谁握着最多 memfd）:\n'
		top_alloc_rows "$snap"
		printf '\n采集流:\n'
		video_streams
	} | tee "$dumpfile" >&2
	printf '完整快照已写入 %s\n' "$dumpfile" >&2

	local ids id
	ids=$(video_streams | awk '{print $1}')
	if [ -n "$ids" ]; then
		for id in $ids; do
			if pw-cli destroy "$id" >/dev/null 2>&1; then
				printf '  已掐掉视频流节点 %s（不动客户端）\n' "$id" >&2
			else
				printf '  掐不掉节点 %s，请你手动关共享\n' "$id" >&2
			fi
		done
	else
		printf '  没找到视频流节点（采集可能已经停了）\n' >&2
	fi

	# 给 fd 归还一点时间；还降不下来就说明共享没被掐断。
	sleep 3
	local after
	after=$(meminfo_val Shmem:)
	printf '  3 秒后 Shmem %s GiB\n' "$after" >&2
	if awk -v a="$after" -v g="$guard" 'BEGIN{exit !(a > g + 0.5)}'; then
		if [ "$do_kill" -eq 1 ] && have pkill; then
			printf '  还在涨，按预案杀掉 qq 进程（--no-kill 可以关掉这一步）\n' >&2
			if pkill -x qq; then printf '  已杀 qq\n' >&2; else printf '  没找到 qq 进程\n' >&2; fi
		else
			printf '  还在涨，请手动关掉共享\n' >&2
		fi
	fi
}

printf '# ts interval=%s duration=%s guard=%s\n' "$interval" "$duration" "${guard:-无}"
printf '# epoch,shmem_gib,shmem_huge_gib,niri_alloc_gib,niri_res_gib,niri_fds,portal_alloc_gib,portal_res_gib,portal_fds,client_alloc_gib,client_res_gib,client_fds,top_name,top_pid,top_alloc_gib,top_res_gib,top_fds,fps,streams\n'

# 上限必须高于当前占用，否则一启动就误触发。
if [ -n "$guard" ]; then
	base=$(meminfo_val Shmem:)
	if awk -v b="$base" -v g="$guard" 'BEGIN{exit !(b > g)}'; then
		printf '上限 %s GiB 低于当前 Shmem %s GiB，先调高再跑。\n' "$guard" "$base" >&2
		exit 64
	fi
	printf '# 起始 Shmem %s GiB，上限 %s GiB\n' "$base" "$guard" >&2
fi

start=$(date +%s)
n=0
while :; do
	now=$(date +%s)
	total=$(meminfo_val Shmem:)
	huge=$(meminfo_val ShmemHugePages:)
	fps=$(last_fps)
	streams=$(video_streams | awk '{printf "%s(%s) ", $1, $2}')

	snap=$(snapshot)
	read -r niri_a niri_r niri_f <<<"$(agg "$snap" '^niri$')"
	read -r p_a p_r p_f <<<"$(agg "$snap" '^xdg-desktop-por')"
	read -r q_a q_r q_f <<<"$(agg "$snap" '^qq')"
	top=$(printf '%s\n' "$snap" | sort -k2,2 -rn -k1,1 -rn | head -1)

	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$now" "${total:-?}" "${huge:-?}" \
		"$niri_a" "$niri_r" "$niri_f" "$p_a" "$p_r" "$p_f" "$q_a" "$q_r" "$q_f" \
		"$(printf '%s\n' "$top" | awk '{print $4}')" "$(printf '%s\n' "$top" | awk '{print $3}')" \
		"$(printf '%s\n' "$top" | awk '{printf "%.3f", $1/1073741824}')" \
		"$(printf '%s\n' "$top" | awk '{printf "%.3f", $2/1048576}')" \
		"$(printf '%s\n' "$top" | awk '{print $5}')" "${fps:-0}" "${streams:-none}"

	printf '  [%s] Shmem %s GiB | niri %s/%s GiB %sfd | portal %s/%s GiB %sfd | client %s/%s GiB %sfd | fps %s | top %s\n' \
		"$(date +%T)" "${total:-?}" "$niri_a" "$niri_r" "$niri_f" \
		"$p_a" "$p_r" "$p_f" "$q_a" "$q_r" "$q_f" "${fps:-?}" \
		"$(printf '%s\n' "$top" | awk '{printf "%s(%s) %.3fGiB", $4, $3, $1/1073741824}')" >&2

	# 真卡死会丢掉 page cache，所以定期把 CSV 落到盘上。
	n=$((n + 1))
	if [ -n "$guard" ]; then
		if awk -v a="$total" -v g="$guard" 'BEGIN{exit !(a > g)}'; then
			# 只有真的存在采集流时才动手：否则超上限可能是别的程序占的
			# shmem，掐流没有意义，杀客户端更是误伤。
			if [ -n "$streams" ]; then
				guard_trip "$total" "$snap"
				printf '# GUARD TRIPPED at %s GiB\n' "$total"
				sync
				exit 2
			fi
			printf '# 警告：Shmem %s GiB 超过上限 %s，但没有采集流，不动手\n' "$total" "$guard" >&2
		fi
		[ $((n % 5)) -eq 0 ] && sync
	fi

	if [ "$duration" -gt 0 ] && [ $((now - start)) -ge "$duration" ]; then
		break
	fi
	sleep "$interval"
done
