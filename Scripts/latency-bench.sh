#!/usr/bin/env zsh
# Convenience wrapper around `swift run LatencyBench`.
#
# KVM Console stores its `devices.json` under
# ~/Library/Application Support/io.lyx.KVMConsole/. The bench reads it from
# there directly. Alternatively, pass `--store <path>` to point the bench
# at an exported `devices.json`.
#
# Usage: ./Scripts/latency-bench.sh <subcommand> [options...]
#   ./Scripts/latency-bench.sh list
#   ./Scripts/latency-bench.sh video --device "MacBook"
#   ./Scripts/latency-bench.sh input --device "MacBook"
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"

mkdir -p Scripts/latency-reports
swift run --package-path KVMCore -c release LatencyBench "$@"

if [[ "${1:-}" != "list" && -d Scripts/latency-reports ]]; then
  open Scripts/latency-reports
fi
