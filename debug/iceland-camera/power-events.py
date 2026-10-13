import json
import os
from pathlib import Path
import struct
import sys
import time


trace_dir, log_dir = map(Path, sys.argv[1:])
trace_root = Path('/sys/kernel/tracing')
output_dir = log_dir / 'power-coverage'
output_dir.mkdir(exist_ok=True)
errors = []
enabled = []
missing = []


def enable_event(event_dir):
    if not (event_dir / 'enable').exists():
        missing.append(str(event_dir.relative_to(trace_dir)))
        return
    try:
        if (event_dir / 'filter').read_text().strip() not in ('none', '0'):
            (event_dir / 'filter').write_text('0\n')
        if (event_dir / 'enable').read_text().strip() != '1':
            (event_dir / 'enable').write_text('1\n')
        relative = event_dir.relative_to(trace_dir / 'events')
        saved = log_dir / 'event-formats' / relative
        saved.mkdir(parents=True, exist_ok=True)
        (saved / 'format').write_text((event_dir / 'format').read_text())
        (saved / 'filter').write_text((event_dir / 'filter').read_text())
        enabled.append(str(relative))
    except OSError as error:
        errors.append(f'{event_dir}: {error}')


for group in ('regulator', 'rpm', 'clk', 'rpmh', 'interconnect', 'gpio', 'spmi'):
    event_dirs = sorted((trace_dir / 'events' / group).glob('*/enable'))
    if not event_dirs:
        missing.append(f'group:{group}')
    for enable_path in event_dirs:
        enable_event(enable_path.parent)

selected = {
    'qcom_aoss': ('aoss_send', 'aoss_send_done'),
    'qcom_scm': ('scm_smc_request', 'scm_smc_done', 'scm_waitq_sleep',
                 'scm_waitq_resume', 'scm_waitq_get_wq_ctx'),
    'drm_msm_gpu': ('msm_gpu_suspend', 'msm_gpu_resume', 'msm_gpu_freq_change',
                    'msm_gmu_freq_change'),
    'power': ('device_pm_callback_start', 'device_pm_callback_end',
              'suspend_resume', 'wakeup_source_activate', 'wakeup_source_deactivate',
              'psci_domain_idle_enter', 'psci_domain_idle_exit'),
    'devfreq': ('devfreq_frequency',),
    'regmap': ('regmap_reg_write', 'regmap_bulk_write', 'regmap_hw_write_start',
               'regmap_hw_write_done', 'regcache_sync', 'regmap_cache_only',
               'regmap_cache_bypass'),
}
for group, events in selected.items():
    for event in events:
        enable_event(trace_dir / 'events' / group / event)


def kernel_build_id():
    notes = Path('/sys/kernel/notes').read_bytes()
    offset = 0
    while offset + 12 <= len(notes):
        name_size, value_size, note_type = struct.unpack_from('<III', notes, offset)
        offset += 12
        name = notes[offset:offset + name_size].rstrip(b'\0')
        offset += (name_size + 3) & ~3
        value = notes[offset:offset + value_size]
        offset += (value_size + 3) & ~3
        if name == b'GNU' and note_type == 3:
            return value.hex()
    return None


try:
    build_id = kernel_build_id()
except OSError as error:
    build_id = None
    errors.append(f'kernel build ID: {error}')

layout_matches = build_id == '1dd4d3b789aab5be5c98495c6e99ea640253867e'
domain_args = 'domain=$arg1:symbol'
regulator_args = 'consumer=$arg1:x64'
clock_args = 'clock=$arg1:x64'
pinctrl_args = 'controller=$arg1:x64 state=$arg2:x64'
if layout_matches:
    domain_args += ' name=+0(+1160($arg1)):string'
    regulator_args += ' supply=+0(+80($arg1)):string'
    clock_args += ' name=+0(+0(+0($arg1))):string'
    pinctrl_args += ' state_name=+0(+16($arg2)):string'

