set -e

zig build test

echo
echo "--- release-fast+c-allocator ---"
echo
args="-Doptimize=ReleaseFast -Dbench-summary"
zig build bench $args
zig build bench-std-json $args
echo
echo "--- release-fast+gpa ---"
echo
args="-Doptimize=ReleaseFast -Dbench-summary -Dbench-use-gpa"
zig build bench $args
zig build bench-std-json $args

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
