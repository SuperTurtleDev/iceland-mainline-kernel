#!/bin/bash
set -eu

trace_dir=/sys/kernel/tracing/instances/iceland-camera
boot_id=$(cat /proc/sys/kernel/random/boot_id)
log_dir=/var/tmp/iceland-camera-watch/$boot_id
child_pids=()
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
clock_events=(clk_enable clk_enable_complete clk_disable clk_disable_complete
	clk_prepare clk_prepare_complete clk_unprepare clk_unprepare_complete
	clk_set_rate clk_set_rate_complete clk_set_parent clk_set_parent_complete)
rpmh_events=(rpmh_send_msg rpmh_tx_done)
mkdir -p "$trace_dir" "$log_dir/event-formats"
ln -sfn "$log_dir" /var/tmp/iceland-camera-watch/current
echo 0 > "$trace_dir/tracing_on"
echo mono > "$trace_dir/trace_clock"
echo 16384 > "$trace_dir/buffer_size_kb"

enable_event()
{
	local event_path=$1 enabled format_dir
	[ -f "$event_path/enable" ] || return 0
	read -r enabled < "$event_path/enable"
	[ "$enabled" = 1 ] || echo 1 > "$event_path/enable"
	format_dir="$log_dir/event-formats/${event_path#"$trace_dir/events/"}"
	if [ ! -f "$format_dir/format" ]; then
		mkdir -p "$format_dir"
		cat "$event_path/format" > "$format_dir/format"
		cat "$event_path/filter" > "$format_dir/filter"
	fi
}

snapshot_file()
{
	local source_path=$1 output_path=$2
	printf 'SNAPSHOT_BEGIN file=%s\n' "${output_path##*/}" > "$trace_dir/trace_marker"
	{
		printf 'SOURCE %s\nUPTIME_BEGIN ' "$source_path"
		cat /proc/uptime
		printf 'REALTIME_BEGIN '
		date --iso-8601=ns
		timeout 5 cat "$source_path" || printf 'READ_FAILED status=%s\n' "$?"
		printf '\nUPTIME_END '
		cat /proc/uptime
	} > "$output_path" 2>&1
	printf 'SNAPSHOT_END file=%s\n' "${output_path##*/}" > "$trace_dir/trace_marker"
}

for event_dir in "$trace_dir"/events/i2c/*; do
	[ -f "$event_dir/filter" ] || continue
	echo 'adapter_nr == 0' > "$event_dir/filter"
	enable_event "$event_dir"
done
python3 "$script_dir/power-events.py" "$trace_dir" "$log_dir"
for event_dir in "$trace_dir"/events/gpio/*; do
	enable_event "$event_dir"
done
for event in "${clock_events[@]}"; do
	enable_event "$trace_dir/events/clk/$event"
done
for event in "${rpmh_events[@]}"; do
	enable_event "$trace_dir/events/rpmh/$event"
done
for event in dpu_enc_mode_set dpu_enc_enable dpu_enc_disable dpu_crtc_enable dpu_crtc_disable dpu_enc_frame_done_timeout dpu_enc_underrun_cb; do
	for event_dir in "$trace_dir"/events/*/"$event"; do
		[ -f "$event_dir/enable" ] || continue
		enable_event "$event_dir"
	done
done
cleanup()
{
	echo 0 > "$trace_dir/tracing_on"
	{
		for stats_file in "$trace_dir"/per_cpu/cpu*/stats; do
			printf '%s\n' "$stats_file"
			cat "$stats_file"
		done
		cat /sys/kernel/tracing/kprobe_profile
	} > "$log_dir/trace-stats-final.txt" 2>&1 || true
	kill "${child_pids[@]}" 2>/dev/null || true
	wait || true
	if [ -f "$trace_dir/events/iceland_power/enable" ]; then
		echo 0 > "$trace_dir/events/iceland_power/enable"
	fi
	for function in gpi_process_events gpi_create_i2c_tre geni_i2c_clk_map_idx; do
		printf 'func %s -p\n' "$function" > /sys/kernel/debug/dynamic_debug/control
	done
}
trap cleanup EXIT
trap 'exit 0' TERM INT

