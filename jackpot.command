#!/bin/zsh
cd "$(dirname "$0")"
# ปิดตัวเก่าที่อาจค้างอยู่บนพอร์ตเดียวกัน ไม่งั้นจะได้โปรแกรมรุ่นเดิม
if pkill -f "ble-apple-scan --serve 8787" 2>/dev/null; then sleep 1; fi
echo "=== Jackpot Case ==="
echo "เอา AirPods ใส่เคส แล้วเปิดฝา"
echo "เบราว์เซอร์เปิดให้เอง  ctrl-c เพื่อหยุด"
echo
./ble-apple-scan --serve 8787 --open --rssi -42 2>&1 | tee jackpot.log
