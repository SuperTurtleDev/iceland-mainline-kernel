import argparse
import json
import subprocess
import time
from pathlib import Path

from gi.repository import Gio


parser = argparse.ArgumentParser()
parser.add_argument("sensor", choices=("Light", "Accelerometer", "Proximity"))
parser.add_argument("--cycles", type=int, default=2)
parser.add_argument("--seconds", type=float, default=15)
parser.add_argument("--snapshot-script", default="pmic-clock-read.py")
arguments = parser.parse_args()
connection = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
log_dir = Path("/var/tmp/iceland-camera-watch/current").resolve()
output_dir = log_dir / f"claim-{arguments.sensor}-{time.monotonic_ns()}"
output_dir.mkdir()
trace_marker = Path("/sys/kernel/tracing/instances/iceland-camera/trace_marker")


def record(event, **fields):
    entry = {"event": event, "sensor": arguments.sensor,
             "monotonic": time.monotonic(), **fields}
    text = json.dumps(entry)
    print(text, flush=True)
    with (output_dir / "results.jsonl").open("a") as output:
        output.write(text + "\n")
    trace_marker.write_text("SENSOR_CLAIM_TEST " + text + "\n")


def request(action):
    record(action + "_begin")
    connection.call_sync("net.hadess.SensorProxy", "/net/hadess/SensorProxy",
                         "net.hadess.SensorProxy", action + arguments.sensor,
                         None, None, Gio.DBusCallFlags.NONE, 10000, None)
    record(action + "_done")


def snapshot(label):
    with (output_dir / f"{label}.pmic").open("w") as output:
        subprocess.run(
            ["python3", str(Path("/var/tmp/iceland-camera-tools") / arguments.snapshot_script)],
            stdout=output, check=True)


def observe(label, seconds):
    snapshot(label)
    with (log_dir / "front-stream.log").open() as source:
        source.seek(0, 2)
        time.sleep(seconds)
        lines = source.read()
    (output_dir / f"{label}.stream").write_text(lines)
    if "Broken pipe" in lines:
        raise RuntimeError("Media routing changed; this sensor test is invalid")
    record(label, frames=lines.count("result=frame_received"),
           failures=lines.count("result=capture_failed"))
    snapshot(label + "-end")


record("begin", owner=connection.get_unique_name(), output_dir=str(output_dir))
observe("baseline", 3)
for cycle in range(arguments.cycles):
    request("Claim")
    try:
        observe(f"held-{cycle}", arguments.seconds)
    finally:
        request("Release")
    observe(f"released-{cycle}", 5)
record("end")
