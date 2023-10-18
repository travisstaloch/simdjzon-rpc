set -e

zig build test

echo
echo "--- release-fast+c-allocator ---"
echo
zig build bench -Doptimize=ReleaseFast -Dbench-summary
zig build bench-std-json -Doptimize=ReleaseFast -Dbench-summary
echo
echo "--- release-fast+gpa ---"
echo
zig build bench -Doptimize=ReleaseFast -Dbench-summary -Dbench-use-gpa
zig build bench-std-json -Doptimize=ReleaseFast -Dbench-summary -Dbench-use-gpa

echo
echo "--- Running benchmarks... ---"
echo

poop=../poop/zig-out/bin/poop
args=-Dbench-iterations=30000

set -x

zig build -Doptimize=ReleaseFast -Dbench-use-gpa=false $args
$poop zig-out/bin/bench-std-json zig-out/bin/bench
zig build -Doptimize=ReleaseFast -Dbench-use-gpa $args
$poop zig-out/bin/bench-std-json zig-out/bin/bench

zig build -Doptimize=ReleaseSafe -Dbench-use-gpa=false $args
$poop zig-out/bin/bench-std-json zig-out/bin/bench
zig build -Doptimize=ReleaseSafe -Dbench-use-gpa $args
$poop zig-out/bin/bench-std-json zig-out/bin/bench
