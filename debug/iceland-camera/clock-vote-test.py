import argparse
import json
import subprocess
import time
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("module", type=Path)
parser.add_argument("clock_ids", nargs="+", type=int)
parser.add_argument("--seconds", type=float, default=15)
arguments = parser.parse_args()
log_dir = Path("/var/tmp/iceland-camera-watch/current").resolve()
output_dir = log_dir / f"clock-vote-{time.monotonic_ns()}"
output_dir.mkdir()
stream_path = log_dir / "front-stream.log"
trace_marker = Path("/sys/kernel/tracing/instances/iceland-camera/trace_marker")
if Path("/sys/module/iceland_clock_hold").exists():
    raise SystemExit("An existing clock hold must be reviewed before testing")


def record(event, **fields):
    entry = {"event": event, "monotonic": time.monotonic(), **fields}
    text = json.dumps(entry)
    print(text, flush=True)
    with (output_dir / "results.jsonl").open("a") as output:
        output.write(text + "\n")
    trace_marker.write_text("CLOCK_VOTE_TEST " + text + "\n")


def observe(seconds, label):
    with stream_path.open() as source:
        source.seek(0, 2)
        time.sleep(seconds)
        lines = source.read()
    (output_dir / f"{label}.stream").write_text(lines)
    if "Broken pipe" in lines:
        raise RuntimeError("Media routing changed; this clock test is invalid")
    return lines.count("result=frame_received"), lines.count("result=capture_failed")


def snapshot(label):
    captured = subprocess.run(
        ["python3", "/var/tmp/iceland-camera-tools/pmic-clock-read.py"],
        capture_output=True, text=True, check=True)
    (output_dir / f"{label}.pmic").write_text(captured.stdout)


record("begin", output_dir=str(output_dir), clock_ids=arguments.clock_ids)
for clock_id in arguments.clock_ids:
    label = str(clock_id)
    frames, failures = observe(3, label + "-baseline")
    record("baseline", clock_id=clock_id, frames=frames, failures=failures)
    if frames or not failures:
        record("stop_baseline_not_failing", clock_id=clock_id)
        break
    snapshot(label + "-before")
    record("enable_begin", clock_id=clock_id)
    enabled = subprocess.run(
        ["insmod", str(arguments.module.resolve()), f"clock_id={clock_id}"],
        capture_output=True, text=True)
    record("enable_result", clock_id=clock_id, returncode=enabled.returncode,
           stderr=enabled.stderr)
    if enabled.returncode:
        break
    try:
        snapshot(label + "-held")
        frames, failures = observe(arguments.seconds, label + "-held")
        record("held_result", clock_id=clock_id, frames=frames, failures=failures)
    finally:
        subprocess.run(["rmmod", "iceland_clock_hold"], check=True)
        record("released", clock_id=clock_id)
    snapshot(label + "-after")
    after_frames, after_failures = observe(5, label + "-released")
    record("released_result", clock_id=clock_id, frames=after_frames,
           failures=after_failures)
    if frames or after_frames:
        record("recovery_candidate_stop", clock_id=clock_id)
        break
record("end")
