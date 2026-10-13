import datetime
import os
from pathlib import Path
import re
import select
import sys
import time

trace_path, output_path = sys.argv[1:]
output_dir = Path(output_path)
trace_fd = os.open(trace_path, os.O_RDONLY | os.O_NONBLOCK)
pending = b""
first_error = False
last_i2c_success = None
stream_active = False
stream_attempt = "unknown"
stream_started = None
stream_started_seen = None
no_frame_reported = False
last_frame = None
last_frame_seen = None
last_frame_stamp = 0
gap_reported = False
last_trace_flush = time.monotonic()

with (output_dir / "trace.log").open("a", buffering=262144) as trace_log, (output_dir / "timeline.log").open("a", buffering=1) as timeline_log:
    def report(event, monotonic_time, detail):
        realtime = time.time() - time.monotonic() + monotonic_time
        timestamp = datetime.datetime.fromtimestamp(realtime).astimezone().isoformat(timespec="microseconds")
        message = f"{event} monotonic={monotonic_time:.6f} realtime={timestamp} {detail}"
        print(message, file=timeline_log)
        print(message, flush=True)

    while True:
        readable, _, _ = select.select([trace_fd], [], [], 0.5)
        if readable:
            try:
                pending += os.read(trace_fd, 65536)
            except BlockingIOError:
                continue
            while b"\n" in pending:
                raw_line, pending = pending.split(b"\n", 1)
                line = raw_line.decode(errors="replace")
                print(line, file=trace_log)
                if re.search(r'(?:LOST\s+\d+\s+EVENTS|EVENTS\s+LOST)', line, re.IGNORECASE):
                    report("TRACE_LOSS", time.monotonic(), line)
                match = re.search(r"\s(\d+\.\d+):\s+(.*)", line)
                if not match:
                    continue
                event_time = float(match[1])
                event_text = match[2]
                result = re.search(r"i2c_result:.* n=(\d+) ret=(-?\d+)", event_text)
                if result:
                    if int(result[2]) == int(result[1]) and int(result[1]) > 0:
                        last_i2c_success = event_time
                    elif int(result[2]) != int(result[1]) and not first_error:
                        first_error = True
                        if last_i2c_success is None:
                            failure_window = "last_i2c_success_monotonic=none"
                        else:
                            failure_window = f"last_i2c_success_monotonic={last_i2c_success:.6f} failure_window_seconds={event_time - last_i2c_success:.6f}"
                        report("FIRST_I2C_ERROR", event_time, f"{failure_window} {event_text}")
                        trigger = output_dir / "first-i2c-error.request"
                        temporary_trigger = trigger.with_suffix(".tmp")
                        temporary_trigger.write_text(f"monotonic={event_time:.6f} {failure_window} {event_text}\n")
                        temporary_trigger.replace(trigger)
                        trace_log.flush()
                if "tracing_mark_write:" in event_text:
                    report("MARK", event_time, event_text)
                    marker = event_text.partition("tracing_mark_write:")[2].strip()
                    if re.match(r"FRONT_STREAM_BEGIN\b", marker):
                        attempt = re.search(r"\battempt=(\d+)\b", marker)
                        stream_attempt = attempt[1] if attempt else "unknown"
                        stream_active = True
                        stream_started = event_time
                        stream_started_seen = time.monotonic()
                        no_frame_reported = False
                        last_frame = None
                        last_frame_seen = None
                        last_frame_stamp = 0
                        gap_reported = False
                    elif re.match(r"(?:FRONT_STREAM_END|CYCLE_RESULT)\b", marker):
                        stream_active = False
                frame_stamp = re.search(r"timestamp\s*=\s*(\d+)", event_text)
                if stream_active and event_text.startswith("v4l2_dqbuf:") and "ERROR" not in event_text and frame_stamp and int(frame_stamp[1]) > last_frame_stamp:
                    if last_frame is None:
                        report("FIRST_FRAME", event_time, f"attempt={stream_attempt} start_monotonic={stream_started:.6f} {event_text}")
                    elif gap_reported:
                        report("FRAME_DELIVERY", event_time, f"attempt={stream_attempt} {event_text}")
                    last_frame = event_time
                    last_frame_stamp = int(frame_stamp[1])
                    last_frame_seen = time.monotonic()
                    gap_reported = False
        if time.monotonic() - last_trace_flush >= 0.1:
            trace_log.flush()
            last_trace_flush = time.monotonic()
        if stream_active:
            if last_frame_seen is None and not no_frame_reported and time.monotonic() - stream_started_seen > 3:
                report("START_NO_FRAME", stream_started, f"attempt={stream_attempt} no successful DQBUF for 3s after stream begin")
                no_frame_reported = True
            elif last_frame_seen is not None and not gap_reported and time.monotonic() - last_frame_seen > 3:
                report("FRAME_GAP", last_frame, f"attempt={stream_attempt} no successful DQBUF for 3s while stream active")
                gap_reported = True
