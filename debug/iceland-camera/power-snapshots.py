import concurrent.futures
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time


log_dir, trace_dir = map(Path, sys.argv[1:])
snapshot_dir = log_dir / "power-snapshots"
snapshot_dir.mkdir(parents=True, exist_ok=True)
request_path = log_dir / "first-i2c-error.request"
stop = threading.Event()
output_lock = threading.Lock()
scan_lock = threading.Lock()
runtime_paths = []
runtime_scan_time = None
baseline_saved = set()
impact = (
    "Software state snapshots are not electrical measurements. Regulator reads "
    "hold regulator locks and may call hardware getters; GPIO and pinctrl reads "
    "may access hardware. Genpd/interconnect reads hold subsystem locks. Runtime "
    "path scans and reads add CPU and I/O load. No clk_summary is read."
)


def emit(event, **details):
    record = {"event": event, "mono_ns": time.monotonic_ns(), **details}
    with output_lock:
        with (log_dir / "power-snapshots.jsonl").open("a") as output:
            output.write(json.dumps(record) + "\n")


def marker(message):
    try:
        (trace_dir / "trace_marker").write_text(message + "\n")
    except OSError as error:
        emit("MARKER_FAILED", message=message, error=str(error))


def read_text(path):
    started = time.monotonic_ns()
    try:
        content = path.read_text()
        result = {"rc": 0, "text": content}
    except OSError as error:
        result = {"rc": -error.errno, "error": str(error)}
    return {"source": str(path), "begin_mono_ns": started,
            "end_mono_ns": time.monotonic_ns(), **result}


def capture(path, destination, identifier):
    marker(f"POWER_READ_BEGIN snapshot={identifier} source={path}")
    started = time.monotonic_ns()
    result = {"source": str(path), "file": destination.name,
              "begin_mono_ns": started}
    with destination.open("wb") as output:
        try:
            process = subprocess.run(["cat", str(path)], stdout=output,
                                     stderr=subprocess.STDOUT, timeout=2)
            result["rc"] = process.returncode
        except subprocess.TimeoutExpired:
            result.update(rc=124, timed_out=True)
        except OSError as error:
            result.update(rc=-error.errno, error=str(error))
    result["end_mono_ns"] = time.monotonic_ns()
    marker(f"POWER_READ_END snapshot={identifier} source={path} rc={result['rc']}")
    return result


def scan_runtime_paths(identifier):
    global runtime_paths, runtime_scan_time
    now = time.monotonic()
    scan_interval = 5 if now < 30 else 30
    if runtime_scan_time is not None and now - runtime_scan_time < scan_interval:
        return
    if not scan_lock.acquire(blocking=False):
        return
    try:
        marker(f"POWER_RUNTIME_SCAN_BEGIN snapshot={identifier}")
        started = time.monotonic_ns()
        found = []
        errors = []
        for root, directories, files in os.walk(
                "/sys/devices", onerror=lambda error: errors.append(str(error))):
            if stop.is_set():
                break
            if "power" in directories:
                candidate = Path(root) / "power/runtime_status"
                if candidate.is_file():
                    found.append(candidate)
                directories.remove("power")
        runtime_paths = sorted(found)
        runtime_scan_time = time.monotonic()
        emit("RUNTIME_PATH_SCAN", snapshot=identifier, begin_mono_ns=started,
             end_mono_ns=time.monotonic_ns(), count=len(found), errors=errors)
        marker(f"POWER_RUNTIME_SCAN_END snapshot={identifier} count={len(found)}")
    finally:
        scan_lock.release()


def snapshot(kind, request=None):
    identifier = f"{kind}-{time.monotonic_ns()}"
    destination = snapshot_dir / identifier
    destination.mkdir()
    marker(f"POWER_SNAPSHOT_BEGIN snapshot={identifier}")
    emit("SNAPSHOT_BEGIN", snapshot=identifier, kind=kind, impact=impact,
         request=request)
    sources = [
        ("genpd.txt", Path("/sys/kernel/debug/pm_genpd/pm_genpd_summary")),
        ("regulators.txt", Path("/sys/kernel/debug/regulator/regulator_summary")),
        ("interconnect.txt", Path("/sys/kernel/debug/interconnect/interconnect_summary")),
        ("gpio.txt", Path("/sys/kernel/debug/gpio")),
    ]
    for filename in ("pinmux-pins", "pinconf-pins"):
        for path in sorted(Path("/sys/kernel/debug/pinctrl").glob(f"*/{filename}")):
            sources.append((f"{path.parent.name}-{filename}.txt", path))
    for filename, path in (
        ("cmd-db.txt", Path("/sys/kernel/debug/cmd-db")),
        ("interconnect-graph.txt", Path("/sys/kernel/debug/interconnect/interconnect_graph")),
    ):
        if filename not in baseline_saved and path.exists():
            sources.append((filename, path))
    try:
        with (destination / "reads.jsonl").open("a") as metadata:
            for filename, path in sources:
                if stop.is_set():
                    break
                result = capture(path, destination / filename, identifier)
                metadata.write(json.dumps(result) + "\n")
                metadata.flush()
                if result["rc"] == 0 and filename in ("cmd-db.txt", "interconnect-graph.txt"):
                    baseline_saved.add(filename)
            scan_runtime_paths(identifier)
            marker(f"POWER_RUNTIME_READ_BEGIN snapshot={identifier}")
            started = time.monotonic_ns()
            count = 0
            with (destination / "runtime-status.jsonl").open("w") as output:
                for path in runtime_paths:
                    if stop.is_set():
                        break
                    output.write(json.dumps(read_text(path)) + "\n")
                    count += 1
            metadata.write(json.dumps({"source": "/sys/devices/**/power/runtime_status",
                                       "begin_mono_ns": started,
                                       "end_mono_ns": time.monotonic_ns(),
                                       "count": count, "interrupted": stop.is_set()}) + "\n")
            marker(f"POWER_RUNTIME_READ_END snapshot={identifier} count={count}")
    finally:
        marker(f"POWER_SNAPSHOT_END snapshot={identifier}")
        emit("SNAPSHOT_END", snapshot=identifier, interrupted=stop.is_set())


