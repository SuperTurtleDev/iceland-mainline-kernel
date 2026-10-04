#!/bin/sh
# pd-boost.sh - event-driven USB PD fast-charge state machine (MIT)
#
# States: idle -> wake/query -> negotiate -> poll(5s) -> terminate -> idle
# PD_MODE=fixed : request a fixed PDO (PD_TARGET_MV) and hold it
# PD_MODE=pps   : request a PD 3.0 APDO operating point (PD_PPS_MV/MA)
#                 and re-request it every poll (PD keepalive, spec limit
#                 is 10 s; we use the 5 s poll, vendor reference uses 3 s)
# Termination: SOC >= PD_STOP_SOC, temp >= PD_STOP_TEMP, status change,
# or charger removal -> rmmod (restores the 5 V baseline).

LOCK=/run/pd-boost.lock
P=/sys/module/charge_boost_lite/parameters
U=/sys/class/power_supply/qcom-battmgr-usb
B=/sys/class/power_supply/qcom-battmgr-bat
MODE="${PD_MODE:-fixed}"
TARGET_MV="${PD_TARGET_MV:-9000}"
FINAL_ICL_UA="${PD_FINAL_ICL_UA:-3000000}"
PPS_MV="${PD_PPS_MV:-5500}"
PPS_MA="${PD_PPS_MA:-2000}"
STOP_SOC="${PD_STOP_SOC:-90}"
STOP_TEMP="${PD_STOP_TEMP:-430}"

log() { logger -t pd-boost "$*"; echo "pd-boost: $*"; }

exec 9>"$LOCK" || exit 1
flock -n 9 || exit 0

# ---- wake -------------------------------------------------------------
[ "$(cat $U/online 2>/dev/null)" = 1 ] || { log "wake: no charger, idle"; exit 0; }
[ -d "$P" ] || modprobe charge_boost_lite apply=0 || { log "module load failed"; exit 1; }

# ---- query ------------------------------------------------------------
i=0
while [ $i -lt 15 ]; do
    echo 1 > $P/check 2>/dev/null
    t=$(cat $P/pd_type)
    [ "$t" = 6 ] || [ "$t" = 8 ] && break
    sleep 1
    i=$((i+1))
done
t=$(cat $P/pd_type)
if [ "$t" != 6 ] && [ "$t" != 8 ]; then
    log "query: no PD contract (type=$t), 5V baseline, idle"
    rmmod charge_boost_lite 2>/dev/null
    exit 0
fi
log "query: PD contract type=$t mode=$MODE"

# ---- negotiate --------------------------------------------------------
echo 500000 > $P/curr_uv
sleep 1

if [ "$MODE" = pps ]; then
    # APDO operating point; the request itself enters PPS mode
    echo $PPS_MV > $P/pps_mv
    echo $PPS_MA > $P/pps_ma
    sleep 2
    v=$(cat $U/voltage_now)
    lo=$(( (PPS_MV - 1500) * 1000 ))
    hi=$(( (PPS_MV + 1000) * 1000 ))
    if [ "$v" -ge "$lo" ] && [ "$v" -le "$hi" ]; then
        echo $FINAL_ICL_UA > $P/curr_uv
        log "negotiate: PPS engaged ${PPS_MV}mV/${PPS_MA}mA vbus=$v"
    else
        log "negotiate: PPS failed (vbus=$v), fallback fixed PDO $TARGET_MV"
        MODE=fixed
    fi
fi

if [ "$MODE" = fixed ]; then
    n=0
    while [ $n -lt 3 ]; do
        echo $TARGET_MV > $P/pdo_mv
        sleep 2
        v=$(cat $U/voltage_now)
        [ "$v" -ge 7500000 ] && break
        n=$((n+1))
    done
    if [ "$v" -lt 7500000 ]; then
        log "negotiate: PDO $TARGET_MV not available (vbus=$v), 5V baseline"
        rmmod charge_boost_lite
        exit 1
    fi
    echo $FINAL_ICL_UA > $P/curr_uv
    log "negotiate: fixed PDO ${TARGET_MV}mV engaged vbus=$(cat $U/voltage_now)"
fi

# ---- poll (5 s): gates + PPS keepalive --------------------------------
while :; do
    sleep 5
    if [ "$(cat $U/online 2>/dev/null)" != 1 ]; then
        log "poll: charger gone -> idle"; break
    fi
    soc=$(cat $B/capacity)
    temp=$(cat $B/temp)
    status=$(cat $B/status)
    if [ "$soc" -ge "$STOP_SOC" ]; then
        log "poll: SOC $soc% >= $STOP_SOC% -> PD off, idle"; break
    fi
    if [ "$temp" -ge "$STOP_TEMP" ]; then
        log "poll: temp high ($temp) -> PD off, idle"; break
    fi
    if [ "$status" != "Charging" ]; then
        log "poll: status=$status -> PD off, idle"; break
    fi
    v=$(cat $U/voltage_now)
    if [ "$v" -lt 4500000 ] || [ "$v" -gt 12000000 ]; then
        log "poll: vbus out of range ($v) -> PD off, idle"; break
    fi
    if [ "$MODE" = pps ]; then
        # PD keepalive: re-request the APDO operating point
        echo $PPS_MV > $P/pps_mv 2>/dev/null
        echo $PPS_MA > $P/pps_ma 2>/dev/null
    fi
done

# ---- terminate --------------------------------------------------------
rmmod charge_boost_lite 2>/dev/null
exit 0
