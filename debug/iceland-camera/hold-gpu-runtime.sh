#!/bin/bash
set -u

log_dir=$1
trace_dir=$2
gpu_device=/sys/bus/platform/devices/3d00000.gpu
deadline=$((SECONDS + 60))
exec > "$log_dir/gpu-runtime-hold.log" 2>&1

mark()
{
	printf '%s\n' "$*" > "$trace_dir/trace_marker"
	printf '%s uptime=' "$*"
	cat /proc/uptime
}

mark GPU_PM_HOLD_WAIT
while ((SECONDS < deadline)); do
	if [ -L "$gpu_device/driver" ] && [ -r "$gpu_device/power/runtime_status" ]; then
		status=$(cat "$gpu_device/power/runtime_status")
		if [[ "$status" == active || "$status" == suspended ]]; then
			original=$(cat "$gpu_device/power/control")
			mark "GPU_PM_HOLD_REQUEST original=$original status=$status"
			if ! printf 'on\n' > "$gpu_device/power/control"; then
				mark GPU_PM_HOLD_FAILED
				exit 1
			fi
			control=$(cat "$gpu_device/power/control")
			status=$(cat "$gpu_device/power/runtime_status")
			mark "GPU_PM_HOLD_RESULT control=$control status=$status"
			[[ "$control" == on && "$status" == active ]] || exit 1
			exit 0
		fi
	fi
	sleep 0.1
done
mark GPU_PM_HOLD_TIMEOUT
exit 1
