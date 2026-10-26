# Game — AirPods lid as controller

**กำลังทำ:** สแกนเนอร์หายตอนแอป Claude รีสตาร์ต (รันอยู่ใน terminal tab ของแอป) เปิดใหม่ผ่าน jackpot.command ใน Terminal.app แล้ว
**ผล test ล่าสุด:** 14:31 open jackpot.command → สแกนเนอร์ pid 44561 รันใน Terminal.app, หน้าเว็บ 200, WebSocket ต่อได้ (Connected)

## บันทึก
- 2026-10-23: ตัวกันซ้ำเดิมใช้เวลา 0.4s ทำให้ปิดเร็ว (~300ms) หลังเปิดถูกทิ้ง → เปลี่ยนเป็นเทียบ flag เปิด/ปิดกับสถานะที่แจ้งเกมไปแล้ว (per device)
- สอง pod นับ counter เพี้ยนกันได้ 1 ค่าเป็นนาที ๆ จึงเทียบด้วย flag ไม่ใช่ทั้ง byte
- game.html ทำตาม m.action จาก server ตรง ๆ; ข้อความ hello/seen ส่งสถานะที่เกมควรรู้ (told) ไม่ใช่ของ pod ที่รายงาน
- build: swiftc -O ble-apple-scan.swift -o ble-apple-scan -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist && codesign -s - -f ble-apple-scan
- 05:28: ผู้ใช้ลองแล้ว "ยังมีปัญหา" แต่ log เป็นของ process เก่า → ต้อง ctrl-c แล้วรัน jackpot.command ใหม่ทุกครั้งหลัง build
- game.html: เพิ่ม `revealed` — % แบตแสดงหลัง action opened ครั้งแรกเท่านั้น
- game.html: closeCase ล้างการ์ดแบตเป็น — และ revealed=false; เปิดใหม่ค่อยโชว์อีก
- 2026-10-23 UI: ธีม Floral Luxury; ภาพเคสตัดจาก reference เป็น JPEG+alpha mask (ui-src/) ฝังเป็น data URI เพราะ server เสิร์ฟแค่ "/"; template อยู่ ui-src/game.template.html (แทน __CASE_IMG__/__MASK__)
- การ์ดใน DOM ยังเรียง L,R,C (script ใช้ index) แต่ CSS order ให้ CASE ขึ้นก่อน; วงกลมลอย qL/qR/qC อัปเดตใน setCard
- ค่าว่างในการ์ด/วงกลม/ชื่ออุปกรณ์/byte ดิบ = ช่องเปล่า (ไม่ใช้ —); .pct มี min-height กันการ์ดยุบ
- ฟอนต์: Kanit ทั้งหน้า (เลิกใช้ Cormorant Garamond); หัวข้อ weight 300, ตัวเลขแบต 600
- เอฟเฟกต์เปิดฝา (spray/fxFrame ใน canvas#fx): parts = flower/petal/pearl, flies = ผีเสื้อ (สูงสุด 30 ตัว), ลดจำนวนเมื่อ prefers-reduced-motion
- เคสเป็น 3 ชั้นใน .casebox: .body (body-mask.png จาก ui-src/mkbody.swift, ตัดเหนือขอบ y168), .full (ภาพเต็มตอนเปิด), .lid (ฝาปิด CSS ใช้ลายจากตัวเคส, rotateX พับลง)
- build: python3 -I ui-src/build.py (แทน __CASE_IMG__/__MASK__/__BODY_MASK__ เป็น CSS var บน :root)
- universal: arm64 ขั้นต่ำ macOS 11, x86_64 ขั้นต่ำ macOS 13 (Command Line Tools ตัวนี้ไม่มี compat lib x86_64 สำหรับ <13)
- รันสแกนเนอร์จาก Bash tool ไม่ได้ (exit 134 ไม่มีสิทธิ์ Bluetooth) ต้องทดสอบผ่าน Terminal panel
- คู่มือออนไลน์: https://claude.ai/artifact/FXnA9rUkUjgjBFiGweH7aa (ตรงกับ dist/AirPods-Case/วิธีติดตั้ง.txt)
- 2026-10-23: ย้ายไป Trash 21 รายการ (กู้คืนได้ด้วย Put Back); เก็บ debug.command+debug.log (ข้อมูล replay test), scan.command (ตัวตรวจฝา)
- Follower: lid event ยึดหน้าเว็บได้ถ้าเคสปัจจุบันปิด/ยังไม่ firm/เงียบ>8s; seen จากเคสอื่นถูกข้าม; เคสเปิดที่เงียบ>8s ส่งต่อให้เคสถัดไป (รองรับ address rotation)
- jackpot.command หายไปหลังล้างไฟล์ ผู้ใช้ขอให้สร้างกลับมาแล้ว (08:09)
- ช่องโหว่ (แก้แล้ว 1-3, ข้อ 4 แก้ไม่ได้): 1) parseFrame crash จาก len 64-bit ติดลบ/ล้น 2) readFrames buffer ไม่จำกัด 3) ไม่มี auth/Origin check + listen *:8787 4) BLE advert ปลอมได้
- --lan: ฟังทุก interface แต่เครื่องอื่นต้องมี ?k=<รหัสต่อรอบ>; ไม่มี --lan ใช้ requiredInterfaceType=.loopback + เช็ก endpoint ซ้ำ; WS ต้องมาที่ /ws และ Origin ตรง Host
- เวอร์ชันเดโมบนเว็บ: ผู้ใช้ยกเลิก ไม่ได้สร้าง
- ถ้ารันสแกนเนอร์ใน terminal tab ของแอป Claude มันจะตายเมื่อแอปรีสตาร์ต ใช้ jackpot.command (Terminal.app) สำหรับใช้งานจริง
