#!/bin/zsh
# สร้างไฟล์ ble-apple-scan ใหม่จาก source บนเครื่องนี้
# ต้องมี Xcode Command Line Tools (ติดตั้งด้วย: xcode-select --install)
#   zsh source/build.sh
#
# พยายาม build ทั้ง Apple Silicon (macOS 11+) และ Intel (macOS 13+)
# ถ้าเครื่องมือของเครื่องนี้ทำได้แค่แบบเดียว ก็จะได้แบบนั้นแบบเดียว

cd "$(dirname "$0")"
out=../ble-apple-scan
tmp=$(mktemp -d)
built=()

for spec in arm64:11 x86_64:13; do
  arch=${spec%%:*}
  min=${spec##*:}
  if swiftc -O -target "$arch-apple-macos$min" ble-apple-scan.swift -o "$tmp/scan-$arch" \
       -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist 2>/dev/null; then
    built+=("$tmp/scan-$arch")
    echo "สร้างแบบ $arch ได้ (macOS $min ขึ้นไป)"
  else
    echo "ข้ามแบบ $arch (เครื่องมือของเครื่องนี้สร้างไม่ได้)"
  fi
done

if (( ${#built} == 0 )); then
  echo "build ไม่สำเร็จ ข้อความ error:"
  swiftc ble-apple-scan.swift -o "$tmp/scan" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
  exit 1
fi

lipo -create "${built[@]}" -output "$out"
codesign -s - -f -i local.ble-apple-scan "$out" 2>/dev/null
rm -rf "$tmp"
lipo -info "$out"
echo "เสร็จแล้ว ดับเบิลคลิก เปิดใช้งาน.command ได้เลย"
