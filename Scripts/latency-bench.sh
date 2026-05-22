#!/usr/bin/env zsh
# Convenience wrapper around `swift run LatencyBench`.
#
# Usage: ./Scripts/latency-bench.sh <subcommand> [options...]
#   ./Scripts/latency-bench.sh list
#   ./Scripts/latency-bench.sh video --device "MacBook"
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"

mkdir -p Scripts/latency-reports
swift run --package-path KVMCore -c release LatencyBench "$@"

# If we wrote any reports, point Finder at the directory.
if [[ "${1:-}" != "list" && -d Scripts/latency-reports ]]; then
  open Scripts/latency-reports
fi
