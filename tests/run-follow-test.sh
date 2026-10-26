#!/bin/zsh
# Compile the real Follower out of ble-apple-scan.swift together with the
# scenarios in follow-test.swift, and run them.
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
{ echo "import Foundation"
  sed -n '/^\/\/ MARK: - which case the page follows/,/^\/\/ MARK: - scanner/p' ble-apple-scan.swift | sed '$d'
} > "$tmp/Follower.swift"
cp tests/follow-test.swift "$tmp/main.swift"
swiftc -O "$tmp/Follower.swift" "$tmp/main.swift" -o "$tmp/follow-test" && "$tmp/follow-test"
rc=$?
rm -rf "$tmp"
exit $rc
