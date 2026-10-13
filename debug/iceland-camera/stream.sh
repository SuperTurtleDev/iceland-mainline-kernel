#!/bin/bash
set -u

log_dir=$(readlink -f /var/tmp/iceland-camera-watch/current)
trace_marker=/sys/kernel/tracing/instances/iceland-camera/trace_marker
media_device=${1:-/dev/media0}
video_device=$(media-ctl -d "$media_device" -e msm_vfe0_video0) || exit 1
exec > >(tee -a "$log_dir/front-stream.log") 2>&1

mark()
{
	printf '%s\n' "$*" > "$trace_marker"
	logger -t iceland-camera-watch -- "$*"
	date --iso-8601=ns
	printf '%s uptime=' "$*"
	cat /proc/uptime
}

configure_front()
{
	media-ctl -d "$media_device" -l '"msm_csiphy4":1 -> "msm_csid0":0 [0], "msm_csiphy5":1 -> "msm_csid0":0 [1], "msm_csid0":1 -> "msm_vfe0_rdi0":0 [1]' || return 1
	for entity in 'sc820cs 0-0010' msm_csiphy5 msm_csid0 msm_vfe0_rdi0; do
		media-ctl -d "$media_device" -V "\"$entity\":0 [fmt:SBGGR10_1X10/3264x2448 field:none]" || return 1
	done
	media-ctl -d "$media_device" -V '"msm_csid0":1 [fmt:SBGGR10_1X10/3264x2448 field:none]' || return 1
	v4l2-ctl -d "$video_device" --set-fmt-video=width=3264,height=2448,pixelformat=pBAA
}

mark FRONT_STREAM_SETUP
for function in gpi_process_events geni_i2c_clk_map_idx; do
	printf 'func %s +p\n' "$function" > /sys/kernel/debug/dynamic_debug/control
done
media-ctl -d "$media_device" -p > "$log_dir/media-before.txt"
media-ctl -d "$media_device" -r || exit 1
configure_front || exit 1
printf 'minor == %s\n' "${video_device#/dev/video}" > /sys/kernel/tracing/instances/iceland-camera/events/v4l2/v4l2_dqbuf/filter
echo 1 > /sys/kernel/tracing/instances/iceland-camera/events/v4l2/v4l2_dqbuf/enable
media-ctl -d "$media_device" -p > "$log_dir/media-configured.txt"
printf 'capture_device=%s\n' "$video_device"
mkdir -p "$log_dir/attempts"
attempt=0
failure_saved=0
route_recoveries=0
consecutive_route_recoveries=0
route_recovery_limit_reported=0
while true; do
	attempt=$((attempt + 1))
	printf -v attempt_log '%s/attempts/%06d.log' "$log_dir" "$attempt"
	mark "FRONT_STREAM_BEGIN attempt=$attempt frames=1"
	timeout --signal=TERM --kill-after=2 6 stdbuf -oL -eL v4l2-ctl -d "$video_device" --stream-mmap=4 --stream-count=1 --stream-to=/dev/null --verbose > "$attempt_log" 2>&1
	stream_rc=$?
	mark "FRONT_STREAM_END attempt=$attempt rc=$stream_rc"
	frame_count=$(grep -c 'cap dqbuf:' "$attempt_log")
	ioctl_error=$(grep -m1 -E 'returned -1|Error:|[Ff]ailed' "$attempt_log" || true)
	if [ "$stream_rc" -eq 0 ] && [ "$frame_count" -eq 1 ] && [ -z "$ioctl_error" ]; then
		consecutive_route_recoveries=0
		route_recovery_limit_reported=0
		mark "CYCLE_RESULT attempt=$attempt result=frame_received frames=$frame_count rc=$stream_rc"
	else
		mark "CYCLE_RESULT attempt=$attempt result=capture_failed frames=$frame_count rc=$stream_rc error=$ioctl_error"
		if [ "$failure_saved" -eq 0 ]; then
			failure_saved=1
			cat "$attempt_log"
			mark "FAILED_CYCLE_SNAPSHOT_BEGIN attempt=$attempt"
			cat /sys/kernel/debug/regulator/regulator_summary > "$log_dir/regulators-first-failed-cycle.txt"
			cat /sys/kernel/debug/gpio > "$log_dir/gpio-first-failed-cycle.txt"
			timeout 5 cat /sys/kernel/debug/pm_genpd/pm_genpd_summary > "$log_dir/domains-first-failed-cycle.txt" 2>&1
			{
				for state_file in /sys/kernel/debug/dri/*/state; do
					[ -r "$state_file" ] || continue
					printf '%s\n' "$state_file"
					timeout 5 cat "$state_file"
				done
			} > "$log_dir/drm-first-failed-cycle.txt" 2>&1
			{
				for state_file in /sys/kernel/debug/pinctrl/*/pinmux-pins /sys/kernel/debug/pinctrl/*/pinconf-pins; do
					[ -r "$state_file" ] || continue
					printf '%s\n' "$state_file"
					timeout 5 cat "$state_file"
				done
			} > "$log_dir/pinctrl-first-failed-cycle.txt" 2>&1
			media-ctl -d "$media_device" -p > "$log_dir/media-first-failed-cycle.txt"
			mark "FAILED_CYCLE_SNAPSHOT_END attempt=$attempt"
		fi
		if [[ "$ioctl_error" == *'(Broken pipe)'* ]]; then
			if ((consecutive_route_recoveries < 3)); then
				route_recoveries=$((route_recoveries + 1))
				consecutive_route_recoveries=$((consecutive_route_recoveries + 1))
				mark "FRONT_ROUTE_RECOVERY_BEGIN attempt=$attempt recovery=$route_recoveries consecutive=$consecutive_route_recoveries"
				media-ctl -d "$media_device" -p > "$log_dir/media-before-recovery-$route_recoveries.txt"
				configure_front
				recovery_rc=$?
				media-ctl -d "$media_device" -p > "$log_dir/media-after-recovery-$route_recoveries.txt"
				mark "FRONT_ROUTE_RECOVERY_END attempt=$attempt recovery=$route_recoveries rc=$recovery_rc"
			elif ((route_recovery_limit_reported == 0)); then
				route_recovery_limit_reported=1
				mark "FRONT_ROUTE_RECOVERY_LIMIT attempt=$attempt consecutive_limit=3"
			fi
		fi
		sleep 1
	fi
done