journalctl -b -n all -f -o short-monotonic --no-pager > "$log_dir/journal.log" &
child_pids+=("$!")
dmesg --follow --time-format=raw > "$log_dir/dmesg.log" &
child_pids+=("$!")
python3 "$(dirname "$0")/timeline.py" "$trace_dir/trace_pipe" "$log_dir" &
child_pids+=("$!")
echo 1 > "$trace_dir/tracing_on"
echo MONITOR_READY > "$trace_dir/trace_marker"
logger -t iceland-camera-watch "MONITOR_READY boot=$boot_id logs=$log_dir"
if [ -f "$script_dir/gpu-runtime-hold" ]; then
	bash "$script_dir/hold-gpu-runtime.sh" "$log_dir" "$trace_dir" &
	child_pids+=("$!")
fi
if [ -f "$script_dir/cpu-latency-hold" ]; then
	bash "$script_dir/hold-cpu-latency.sh" "$log_dir" "$trace_dir" &
	child_pids+=("$!")
fi
python3 "$script_dir/power-snapshots.py" "$log_dir" "$trace_dir" &
child_pids+=("$!")
if [ "${1:-}" = --capture ]; then
	bash "$(dirname "$0")/boot-capture.sh" &
	child_pids+=("$!")
fi
if [ -n "${NOTIFY_SOCKET:-}" ]; then
	systemd-notify --ready
fi
uname -a > "$log_dir/kernel.txt"
cat /sys/kernel/debug/regulator/regulator_summary > "$log_dir/regulators-initial.txt" 2>&1 || true
cat /sys/kernel/debug/gpio > "$log_dir/gpio-initial.txt" 2>&1 || true
cat "$trace_dir/trace_clock" > "$log_dir/trace-clock.txt"

(
	for attempt in {1..600}; do
		for snapshot in cmd-db:cmd-db pm_genpd/pm_genpd_summary:genpd; do
			source_path="/sys/kernel/debug/${snapshot%:*}"
			output_path="$log_dir/${snapshot#*:}-initial.txt"
			[ ! -f "$output_path" ] && [ -r "$source_path" ] || continue
			snapshot_file "$source_path" "$output_path"
		done
		for state_file in /sys/kernel/debug/dri/*/state; do
			[ -f "$state_file" ] || continue
			drm_dir=${state_file%/state}
			output_path="$log_dir/drm-${drm_dir##*/}-initial.txt"
			[ ! -f "$output_path" ] || continue
			snapshot_file "$state_file" "$output_path"
		done
		sleep 0.1
	done
) &
child_pids+=("$!")

(
	for attempt in {1..600}; do
		for group in i2c; do
			for event_dir in "$trace_dir/events/$group"/*; do
				[ -f "$event_dir/enable" ] || continue
				read -r enabled < "$event_dir/enable"
				[ "$enabled" = 1 ] && continue
				case "$group" in
					i2c) echo 'adapter_nr == 0' > "$event_dir/filter" ;;
				esac
				enable_event "$event_dir"
			done
		done
		for event in "${clock_events[@]}"; do
			enable_event "$trace_dir/events/clk/$event"
		done
		for event in "${rpmh_events[@]}"; do
			enable_event "$trace_dir/events/rpmh/$event"
		done
		if ((attempt % 10 == 0)); then
			python3 "$script_dir/power-events.py" "$trace_dir" "$log_dir"
		fi
		for event in dpu_enc_mode_set dpu_enc_enable dpu_enc_disable dpu_crtc_enable dpu_crtc_disable dpu_enc_frame_done_timeout dpu_enc_underrun_cb; do
			for event_dir in "$trace_dir"/events/*/"$event"; do
				[ -f "$event_dir/enable" ] || continue
				enable_event "$event_dir"
			done
		done
		sleep 0.1
	done
) &
child_pids+=("$!")

while sleep 1; do
	{
		printf 'UPTIME '
		cat /proc/uptime
		for device in 0-0010 0-0036 0-000c; do
			printf '%s ' "$device"
			cat "/sys/bus/i2c/devices/$device/power/runtime_status" 2>/dev/null || true
		done
		ps -eo pid,ppid,stat,comm | grep -E 'pipewire|wireplumber|snapshot|v4l2-ctl|gnome-shell|gdm-session|libcamera|cheese' || true
		fuser /dev/video* /dev/v4l-subdev* /dev/snd/pcm* 2>&1 || true
	} >> "$log_dir/owners.log"
done
