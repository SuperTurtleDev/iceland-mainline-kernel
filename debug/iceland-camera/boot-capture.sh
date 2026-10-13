#!/bin/bash
set -u

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
log_dir=$(readlink -f /var/tmp/iceland-camera-watch/current)
trace_marker=/sys/kernel/tracing/instances/iceland-camera/trace_marker
media_device=
chip_id_seen=0
deadline=$((SECONDS + 60))
entities=('sc820cs 0-0010' msm_csiphy5 msm_csid0 msm_vfe0_rdi0 msm_vfe0_video0)
exec > >(tee -a "$log_dir/boot-capture.log") 2>&1

mark()
{
	printf '%s\n' "$*" > "$trace_marker"
	logger -t iceland-camera-watch -- "$*"
	date --iso-8601=ns
	printf '%s uptime=' "$*"
	cat /proc/uptime
}

mark BOOT_CAPTURE_WAIT
while ((SECONDS < deadline)); do
	if ((chip_id_seen == 0)); then
		chip_id_line=$(grep -F 'sc820cs: chip id 0xd154 OK' "$log_dir/dmesg.log" 2>/dev/null | tail -n 1)
		if [[ -z "$chip_id_line" ]]; then
			chip_id_line=$(dmesg --time-format=raw | grep -F 'sc820cs: chip id 0xd154 OK' | tail -n 1)
		fi
		if [[ -n "$chip_id_line" ]]; then
			chip_id_seen=1
			mark "CHIP_ID_OK observed=$chip_id_line"
		fi
	fi

	if ((chip_id_seen)) && [[ -z "$media_device" ]]; then
		for candidate in /dev/media*; do
			[[ -c "$candidate" ]] || continue
			topology=$(media-ctl -d "$candidate" -p 2>/dev/null) || continue
			[[ "$topology" == *'Qualcomm Camera Subsystem'* ]] || continue
			media_device=$candidate
			break
		done
	fi

	if [[ -n "$media_device" ]]; then
		graph_ready=1
		for entity in "${entities[@]}"; do
			entity_node=$(media-ctl -d "$media_device" -e "$entity" 2>/dev/null)
			if [[ ! -c "$entity_node" ]]; then
				graph_ready=0
				break
			fi
		done
		if ((graph_ready)); then
			topology=$(media-ctl -d "$media_device" -p 2>/dev/null)
			if awk '
				/^- entity / { sensor = $0 ~ /: sc820cs 0-0010 \(/ }
				sensor && /-> "msm_csiphy5":0/ && /\[ENABLED,IMMUTABLE\]/ { ready = 1 }
				END { exit !ready }
			' <<< "$topology"; then
				printf '%s\n' "$topology" > "$log_dir/media-ready.txt"
				mark "GRAPH_READY media=$media_device"
				exec bash "$script_dir/stream.sh" "$media_device"
			fi
		fi
	fi
	sleep 0.05
done

mark "BOOT_CAPTURE_TIMEOUT chip_id_seen=$chip_id_seen media=${media_device:-none}"
cat /sys/kernel/debug/v4l2-async/pending_async_subdevices > "$log_dir/pending-async-timeout.txt" 2>&1
for candidate in /dev/media*; do
	[[ -c "$candidate" ]] || continue
	media-ctl -d "$candidate" -p > "$log_dir/${candidate##*/}-timeout.txt" 2>&1
done
exit 1
