#!/bin/bash
set -euo pipefail

stream_pid=$(pgrep -f '^(/bin/)?bash /var/tmp/iceland-camera-tools/stream.sh')
test "$(wc -w <<< "$stream_pid")" -eq 1
kill -STOP "$stream_pid"
trap 'kill -CONT "$stream_pid"' EXIT
sleep 1
media-ctl -d /dev/media0 -r
media-ctl -d /dev/media0 -l '"msm_csiphy5":1 -> "msm_csid0":0 [1], "msm_csid0":1 -> "msm_vfe0_rdi0":0 [1]'
for entity in 'sc820cs 0-0010' msm_csiphy5 msm_csid0 msm_vfe0_rdi0; do
	media-ctl -d /dev/media0 -V "\"$entity\":0 [fmt:SBGGR10_1X10/3264x2448 field:none]"
done
media-ctl -d /dev/media0 -V '"msm_csid0":1 [fmt:SBGGR10_1X10/3264x2448 field:none]'
video_device=$(media-ctl -d /dev/media0 -e msm_vfe0_video0)
v4l2-ctl -d "$video_device" --set-fmt-video=width=3264,height=2448,pixelformat=pBAA
