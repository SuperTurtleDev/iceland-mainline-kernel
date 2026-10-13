#!/bin/bash
set -eu

log_dir=$1
trace_dir=$2
latency_device=/dev/cpu_dma_latency

if [ ! -e "$latency_device" ]; then
	printf 'CPU_LATENCY_HOLD_UNAVAILABLE\n' > "$trace_dir/trace_marker"
	exit 0
fi

exec 9>"$latency_device"
printf '\0\0\0\0' >&9
{
	printf 'CPU_LATENCY_HOLD_RESULT value_us=0 uptime='
	cat /proc/uptime
} | tee "$log_dir/cpu-latency-hold.log" > "$trace_dir/trace_marker"
while :; do
	sleep 60
done