probes = {
    'gdsc_enable': domain_args,
    'gdsc_disable': domain_args,
    'gdsc_gx_disable': domain_args,
    'gdsc_set_hwmode': domain_args + ' device=$arg2:x64 mode=$arg3:u32',
    'gdsc_poll_status': 'gdsc=$arg1:symbol wanted=$arg2:u32',
    'rpmhpd_power_on': domain_args,
    'rpmhpd_power_off': domain_args,
    'rpmhpd_set_performance_state': domain_args + ' state=$arg2:u32',
    'regulator_set_mode': regulator_args + ' mode=$arg2:u32',
    'regulator_set_load': regulator_args + ' load_ua=$arg2:s32',
    'regulator_force_disable': regulator_args,
    'pinctrl_select_state': pinctrl_args,
    'reset_control_assert': 'reset=$arg1:x64',
    'reset_control_deassert': 'reset=$arg1:x64',
    'reset_control_reset': 'reset=$arg1:x64',
    'gpiod_set_value_cansleep': 'descriptor=$arg1:x64 value=$arg2:s32',
    'pmic_gpio_set': 'chip=$arg1:x64 pin=$arg2:u32 value=$arg3:s32',
    'pmic_gpio_config_set': 'controller=$arg1:x64 pin=$arg2:u32 configs=$arg3:x64 count=$arg4:u32',
    'pmic_gpio_set_mux': 'controller=$arg1:x64 function=$arg2:u32 pin=$arg3:u32',
    'qcom_reset_assert': 'controller=$arg1:x64 index=$arg2:u64',
    'qcom_reset_deassert': 'controller=$arg1:x64 index=$arg2:u64',
    'rpmh_regulator_vrm_set_mode': 'regulator=$arg1:x64 mode=$arg2:u32',
    'clk_prepare': clock_args,
    'clk_enable': clock_args,
    'clk_set_rate': clock_args + ' rate=$arg2:u64',
    'clk_set_parent': clock_args + ' parent=$arg2:x64',
    'rpmh_write': 'device=$arg1:x64 state=$arg2:u32 commands=$arg3:x64 count=$arg4:u32',
    'rpmh_write_async': 'device=$arg1:x64 state=$arg2:u32 commands=$arg3:x64 count=$arg4:u32',
    'rpmh_write_batch': 'device=$arg1:x64 state=$arg2:u32 commands=$arg3:x64 counts=$arg4:x64',
    'rpmh_flush': 'driver=$arg1:x64',
}
symbols = set()
with Path('/proc/kallsyms').open() as symbol_file:
    for line in symbol_file:
        fields = line.split()
        if len(fields) >= 3:
            symbols.add(fields[2])

definitions = []
existing_definitions = {}
for line in (trace_root / 'kprobe_events').read_text().splitlines():
    fields = line.split()
    if fields:
        existing_definitions[fields[0].partition(':')[2]] = fields
for function, arguments in probes.items():
    if function not in symbols:
        missing.append(f'probe:{function}')
        continue
    for kind, suffix, fetch in (('p', 'enter', arguments),
                                ('r128', 'exit', 'ret=$retval:s32')):
        event = f'{function}_{suffix}'
        definition = f'{kind}:iceland_power/{event} {function} {fetch}'
        event_dir = trace_dir / 'events' / 'iceland_power' / event
        try:
            if event_dir.exists() and existing_definitions.get(f'iceland_power/{event}') != definition.split():
                errors.append(f'probe definition mismatch: {event}; existing={existing_definitions.get(f"iceland_power/{event}")}')
                continue
            if not event_dir.exists():
                probe_fd = os.open(trace_root / 'kprobe_events', os.O_WRONLY | os.O_APPEND)
                try:
                    os.write(probe_fd, (definition + '\n').encode())
                finally:
                    os.close(probe_fd)
            definitions.append(definition)
            enable_event(event_dir)
        except OSError as error:
            errors.append(f'{definition}: {error}')

report = {
    'monotonic': time.monotonic(),
    'kernel_build_id': build_id,
    'verified_dwarf_layout': layout_matches,
    'layout_source': 'matching vmlinux DWARF via gdb; no offsets used on other build IDs',
    'enabled': enabled,
    'missing': missing,
    'errors': errors,
    'probe_definitions': definitions,
    'limits': ['AP requests and API results, not measured rail voltages',
               'hardware/firmware autonomous power gating may have no AP event',
               'RPMh sleep/wake records program TCS, not the later firmware execution',
               'probe enter/exit pairing uses task PID and nesting',
               'probe overhead can change timing'],
}
report_path = output_dir / 'latest.json'
previous = json.loads(report_path.read_text()) if report_path.exists() else {}
if any(previous.get(field) != report[field]
       for field in ('enabled', 'missing', 'errors', 'kernel_build_id')):
    record = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    (output_dir / f'{time.monotonic_ns()}.json').write_text(record)
    print(f'POWER_COVERAGE enabled={len(enabled)} missing={len(missing)} errors={len(errors)}', flush=True)
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
