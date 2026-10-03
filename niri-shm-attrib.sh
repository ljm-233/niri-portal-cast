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
#   *_res     它映射到的常驻共享页（smaps_rollup 的 Pss_Shmem，多个映射者按份分摊）
#   *_alloc   memfd / /dev/shm / dmabuf 在它 fd 表里的已声明字节 —— 谁握着 fd 谁就让这些页活着
# 注意两个坑：
#   1. alloc 可能远大于 res：memfd 可以被 ftruncate 成很大却一页都没碰过（例：Intel
#      Vulkan 在 portal 里建的 6×1 GiB memfd，res=0，不占内存）。判泄漏要看 res。
#   2. smaps_rollup 里没有裸的 "Shmem:" 字段，只有 Pss_Shmem / ShmemPmdMapped。读错
#      字段会让 res 恒为 0，看起来像「没有人在占」——这坑踩过一次。
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
#   res    = smaps_rollup 的 Pss_Shmem（多个映射者按份分摊）。
#            注意这里没有裸的 "Shmem:" 字段：读它会让 res 恒为 0。
#
# 性能：几百个进程时逐 fd fork 要 7 秒，会漏掉暴涨的头几秒。所以常驻 shmem 用
# 一次 awk 扫完所有 smaps_rollup，共享 fd 用一次 find 列出来、一次 stat 取全部
# 大小（stat 可以吃多个路径），全程只 fork 个位数次。
snapshot() {
	local d pid n res alloc fds path kb list size fdpath tmp
	declare -A res_of=() alloc_of=() fds_of=() drm_of=()

	while read -r pid kb; do
		res_of[$pid]=$kb
	done < <(grep -H '^Pss_Shmem:' /proc/[0-9]*/smaps_rollup 2>/dev/null |
		awk -F: '{ p=$1; sub(/^\/proc\//,"",p); sub(/\/smaps_rollup$/,"",p);
			kb=$3+0; if (kb > 0) print p, kb }')

	# memfd / /dev/shm / dmabuf 三类 fd：dmabuf 是关键的一类，它能让 GPU 侧的
	# GEM 对象一直活着（niri 空闲时就握着 54 个 dmabuf fd / 749 MiB），而且它
	# 不出现 niri 的 memfd 计数里 —— 漏掉整类就等于漏掉泄漏本身。
	list=$(find /proc/[0-9]*/fd -maxdepth 1 -type l \
		\( -lname '*memfd:*' -o -lname '/dev/shm/*' -o -lname '/dmabuf:*' \) 2>/dev/null)
	if [ -n "$list" ]; then
		while read -r size fdpath; do
			tmp=${fdpath#/proc/}
			pid=${tmp%%/*}
			alloc_of[$pid]=$(( ${alloc_of[$pid]:-0} + size ))
			fds_of[$pid]=$(( ${fds_of[$pid]:-0} + 1 ))
		done < <(stat -Lc '%s %n' $list 2>/dev/null)
	fi

	# GPU 侧的 shmem 缓冲（GEM/dma-buf）：它算进 /proc/meminfo 的 Shmem，却不出现
	# 在任何进程的 smaps 里。i915 在 fdinfo 里按 DRM client 报用量，这是唯一能
	# 归属到进程的口子。两个坑：
	#   - 同一个 client 常被 dup 成多个 fd（niri 这里是 5 个），按 fd 求和会算 5 遍，
	#     所以按 (pid, 指标名) 取最大值去重；
	#   - drm-resident-* 对 i915 是可回收的、会来回漂，用 drm-total-* 看分配量。
	while read -r pid kb; do
		drm_of[$pid]=$(( ${drm_of[$pid]:-0} + kb ))
	done < <(grep -H '^drm-total-' /proc/[0-9]*/fdinfo/* 2>/dev/null |
		awk -F: '{ p=$1; sub(/^\/proc\//,"",p); sub(/\/fdinfo\/.*/,"",p);
			k=p SUBSEP $2; v=$3+0; if (v > seen[k]) seen[k]=v }
			END { for (k in seen) { split(k, a, SUBSEP); tot[a[1]] += seen[k] }
				for (p in tot) if (tot[p] > 0) print p, tot[p] }')

	for d in /proc/[0-9]*; do
		pid=${d#/proc/}
		read -r n < "$d/comm" 2>/dev/null || continue
		res=${res_of[$pid]:-0}
		alloc=${alloc_of[$pid]:-0}
		[ "$res" -gt 0 ] || [ "$alloc" -gt 0 ] || [ "${drm_of[$pid]:-0}" -gt 0 ] || continue
		printf '%s %s %s %s %s %s\n' "$alloc" "$res" "$pid" "$n" \
			"${fds_of[$pid]:-0}" "${drm_of[$pid]:-0}"
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

# 汇总某一类进程：allocGiB resGiB fds drmGiB
agg() {
	printf '%s\n' "$1" | awk -v pat="$2" '
		$4 ~ pat { a += $1; r += $2; f += $5; d += $6 }
		END { printf "%.3f %.3f %d %.3f", a/1073741824, r/1048576, f, d/1048576 }'
}

# 按常驻 shmem 排序：这才是真正占着内存的量。alloc 大但 res=0 只是「声明了
# 大小但没碰过页」（例：Intel Vulkan 在 portal 里建的 6×1 GiB memfd）。
top_res_rows() {
	printf '%s\n' "$1" | sort -k2,2 -rn -k1,1 -rn | head -8 |
		awk '{ printf "%s(%s) res=%.3fGiB alloc=%.3fGiB fds=%s drm=%.3fGiB\n", $4, $3, $2/1048576, $1/1073741824, $5, $6/1048576 }'
}

# 按 GPU 侧 shmem 排序：GEM/dma-buf 不出现 smaps 里，只有这里能看到是谁。
top_drm_rows() {
	printf '%s\n' "$1" | sort -k6,6 -rn | head -8 |
		awk '{ printf "%s(%s) drm=%.3fGiB res=%.3fGiB alloc=%.3fGiB fds=%s\n", $4, $3, $6/1048576, $2/1048576, $1/1073741824, $5 }'
}

# 按已声明字节排序：谁手上握着最多 memfd。
top_alloc_rows() {
	printf '%s\n' "$1" | sort -k1,1 -rn | head -8 |
		awk '{ printf "%s(%s) alloc=%.3fGiB res=%.3fGiB fds=%s drm=%.3fGiB\n", $4, $3, $1/1073741824, $2/1048576, $5, $6/1048576 }'
}

guard_trip() {
	local total="$1" snap="$2"
	printf '\n# ===== 触发刹车：Shmem %s GiB 超过上限 %s GiB =====\n' "$total" "$guard" >&2
	{
		printf 'Shmem %s GiB，上限 %s GiB，%s\n\n' "$total" "$guard" "$(date '+%F %T')"
		printf '按常驻 shmem 排序（谁真的占着内存）:\n'
		top_res_rows "$snap"
		printf '\n按 GPU 侧 shmem 排序（GEM/dma-buf，smaps 里看不到的那部分）:\n'
		top_drm_rows "$snap"
		printf '\n按已声明字节排序（谁握着最多 memfd）:\n'
		top_alloc_rows "$snap"
		printf '\n采集流:\n'
		video_streams
	} | tee "$dumpfile" >&2
	{
		printf '\n=== 全部持有共享内存的进程（alloc_bytes res_kB pid comm fds drm_kB）===\n'
		printf '%s\n' "$snap" | sort -k2,2 -rn -k1,1 -rn
	} >> "$dumpfile"
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
printf '# epoch,shmem_gib,shmem_huge_gib,shmem_pmd_gib,devshm_mib,fd_total_gib,fd_total_count,drm_total_gib,niri_res_gib,niri_alloc_gib,niri_fds,niri_drm_gib,portal_res_gib,portal_alloc_gib,portal_fds,portal_drm_gib,client_res_gib,client_alloc_gib,client_fds,client_drm_gib,top_name,top_pid,top_res_gib,top_alloc_gib,top_fds,top_drm_gib,fps,streams\n'

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
	pmd=$(meminfo_val ShmemPmdMapped:)
	devshm=""
	if have df; then
		devshm=$(df -k /dev/shm 2>/dev/null | awk 'NR==2{printf "%.1f", $3/1024}')
	fi
	fps=$(last_fps)
	streams=$(video_streams | awk '{printf "%s(%s) ", $1, $2}')

	snap=$(snapshot)
	read -r niri_a niri_r niri_f niri_d <<<"$(agg "$snap" '^niri$')"
	read -r p_a p_r p_f p_d <<<"$(agg "$snap" '^xdg-desktop-por')"
	read -r q_a q_r q_f q_d <<<"$(agg "$snap" '^qq')"
	# 全系统合计：如果它在涨但没有任何一列在涨，说明持有者在别的进程里
	read -r fd_gib fd_n drm_g <<<"$(printf '%s\n' "$snap" |
		awk '{a+=$1; n+=$5; d+=$6} END{printf "%.3f %d %.3f", a/1073741824, n, d/1048576}')"
	top=$(printf '%s\n' "$snap" | sort -k2,2 -rn -k1,1 -rn | head -1)

	row=("$now" "${total:-?}" "${huge:-?}" "${pmd:-?}" "${devshm:-0}" "${fd_gib:-0}" "${fd_n:-0}" "${drm_g:-0}" \
		"$niri_r" "$niri_a" "$niri_f" "$niri_d" "$p_r" "$p_a" "$p_f" "$p_d" \
		"$q_r" "$q_a" "$q_f" "$q_d" \
		"$(printf '%s\n' "$top" | awk '{print $4}')" "$(printf '%s\n' "$top" | awk '{print $3}')" \
		"$(printf '%s\n' "$top" | awk '{printf "%.3f", $2/1048576}')" \
		"$(printf '%s\n' "$top" | awk '{printf "%.3f", $1/1073741824}')" \
		"$(printf '%s\n' "$top" | awk '{print $5}')" \
		"$(printf '%s\n' "$top" | awk '{printf "%.3f", $6/1048576}')" \
		"${fps:-0}" "${streams:-none}")
	printf '%s\n' "$(IFS=,; echo "${row[*]}")"

	printf '  [%s] Shmem %s GiB (GEM %s) | niri res=%s alloc=%s drm=%s %sfd | portal res=%s drm=%s | client res=%s drm=%s | fps %s | top %s\n' \
		"$(date +%T)" "${total:-?}" "${drm_g:-0}" \
		"$niri_r" "$niri_a" "$niri_d" "$niri_f" "$p_r" "$p_d" "$q_r" "$q_d" "${fps:-?}" \
		"$(printf '%s\n' "$top" | awk '{printf "%s(%s) res=%.3f drm=%.3f", $4, $3, $2/1048576, $6/1048576}')" >&2

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
