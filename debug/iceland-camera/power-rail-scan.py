import argparse
import json
import subprocess
import time
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("module", type=Path)
parser.add_argument("rails", nargs="+")
parser.add_argument("--seconds", type=float, default=12)
arguments = parser.parse_args()
log_dir = Path("/var/tmp/iceland-camera-watch/current").resolve()
output_dir = log_dir / f"rail-scan-{time.monotonic_ns()}"
output_dir.mkdir()
stream_path = log_dir / "front-stream.log"
trace_marker = Path("/sys/kernel/tracing/instances/iceland-camera/trace_marker")
summary_path = Path("/sys/kernel/debug/regulator/regulator_summary")
module_dir = Path("/sys/module/iceland_power_hold")
if module_dir.exists():
    raise SystemExit("An existing hold must be reviewed before scanning")


def record(event, **fields):
    entry = {"event": event, "monotonic": time.monotonic(), **fields}
    text = json.dumps(entry)
    print(text, flush=True)
    with (output_dir / "results.jsonl").open("a") as output:
        output.write(text + "\n")
    trace_marker.write_text("POWER_RAIL_SCAN " + text + "\n")


def observe(seconds, label):
    with stream_path.open() as source:
        source.seek(0, 2)
        time.sleep(seconds)
        lines = source.read()
    (output_dir / f"{label}.stream").write_text(lines)
    frames = lines.count("result=frame_received")
    failures = lines.count("result=capture_failed")
    return frames, failures


record("begin", output_dir=str(output_dir), rails=arguments.rails)
for rail in arguments.rails:
    frames, failures = observe(3, rail + "-baseline")
    if frames or not failures:
        record("stop_baseline_not_failing", rail=rail, frames=frames, failures=failures)
        break
    (output_dir / f"{rail}-before.txt").write_text(summary_path.read_text())
    record("enable_begin", rail=rail)
    enabled = subprocess.run(["insmod", str(arguments.module.resolve()), f"rail={rail}"],
                             capture_output=True, text=True)
    record("enable_result", rail=rail, returncode=enabled.returncode,
           stderr=enabled.stderr)
    if enabled.returncode:
        break
    try:
        (output_dir / f"{rail}-held.txt").write_text(summary_path.read_text())
        frames, failures = observe(arguments.seconds, rail + "-held")
        record("held_result", rail=rail, frames=frames, failures=failures)
    finally:
        try:
            (module_dir / "parameters/release").write_text("1\n")
        except OSError as error:
            record("release_failed_stop", rail=rail, error=str(error))
            raise
        subprocess.run(["rmmod", "iceland_power_hold"], check=True)
        record("released", rail=rail)
    (output_dir / f"{rail}-after.txt").write_text(summary_path.read_text())
    after_frames, after_failures = observe(3, rail + "-released")
    record("released_result", rail=rail, frames=after_frames, failures=after_failures)
    if frames or after_frames:
        record("recovery_candidate_stop", rail=rail)
        break
record("end")
