#!/usr/bin/env zsh
# Convenience wrapper around `swift run LatencyBench`.
#
# KVM Console is sandboxed, so its `devices.json` lives inside the app
# container. To let the bench read it, grant the terminal running this
# script Full Disk Access (System Settings → Privacy & Security → Full
# Disk Access). Alternatively, pass `--store <path>` to point the bench
# at an exported `devices.json`.
#
# Usage: ./Scripts/latency-bench.sh <subcommand> [options...]
#   ./Scripts/latency-bench.sh list
#   ./Scripts/latency-bench.sh video --device "MacBook"
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"

mkdir -p Scripts/latency-reports
swift run --package-path KVMCore -c release LatencyBench "$@"

if [[ "${1:-}" != "list" && -d Scripts/latency-reports ]]; then
  open Scripts/latency-reports
fi
