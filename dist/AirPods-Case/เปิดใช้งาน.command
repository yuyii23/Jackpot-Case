#!/bin/zsh
# AirPods Case: เปิดหน้าเช็กแบตเตอรี่ AirPods จากการเปิด/ปิดฝาเคส
# ดับเบิลคลิกไฟล์นี้เพื่อเริ่ม  ปิดหน้าต่าง Terminal หรือกด Control+C เพื่อหยุด

# ระยะจับสัญญาณเคส (dBm) เลขติดลบน้อย = ต้องวางเคสใกล้ Mac มาก
#   -42  วางเคสชิดเครื่อง ไม่จับ AirPods ของคนอื่นที่อยู่ใกล้ ๆ
#   -55  วางห่างได้มากขึ้น ลองค่านี้ถ้าเปิดฝาแล้วหน้าเว็บไม่ตอบสนอง
RSSI=${RSSI:--42}
PORT=${PORT:-8787}

# ดูจากมือถือ: เปลี่ยน 0 เป็น 1 แล้ว Terminal จะแสดงลิงก์สำหรับมือถือที่ต่อ Wi-Fi เดียวกัน
# ลิงก์มีรหัสเฉพาะ และเปลี่ยนทุกครั้งที่เปิดโปรแกรม  ค่า 0 = เปิดได้เฉพาะบน Mac เครื่องนี้ (ปลอดภัยกว่า)
PHONE=${PHONE:-0}

cd "$(dirname "$0")"

# ไฟล์ที่ดาวน์โหลดมาถูก macOS ติดป้ายกักกันไว้ เอาออกครั้งเดียวให้ตัวสแกนเนอร์รันได้
xattr -dr com.apple.quarantine . 2>/dev/null
chmod +x ble-apple-scan 2>/dev/null

# ปิดตัวเก่าที่อาจค้างอยู่บนพอร์ตเดียวกัน ไม่งั้นจะได้โปรแกรมรุ่นเดิมหรือพอร์ตชนกัน
if pkill -f "ble-apple-scan --serve $PORT" 2>/dev/null; then sleep 1; fi

clear
echo "=== AirPods Case ==="
echo "วางเคส AirPods ไว้ใกล้ Mac แล้วเปิดฝา"
echo "เบราว์เซอร์จะเปิด http://localhost:$PORT ให้เอง"
extra=()
if [[ $PHONE == 1 ]]; then
  extra=(--lan)
  echo "โหมดมือถือเปิดอยู่: ลิงก์สำหรับมือถือ (phone on the same Wi-Fi) จะแสดงด้านล่าง"
fi
echo "หยุด: กด Control+C หรือปิดหน้าต่างนี้"
echo

./ble-apple-scan --serve "$PORT" --open --rssi "$RSSI" "${extra[@]}" 2>&1 | tee scan.log
