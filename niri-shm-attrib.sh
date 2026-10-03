#!/bin/bash
# niri-shm-attrib.sh -- 按进程归属采样共享内存，用来回答「共享时 Shmem 一路涨，
# 涨的是谁的内存」。
#
# 只读：只读 /proc、/sys、/proc/meminfo 和用户 journal，不写任何文件，不重启
# 任何进程，共享进行中跑也安全。
#
# 背景：/proc/meminfo 里的 Shmem 是全局计数，光看它分不出是 niri 在堆裸帧，还是
# QQ 自己的编码缓冲在涨。这两个原因的修法完全不同，所以先归属再动手。
#
# 用法：
#   ./niri-shm-attrib.sh              # 每 2 秒一次，直到 Ctrl-C
#   ./niri-shm-attrib.sh 1 300        # 每 1 秒一次，采 300 秒
#   ./niri-shm-attrib.sh 2 300 > shm.csv
#
# stdout 是 CSV（表头以 # 开头），stderr 是给人看的实时 top。
# 采样期间发起一次屏幕共享，然后看 Shmem 涨的时候 niri 和 qq 各自的列谁在动。

set -uo pipefail

interval="${1:-2}"
duration="${2:-0}"

command -v journalctl >/dev/null 2>&1 || true

# 全局计数（kB -> GiB 保留三位）
meminfo_val() {
	awk -v k="$1" '$1 == k { printf "%.3f", $2 / 1048576 }' /proc/meminfo
}

# 最近一次协商到的帧率：这是运行中进程真实拿到的值，不是配置文件里的值。
last_fps() {
	journalctl --user -u niri.service --since '-10min' --no-pager 2>/dev/null |
		grep -oE 'framerate: spa_fraction \{ num: [0-9]+' | tail -1 | grep -oE '[0-9]+$'
}

# 每个进程一行：shmem_kB pid comm memfd数
snapshot() {
	local d pid s n mf
	for d in /proc/[0-9]*; do
		pid=${d#/proc/}
		[ -r "$d/smaps_rollup" ] || continue
		s=$(awk '/^Shmem:/{print $2; exit}' "$d/smaps_rollup" 2>/dev/null)
		[ -n "${s:-}" ] || continue
		[ "$s" -gt 0 ] 2>/dev/null || continue
		n=$(cat "$d/comm" 2>/dev/null || echo '?')
		# memfd 与 /dev/shm 的 fd 数量：帧缓冲堆积时这个数会先动。
		mf=$(ls -l "$d/fd" 2>/dev/null | grep -cE 'memfd:|/dev/shm/')
		printf '%s %s %s %s\n' "$s" "$pid" "$n" "$mf"
	done
}

printf '# ts interval=%s\n' "$interval"
printf '# epoch,shmem_gib,shmem_huge_gib,attributed_gib,niri_gib,niri_memfd,qq_gib,qq_memfd,top_name,top_pid,top_gib,top_memfd,negotiated_fps\n'

start=$(date +%s)
peak=0
peak_at=""
while :; do
	now=$(date +%s)
	total=$(meminfo_val Shmem:)
	huge=$(meminfo_val ShmemHugePages:)
	fps=$(last_fps)

	snap=$(snapshot)
	# 归属合计（共享页会被多个进程重复计入，所以这是个上限，不是精确值）
	attributed=$(printf '%s\n' "$snap" | awk '{s+=$1} END{printf "%.3f", s/1048576}')

	niri=$(printf '%s\n' "$snap" | awk '$3=="niri"{s+=$1} END{printf "%.3f", s/1048576}')
	niri_mf=$(printf '%s\n' "$snap" | awk '$3=="niri"{s+=$4} END{print s+0}')
	qq=$(printf '%s\n' "$snap" | awk '$3 ~ /^qq/{s+=$1} END{printf "%.3f", s/1048576}')
	qq_mf=$(printf '%s\n' "$snap" | awk '$3 ~ /^qq/{s+=$4} END{print s+0}')

	top=$(printf '%s\n' "$snap" | sort -rn | head -1)
	top_name=$(printf '%s\n' "$top" | awk '{print $3}')
	top_pid=$(printf '%s\n' "$top" | awk '{print $2}')
	top_gib=$(printf '%s\n' "$top" | awk '{printf "%.3f", $1/1048576}')
	top_mf=$(printf '%s\n' "$top" | awk '{print $4}')

	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$now" "${total:-?}" "${huge:-?}" "$attributed" \
		"$niri" "$niri_mf" "$qq" "$qq_mf" \
		"${top_name:-?}" "${top_pid:-?}" "${top_gib:-?}" "${top_mf:-0}" "${fps:-0}"

	# 峰值只在「共享时」有意义，这里先记全局最大值，供复盘。
	awk -v a="$total" -v b="$peak" 'BEGIN{exit !(a > b)}' && { peak="$total"; peak_at="$(date +%T)"; }

	printf '  [%s] Shmem %s GiB (大页 %s) | niri %s GiB/%s fd | qq %s GiB/%s fd | 帧率 %s | top %s(%s) %s GiB/%s fd\n' \
		"$(date +%T)" "${total:-?}" "${huge:-?}" "$niri" "$niri_mf" "$qq" "$qq_mf" \
		"${fps:-?}" "${top_name:-?}" "${top_pid:-?}" "${top_gib:-?}" "${top_mf:-0}" >&2

	if [ "$duration" -gt 0 ] && [ $((now - start)) -ge "$duration" ]; then
		break
	fi
	sleep "$interval"
done

if [ -n "$peak_at" ]; then
	printf '# peak shmem %.3f GiB at %s\n' "$peak" "$peak_at" >&2
fi
