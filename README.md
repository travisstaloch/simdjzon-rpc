# simdjzon-rpc

:warning: still in early development. :warning:

A fast json-rpc implementation in [Zig](https://ziglang.org/) based on [simdjzon](https://github.com/travisstaloch/simdjzon)

Also includes a very competitive [std-json-rpc](src/std-json.zig) implementation.  See benchmarks below.

# usage
```zig
// build.zig.zon
...
    .dependencies = .{
        .@"simdjzon-rpc" = .{
            .url = "https://github.com/travisstaloch/simdjzon-rpc/archive/<commit-hash>.tar.gz",
            // add hash field here after running '$ zig build'
        },
    },
...

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

// main.zig
const simjzon_rpc = @import("simdjzon-rpc");
const stdjson_rpc = @import("std-json-rpc");
```

# [examples](examples/)

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

### bench

There are 2 benchmark scripts [bench](examples/bench.zig) and [bench-std-json](examples/bench-std-json.zig).  They are very similar.  Their engines each have 4 rpc methods and randomly choose an input json from [common](src/common.zig) 'test_cases_2'.

The following output can be reproduced by running [bench.sh](scripts/bench.sh).

### bench options
```console
$ zig build --help
...
  -Dbench-iterations=[int]     number times for benchmark to loop. default 100.
  -Dbench-summary=[bool]       whether or not to show bench timing and memory usage summary. default false.
  -Dbench-use-gpa=[bool]       whether or not to use zig's general purpose allocator.  use std.heap.c_allocator when false.  default false.
  -Dbench-validate=[bool]      whether to check that rpc output matches expected output.  default false.
...
```
### run benchmarks
```console
$ zig build bench -Dbench-iterations=30000 -Doptimize=ReleaseFast -Dbench-summary -Dbench-use-gpa=false
 reqs=30000
 time=16.78ms
req/s=1787.7K

total_bytes_allocated139.7MiB
bytes_in_use     18.6KiB
max_bytes_in_use 24.3KiB
allocs           18.44us/15 (avg 1.229us)
frees            460ns/9 (avg 51ns)
shrinks          833.799us/30000 (avg 27ns)
expands          1.72ms/59996 (avg 28ns)
total_time 2.573ms

$ zig build bench-std-json -Dbench-iterations=30000 -Doptimize=ReleaseFast -Dbench-summary -Dbench-use-gpa=false
 reqs=30000
 time=21.175ms
req/s=1416.7K

total_bytes_allocated139.7MiB
bytes_in_use     8.4KiB
max_bytes_in_use 14.1KiB
allocs           19.339us/12 (avg 1.611us)
frees            500ns/8 (avg 62ns)
shrinks          887.714us/30000 (avg 29ns)
expands          856.903us/29996 (avg 28ns)
total_time 1.764ms
```

### benchmark results

The following compares simdjzon-rpc to std-json-rpc with these options

| build mode               | allocator        |
| ------------------------ | ---------------- |
| ReleaseFast, ReleaseSafe | Gpa, C allocator |

They show similar memory usage and std-json-rpc being ~7-10% faster in 3/4 cases.  simdjzon-rpc is ~19% faster with a ReleaseFast,C Allocator combo.

#### ReleaseFast, Gpa
```console
~/.../zig/simdjzon-rpc $ zig build -Doptimize=ReleaseFast -Dbench-use-gpa -Dbench-iterations=30000
~/.../zig/simdjzon-rpc $ poop zig-out/bin/bench-std-json zig-out/bin/bench
Benchmark 1 (14 runs): zig-out/bin/bench-std-json
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           380ms ± 3.33ms     375ms …  387ms          0 ( 0%)        0%
  peak_rss           1.57MB ±    0      1.57MB … 1.57MB          0 ( 0%)        0%
  cpu_cycles          198M  ± 2.60M      194M  …  204M           0 ( 0%)        0%
  instructions        312M  ± 1.14M      311M  …  315M           0 ( 0%)        0%
  cache_references   21.8M  ±  290K     21.3M  … 22.3M           0 ( 0%)        0%
  cache_misses        187K  ± 52.7K      103K  …  287K           0 ( 0%)        0%
  branch_misses      1.41M  ± 37.8K     1.35M  … 1.47M           0 ( 0%)        0%
Benchmark 2 (13 runs): zig-out/bin/bench
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           407ms ± 2.85ms     404ms …  413ms          1 ( 8%)        💩+  7.2% ±  0.6%
  peak_rss           1.57MB ±    0      1.57MB … 1.57MB          0 ( 0%)          -  0.0% ±  0.0%
  cpu_cycles          173M  ± 1.71M      171M  …  176M           0 ( 0%)        ⚡- 12.7% ±  0.9%
  instructions        242M  ± 1.12M      240M  …  244M           0 ( 0%)        ⚡- 22.6% ±  0.3%
  cache_references   20.0M  ±  286K     19.5M  … 20.5M           0 ( 0%)        ⚡-  8.3% ±  1.0%
  cache_misses        174K  ± 54.0K     98.7K  …  265K           0 ( 0%)          -  6.7% ± 22.6%
  branch_misses      1.35M  ± 29.9K     1.28M  … 1.40M           4 (31%)        ⚡-  4.4% ±  1.9%
```

#### ReleaseFast, C allocator
```console
~/.../zig/simdjzon-rpc $ zig build -Doptimize=ReleaseFast -Dbench-use-gpa=false -Dbench-iterations=30000
~/.../zig/simdjzon-rpc $ poop zig-out/bin/bench-std-json zig-out/bin/bench
Benchmark 1 (236 runs): zig-out/bin/bench-std-json
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          21.1ms ±  354us    20.7ms … 22.9ms         21 ( 9%)        0%
  peak_rss           1.57MB ± 28.9KB    1.44MB … 1.57MB         12 ( 5%)        0%
  cpu_cycles         94.7M  ± 1.27M     93.1M  …  103M          11 ( 5%)        0%
  instructions        263M  ± 20.5K      263M  …  263M           6 ( 3%)        0%
  cache_references    237K  ±  171K      172K  … 2.02M          28 (12%)        0%
  cache_misses       6.73K  ±  990      5.66K  … 13.2K          14 ( 6%)        0%
  branch_misses       178K  ± 2.40K      172K  …  188K           2 ( 1%)        0%
Benchmark 2 (299 runs): zig-out/bin/bench
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          16.7ms ±  511us    16.2ms … 22.3ms         20 ( 7%)        ⚡- 21.0% ±  0.4%
  peak_rss           1.45MB ± 40.0KB    1.31MB … 1.57MB         29 (10%)        ⚡-  7.4% ±  0.4%
  cpu_cycles         74.0M  ± 2.01M     73.0M  … 100.0M         20 ( 7%)        ⚡- 21.8% ±  0.3%
  instructions        183M  ± 33.6K      183M  …  183M           5 ( 2%)        ⚡- 30.6% ±  0.0%
  cache_references   93.2K  ±  148K     47.3K  … 2.36M          35 (12%)        ⚡- 60.7% ± 11.4%
  cache_misses       6.10K  ±  824      5.19K  … 12.9K          13 ( 4%)        ⚡-  9.4% ±  2.3%
  branch_misses      70.3K  ± 3.29K     67.5K  …  102K          29 (10%)        ⚡- 60.5% ±  0.3%
```

#### ReleaseSafe, Gpa
```console
~/.../zig/simdjzon-rpc $ zig build -Doptimize=ReleaseSafe -Dbench-use-gpa -Dbench-iterations=30000
~/.../zig/simdjzon-rpc $ poop zig-out/bin/bench-std-json zig-out/bin/bench
Benchmark 1 (12 runs): zig-out/bin/bench-std-json
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           437ms ± 3.14ms     432ms …  442ms          0 ( 0%)        0%
  peak_rss           1.70MB ±    0      1.70MB … 1.70MB          0 ( 0%)        0%
  cpu_cycles          263M  ± 2.57M      259M  …  268M           0 ( 0%)        0%
  instructions        463M  ± 1.01M      461M  …  465M           0 ( 0%)        0%
  cache_references   34.2M  ±  387K     33.7M  … 35.2M           1 ( 8%)        0%
  cache_misses        337K  ± 72.7K      221K  …  433K           0 ( 0%)        0%
  branch_misses      1.40M  ± 33.2K     1.34M  … 1.44M           0 ( 0%)        0%
Benchmark 2 (11 runs): zig-out/bin/bench
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           481ms ± 5.92ms     476ms …  495ms          0 ( 0%)        💩+ 10.1% ±  0.9%
  peak_rss           1.68MB ± 53.0KB    1.57MB … 1.70MB          2 (18%)          -  1.4% ±  1.9%
  cpu_cycles          269M  ± 4.83M      264M  …  279M           0 ( 0%)        💩+  2.3% ±  1.3%
  instructions        400M  ± 1.79M      397M  …  403M           0 ( 0%)        ⚡- 13.6% ±  0.3%
  cache_references   31.4M  ±  851K     29.4M  … 32.8M           1 ( 9%)        ⚡-  8.4% ±  1.6%
  cache_misses        336K  ±  127K      204K  …  681K           1 ( 9%)          -  0.4% ± 26.4%
  branch_misses      1.57M  ± 33.7K     1.51M  … 1.62M           0 ( 0%)        💩+ 12.4% ±  2.1%
```

#### ReleaseSafe, C allocator
```console
~/.../zig/simdjzon-rpc $ zig build -Doptimize=ReleaseSafe -Dbench-use-gpa=false -Dbench-iterations=30000
~/.../zig/simdjzon-rpc $ poop zig-out/bin/bench-std-json zig-out/bin/bench
Benchmark 1 (186 runs): zig-out/bin/bench-std-json
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          26.7ms ±  750us    26.0ms … 34.2ms         11 ( 6%)        0%
  peak_rss           1.70MB ± 32.3KB    1.57MB … 1.70MB         12 ( 6%)        0%
  cpu_cycles          120M  ± 3.15M      118M  …  155M          10 ( 5%)        0%
  instructions        382M  ± 15.4K      382M  …  382M           8 ( 4%)        0%
  cache_references   1.09M  ±  336K      908K  … 4.23M          18 (10%)        0%
  cache_misses       8.59K  ± 4.88K     6.11K  … 57.0K          11 ( 6%)        0%
  branch_misses       167K  ± 4.64K      161K  …  221K          13 ( 7%)        0%
Benchmark 2 (174 runs): zig-out/bin/bench
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          28.8ms ±  438us    28.2ms … 31.4ms         15 ( 9%)        💩+  7.8% ±  0.5%
  peak_rss           1.69MB ± 39.0KB    1.57MB … 1.70MB         17 (10%)          -  0.3% ±  0.4%
  cpu_cycles          129M  ± 1.33M      128M  …  139M           9 ( 5%)        💩+  7.9% ±  0.4%
  instructions        302M  ± 23.8K      302M  …  302M           6 ( 3%)        ⚡- 20.8% ±  0.0%
  cache_references    416K  ±  123K      323K  … 1.33M          18 (10%)        ⚡- 61.9% ±  4.8%
  cache_misses       7.64K  ± 1.95K     5.66K  … 19.4K           8 ( 5%)        ⚡- 11.1% ±  9.0%
  branch_misses      78.0K  ± 1.94K     74.8K  … 93.3K           8 ( 5%)        ⚡- 53.2% ±  0.4%
```

# notes

* adapted from [ucall](https://github.com/unum-cloud/ucall)
* [json-rpc spec](https://www.jsonrpc.org/specification)
* related [zig-json-rpc](https://github.com/candrewlee14/zig-json-rpc/)
