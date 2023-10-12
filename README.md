# simdjzon-rpc

:warning: still in early development. :warning:

A fast json-rpc implementation in [Zig](https://ziglang.org/) based on [simdjzon](https://github.com/travisstaloch/simdjzon)

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
```console
$ zig build bench -Dbench-iterations=30000 -Doptimize=ReleaseFast
 reqs=30000
 time=370.264ms
req/s=81.0K

$ zig build bench-zig-json-rpc -Dbench-iterations=30000 -Doptimize=ReleaseFast
 reqs=30000
 time=980.139ms
req/s=30.6K
```

# notes

* adapted from [ucall](https://github.com/unum-cloud/ucall)
* [json-rpc spec](https://www.jsonrpc.org/specification)
* related [zig-json-rpc](https://github.com/candrewlee14/zig-json-rpc/)
