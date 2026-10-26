#!/bin/zsh
# Compile the real Wire rules out of ble-apple-scan.swift together with the
# checks in security-test.swift, and run them.
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
{ echo "import Foundation"
  sed -n '/^\/\/ MARK: - websocket framing and access rules/,/^\/\/ MARK: - websocket + http server/p' ble-apple-scan.swift | sed '$d'
} > "$tmp/Wire.swift"
cp tests/security-test.swift "$tmp/main.swift"
swiftc -O "$tmp/Wire.swift" "$tmp/main.swift" -o "$tmp/security-test" && "$tmp/security-test"
rc=$?
rm -rf "$tmp"
exit $rc
