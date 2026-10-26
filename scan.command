#!/bin/zsh
cd "$(dirname "$0")"
echo "=== AirPods case lid detector (v2) ==="
echo "Open and close the case lid 3 times, slowly, a second or two apart."
echo "Watch for the '>>> LID OPENED / LID CLOSED' lines."
echo "Press ctrl-c when done."
echo
./ble-apple-scan --rssi -55 2>&1 | tee scan.log