def sample_stats_loop():
    previous = {}
    profile = Path("/sys/kernel/tracing/kprobe_profile")
    while not stop.is_set():
        started = time.monotonic()
        records = []
        loss = []
        for path in sorted((trace_dir / "per_cpu").glob("cpu*/stats")):
            result = read_text(path)
            totals = {}
            for line in result.get("text", "").splitlines():
                key, separator, value = line.partition(":")
                if separator and value.strip().isdigit():
                    totals[key.strip()] = int(value.strip())
            cpu = path.parent.name
            old = previous.get(cpu, {})
            deltas = {key: value - old[key] for key, value in totals.items() if key in old}
            counters = ("overrun", "commit overrun", "dropped events", "read events")
            result.update(cpu=cpu, totals=totals, deltas=deltas,
                          counters_reset=any(deltas.get(key, 0) < 0 for key in counters))
            records.append(result)
            for key in ("overrun", "commit overrun", "dropped events"):
                delta = deltas.get(key, totals.get(key, 0))
                if delta > 0:
                    loss.append({"cpu": cpu, "counter": key, "delta": delta,
                                 "total": totals[key]})
            previous[cpu] = totals
        record = {"mono_ns": time.monotonic_ns(), "cpus": records,
                  "kprobe_profile": read_text(profile)}
        capacity = os.statvfs(log_dir)
        record["free_bytes"] = capacity.f_bavail * capacity.f_frsize
        record["trace_bytes"] = (log_dir / "trace.log").stat().st_size if (log_dir / "trace.log").exists() else 0
        with (log_dir / "trace-stats.jsonl").open("a") as output:
            output.write(json.dumps(record) + "\n")
        if loss:
            emit("TRACE_LOSS", counters=loss)
            marker("POWER_TRACE_LOSS " + json.dumps(loss, separators=(",", ":")))
            print("TRACE_LOSS " + json.dumps(loss), flush=True)
        stop.wait(max(0, 1 - (time.monotonic() - started)))


def sample_stats():
    try:
        sample_stats_loop()
    except Exception as error:
        print(f"TRACE_STATS_FAILED {error}", file=sys.stderr, flush=True)
        stop.set()


def shutdown(signum, frame):
    stop.set()


for signal_number in (signal.SIGTERM, signal.SIGINT):
    signal.signal(signal_number, shutdown)

existing_request = read_text(request_path) if request_path.exists() else None
error_seen = existing_request is not None
emit("SAMPLER_START", impact=impact, attached_existing_error=error_seen,
     trace_clock=read_text(trace_dir / "trace_clock"),
     buffer_total_size_kb=read_text(trace_dir / "buffer_total_size_kb"),
     overwrite=read_text(trace_dir / "options/overwrite"))
stats_thread = threading.Thread(target=sample_stats, name="trace-stats", daemon=True)
stats_thread.start()
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as workers:
    periodic = workers.submit(snapshot, "initial")
    error_snapshot = None
    if existing_request is not None:
        emit("ATTACHED_EXISTING_I2C_ERROR", request=existing_request)
        error_snapshot = workers.submit(snapshot, "attached-existing-error", existing_request)
    next_snapshot = time.monotonic() + 5
    while not stop.wait(0.1):
        if not error_seen and request_path.exists():
            error_seen = True
            request = read_text(request_path)
            emit("FIRST_I2C_ERROR_REQUEST", request=request)
            error_snapshot = workers.submit(snapshot, "first-i2c-error", request)
        for future in (periodic, error_snapshot):
            if future is not None and future.done() and future.exception() is not None:
                emit("SNAPSHOT_FAILED", error=str(future.exception()))
                stop.set()
        if time.monotonic() >= next_snapshot:
            next_snapshot = time.monotonic() + 5
            if periodic.done():
                periodic = workers.submit(snapshot, "periodic")
            else:
                emit("PERIODIC_SNAPSHOT_SKIPPED", reason="previous snapshot still running")
stats_thread.join(timeout=2)
emit("SAMPLER_STOP")
