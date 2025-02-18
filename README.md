# simdjzon-rpc

:warning: still in early development. :warning:

A fast json-rpc implementation in [Zig](https://ziglang.org/) based on [simdjzon](https://github.com/travisstaloch/simdjzon)

Also includes a very competitive [std-json-rpc](src/std-json.zig) implementation.  See benchmarks below.

# usage
```console
$ zig fetch --save=simdjzon-rpc git+https://github.com/travisstaloch/simdjzon-rpc#main
```
```zig
// build.zig
    // simdjzon-rpc
    const simdjzon_rpc_dep = b.dependency(
        "simdjzon-rpc",
        .{ .target = target, .optimize = optimize },
    );
    my_exe.addModule("simdjzon-rpc", simdjzon_rpc_dep.module());
    // std-json-rpc
    const stdjson_rpc_dep = b.dependency(
        "std-json-rpc",
        .{ .target = target, .optimize = optimize },
    );
    my_exe.addModule("std-json-rpc", stdjson_rpc_dep.module());
```
```zig
// main.zig
const simjzon_rpc = @import("simdjzon-rpc");
const stdjson_rpc = @import("std-json-rpc");
```

# [examples](examples/)

# Echo Server

### run and test http-echo-server
```console
$ zig build http-echo-server

listening on http://127.0.0.1:4000
```
in another terminal
```console
$ cd examples
$ python3 test.py
ok
```

# Benchmarks

There are 2 benchmark scripts [bench](examples/bench.zig) and [bench-std-json](examples/bench-std-json.zig).  They are very similar.  Their engines each have 4 rpc methods and randomly choose an input json from [common](src/common.zig) 'test_cases_2'.

The following output can be reproduced by running [bench.sh](scripts/bench.sh).

### benchmark related build steps and options
```console
$ zig build -h
#...
Steps:
  #...
  bench                        Run bench
  bench-std-json               Run bench-std-json

#...
Project-Specific Options:
  #...
  -Dbench-iterations=[int]     number times for benchmark to loop. default 100.
  -Dbench-iterations=[int]     number times for benchmark to loop. default 100.
  -Dbench-summary=[bool]       whether or not to show bench timing and memory usage summary. default false.
  -Dbench-use-gpa=[bool]       whether or not to use zig's general purpose allocator.  use std.heap.c_allocator when false.  default false.
  -Dbench-validate=[bool]      whether to check that rpc output matches expected output.  default false.
...
```
### single benchmark summary
```console
$ zig build bench -Dbench-iterations=30000 -Doptimize=ReleaseFast -Dbench-summary -Dbench-use-gpa=false

(simdjzon-rpc)
 reqs=30000
 time=16.066ms
req/s=1867.2K

-- CountingAllocator summary -- 
total_bytes_allocated   134.2MiB
bytes_in_use            17.8KiB
max_bytes_in_use        23.6KiB
allocs                  19.06us/13 (avg 1.466us)
frees                   430ns/7 (avg 61ns)
shrinks                 622.401us/30000 (avg 20ns)
expands                 2.355ms/59997 (avg 39ns)
total_time              2.997ms

```

### benchmark results

Below simdjzon-rpc to std-json-rpc with these options

| build mode               | allocator        |
| ------------------------ | ---------------- |
| ReleaseFast, ReleaseSafe | Gpa, C allocator |

These benchmarks happen at the end of [scripts/bench.sh](scripts/bench.sh).

TLDR: simdjzon-rpc is between 6%-27% faster in 3/4 cases and 5.5% slower with the ReleaseSafe/Gpa combo.  simdjzon-rpc runs 27% faster with a ReleaseFast, C Allocator combo.


#### ReleaseFast, C allocator

```console
++ zig build -Doptimize=ReleaseFast -Dbench-use-gpa=false -Dbench-iterations=30000
++ ../poop/zig-out/bin/poop -d 2000 zig-out/bin/bench-std-json zig-out/bin/bench
Benchmark 1 (93 runs): zig-out/bin/bench-std-json
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          21.2ms ±  293us    20.8ms … 22.4ms          3 ( 3%)        0%
  peak_rss           1.53MB ± 61.6KB    1.44MB … 1.57MB          0 ( 0%)        0%
  cpu_cycles         95.0M  ±  906K     93.7M  … 98.4M           3 ( 3%)        0%
  instructions        274M  ± 31.0K      274M  …  274M           2 ( 2%)        0%
  cache_references    240K  ±  109K      185K  …  747K          14 (15%)        0%
  cache_misses       6.10K  ±  436      5.66K  … 9.10K           2 ( 2%)        0%
  branch_misses       153K  ± 2.25K      149K  …  162K           2 ( 2%)        0%
Benchmark 2 (131 runs): zig-out/bin/bench
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          15.3ms ±  348us    15.0ms … 16.8ms          9 ( 7%)        ⚡- 27.8% ±  0.4%
  peak_rss           1.44MB ± 25.2KB    1.31MB … 1.44MB          5 ( 4%)        ⚡-  6.1% ±  0.8%
  cpu_cycles         67.6M  ±  594K     66.9M  … 69.9M          10 ( 8%)        ⚡- 28.9% ±  0.2%
  instructions        180M  ± 36.5K      180M  …  180M           3 ( 2%)        ⚡- 34.4% ±  0.0%
  cache_references   38.9K  ± 54.7K     21.8K  …  406K          18 (14%)        ⚡- 83.8% ±  9.1%
  cache_misses       5.58K  ±  191      5.23K  … 6.35K           2 ( 2%)        ⚡-  8.5% ±  1.4%
  branch_misses      56.5K  ±  526      55.5K  … 59.3K           4 ( 3%)        ⚡- 63.0% ±  0.3%

```


#### ReleaseFast, Gpa
```console
++ zig build -Doptimize=ReleaseFast -Dbench-use-gpa -Dbench-iterations=30000
++ ../poop/zig-out/bin/poop -d 2000 zig-out/bin/bench-std-json zig-out/bin/bench
Benchmark 1 (70 runs): zig-out/bin/bench-std-json
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          28.9ms ±  346us    28.4ms … 30.2ms          3 ( 4%)        0%
  peak_rss           1.84MB ±    0      1.84MB … 1.84MB          0 ( 0%)        0%
  cpu_cycles          129M  ±  877K      127M  …  131M           0 ( 0%)        0%
  instructions        319M  ± 74.8K      319M  …  319M           3 ( 4%)        0%
  cache_references    634K  ±  110K      561K  … 1.46M           4 ( 6%)        0%
  cache_misses       6.90K  ±  739      5.87K  … 10.0K           4 ( 6%)        0%
  branch_misses       159K  ± 2.70K      155K  …  164K           0 ( 0%)        0%
Benchmark 2 (75 runs): zig-out/bin/bench
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          26.7ms ±  292us    26.2ms … 27.7ms          3 ( 4%)        ⚡-  7.5% ±  0.4%
  peak_rss           1.70MB ±    0      1.70MB … 1.70MB          0 ( 0%)        ⚡-  7.1% ±  0.0%
  cpu_cycles          119M  ± 1.03M      118M  …  122M           3 ( 4%)        ⚡-  7.5% ±  0.2%
  instructions        246M  ± 94.8K      246M  …  246M           4 ( 5%)        ⚡- 22.9% ±  0.0%
  cache_references    318K  ±  157K      149K  … 1.08M           2 ( 3%)        ⚡- 49.8% ±  7.0%
  cache_misses       5.89K  ±  320      5.44K  … 7.10K           5 ( 7%)        ⚡- 14.6% ±  2.7%
  branch_misses      58.6K  ± 3.50K     57.0K  … 87.7K           2 ( 3%)        ⚡- 63.2% ±  0.6%

```


#### ReleaseSafe, C allocator
```console
++ zig build -Doptimize=ReleaseSafe -Dbench-use-gpa=false -Dbench-iterations=30000
++ ../poop/zig-out/bin/poop -d 2000 zig-out/bin/bench-std-json zig-out/bin/bench
Benchmark 1 (73 runs): zig-out/bin/bench-std-json
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          26.9ms ±  332us    26.3ms … 28.3ms          6 ( 8%)        0%
  peak_rss           1.57MB ± 37.7KB    1.44MB … 1.70MB          6 ( 8%)        0%
  cpu_cycles          121M  ±  873K      119M  …  124M           2 ( 3%)        0%
  instructions        367M  ± 29.2K      367M  …  368M           1 ( 1%)        0%
  cache_references   1.06M  ± 66.0K      997K  … 1.38M           5 ( 7%)        0%
  cache_misses       6.33K  ±  323      5.78K  … 7.01K           0 ( 0%)        0%
  branch_misses       141K  ± 1.96K      137K  …  147K           0 ( 0%)        0%
Benchmark 2 (80 runs): zig-out/bin/bench
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          25.2ms ±  366us    24.8ms … 27.0ms          5 ( 6%)        ⚡-  6.2% ±  0.4%
  peak_rss           1.57MB ±    0      1.57MB … 1.57MB          0 ( 0%)          +  0.2% ±  0.5%
  cpu_cycles          113M  ±  650K      113M  …  116M           3 ( 4%)        ⚡-  6.4% ±  0.2%
  instructions        291M  ± 27.8K      291M  …  291M           2 ( 3%)        ⚡- 20.9% ±  0.0%
  cache_references    370K  ± 98.0K      323K  … 1.06M           9 (11%)        ⚡- 65.2% ±  2.5%
  cache_misses       6.00K  ±  365      5.35K  … 6.84K           0 ( 0%)        ⚡-  5.2% ±  1.7%
  branch_misses      61.5K  ±  991      60.6K  … 66.7K           5 ( 6%)        ⚡- 56.6% ±  0.3%
```

#### ReleaseSafe, Gpa
```console
++ zig build -Doptimize=ReleaseSafe -Dbench-use-gpa -Dbench-iterations=30000
++ ../poop/zig-out/bin/poop -d 2000 zig-out/bin/bench-std-json zig-out/bin/bench
Benchmark 1 (52 runs): zig-out/bin/bench-std-json
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          38.6ms ±  580us    38.1ms … 41.1ms          8 (15%)        0%
  peak_rss           1.93MB ± 57.3KB    1.84MB … 1.97MB         13 (25%)        0%
  cpu_cycles          174M  ±  655K      172M  …  176M           3 ( 6%)        0%
  instructions        448M  ± 53.6K      448M  …  448M           2 ( 4%)        0%
  cache_references   1.92M  ±  458K     1.58M  … 4.00M           6 (12%)        0%
  cache_misses       8.34K  ±  890      6.89K  … 10.9K           2 ( 4%)        0%
  branch_misses       223K  ± 4.00K      214K  …  234K           0 ( 0%)        0%
Benchmark 2 (50 runs): zig-out/bin/bench
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          40.7ms ±  407us    40.2ms … 42.0ms          3 ( 6%)        💩+  5.4% ±  0.5%
  peak_rss           1.97MB ±    0      1.97MB … 1.97MB          0 ( 0%)          +  1.7% ±  0.8%
  cpu_cycles          184M  ± 1.52M      182M  …  190M           3 ( 6%)        💩+  5.9% ±  0.3%
  instructions        404M  ± 74.7K      404M  …  404M           4 ( 8%)        ⚡-  9.9% ±  0.0%
  cache_references    978K  ±  272K      721K  … 2.19M           3 ( 6%)        ⚡- 49.1% ±  7.7%
  cache_misses       7.27K  ±  592      6.42K  … 9.18K           2 ( 4%)        ⚡- 12.8% ±  3.6%
  branch_misses      90.7K  ± 4.30K     79.9K  …  104K           6 (12%)        ⚡- 59.3% ±  0.7%

```


# notes

* adapted from [ucall](https://github.com/unum-cloud/ucall)
* [json-rpc spec](https://www.jsonrpc.org/specification)
* related [zig-json-rpc](https://github.com/candrewlee14/zig-json-rpc/)
