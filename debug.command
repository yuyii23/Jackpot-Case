#!/bin/zsh
cd "$(dirname "$0")"
echo "=== verbose capture — every 0x07 packet is printed ==="
echo
echo "Do this, slowly, while this runs:"
echo "  1. open the lid    2. wait 3 seconds"
echo "  3. close the lid   4. wait 3 seconds"
echo "  5. open the lid    6. wait 3 seconds"
echo
./ble-apple-scan --serve 8787 --rssi -90 --debug --verbose 2>&1 | tee debug.log
