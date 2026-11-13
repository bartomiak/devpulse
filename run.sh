#!/usr/bin/env bash
# Builds and (re)starts the app
set -euo pipefail
cd "$(dirname "$0")"

./build.sh "${1:-debug}"
pkill -x SysMonitor 2>/dev/null || true
open build/SysMonitor.app
