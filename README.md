# simdjzon-rpc

:warning: still in early development. :warning:

A fast json-rpc implementation in [Zig](https://ziglang.org/) based on [simdjzon](https://github.com/travisstaloch/simdjzon)

# examples
[http-echo-server](examples/http-echo-server)

### run and test http-echo-server
```console
$ cd examples/http-echo-server/
$ $ zig build run

listening on http://127.0.0.1:4000
```
in another terminal
```console
$ cd examples/http-echo-server/
$ python3 test.py
ok
```

# notes

* adapted from [ucall](https://github.com/unum-cloud/ucall)
* [json-rpc spec](https://www.jsonrpc.org/specification)

