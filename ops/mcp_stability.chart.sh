# Loaded by Netdata charts.d.plugin.
# shellcheck shell=bash

mcp_stability_update_every=30
mcp_stability_priority=91000
mcp_stability_metrics_file=/run/mcp-stability.metrics

mcp_stability_get() {
    [ -r "$mcp_stability_metrics_file" ] || return 1
    # The file is atomically written by a root-owned collector and is numeric-only.
    # shellcheck disable=SC1090
    . "$mcp_stability_metrics_file"

    : "${mcp_oracle_connected:=0}" "${mcp_context_engine_up:=0}"
    : "${mcp_active_sessions:=0}" "${mcp_session_max:=64}" "${mcp_session_pressure_pct:=0}"
    : "${mcp_jxser_standard_connected:=0}" "${mcp_jxnative_connected:=0}"
    : "${mcp_cap_evictions:=0}" "${mcp_session_recoveries:=0}" "${mcp_transport_closed:=0}"
    : "${mcp_oracle_tool_errors_5m:=0}" "${mcp_oracle_tool_timeouts_5m:=0}"
    : "${mcp_oracle_tool_p95_ms:=0}" "${mcp_jxser_tool_p95_ms:=0}" "${mcp_jxnative_tool_p95_ms:=0}"
    return 0
}

mcp_stability_check() {
    mcp_stability_get
}

mcp_stability_create() {
    cat <<EOF
CHART mcp_stability.health '' 'Connector Health' 'status' mcp stability line $((mcp_stability_priority)) $mcp_stability_update_every '' '' 'mcp'
DIMENSION oracle 'Oracle MCP' absolute 1 1
DIMENSION context_engine 'Context Engine' absolute 1 1
DIMENSION jxser_standard 'jxser_standard' absolute 1 1
DIMENSION jxnative 'jxnative' absolute 1 1
CHART mcp_stability.session_pressure '' 'Session Pressure' '%' mcp stability area $((mcp_stability_priority + 1)) $mcp_stability_update_every '' '' 'mcp'
DIMENSION pressure 'Pressure' absolute 1 1
DIMENSION warning 'Warning 75%' absolute 1 1
DIMENSION critical 'Critical 90%' absolute 1 1
CHART mcp_stability.events '' 'Stability Events' 'events' mcp stability line $((mcp_stability_priority + 2)) $mcp_stability_update_every '' '' 'mcp'
DIMENSION cap_evictions 'Cap evictions' absolute 1 1
DIMENSION recoveries 'Recoveries' absolute 1 1
DIMENSION transport_closed 'Transport closed' absolute 1 1
DIMENSION tool_errors 'Tool errors (5m)' absolute 1 1
DIMENSION tool_timeouts 'Tool timeouts (5m)' absolute 1 1
CHART mcp_stability.latency '' 'Connector Latency p95 (5m)' 'ms' mcp stability line $((mcp_stability_priority + 3)) $mcp_stability_update_every '' '' 'mcp'
DIMENSION oracle 'Oracle tools' absolute 1 1
DIMENSION jxser_standard 'jxser_standard' absolute 1 1
DIMENSION jxnative 'jxnative' absolute 1 1
EOF
    return 0
}

mcp_stability_update() {
    mcp_stability_get || return 1
    cat <<EOF
BEGIN mcp_stability.health $1
SET oracle = $mcp_oracle_connected
SET context_engine = $mcp_context_engine_up
SET jxser_standard = $mcp_jxser_standard_connected
SET jxnative = $mcp_jxnative_connected
END
BEGIN mcp_stability.session_pressure $1
SET pressure = $mcp_session_pressure_pct
SET warning = 75
SET critical = 90
END
BEGIN mcp_stability.events $1
SET cap_evictions = $mcp_cap_evictions
SET recoveries = $mcp_session_recoveries
SET transport_closed = $mcp_transport_closed
SET tool_errors = $mcp_oracle_tool_errors_5m
SET tool_timeouts = $mcp_oracle_tool_timeouts_5m
END
BEGIN mcp_stability.latency $1
SET oracle = $mcp_oracle_tool_p95_ms
SET jxser_standard = $mcp_jxser_tool_p95_ms
SET jxnative = $mcp_jxnative_tool_p95_ms
END
EOF
    return 0
}
