# sus

zls fuzzing tooling.

```bash
git clone https://github.com/ziglang/zig repos/zig
git clone --recurse-submodules https://github.com/zigtools/zls repos/zls
rm repos/zig/build.zig
Get-ChildItem -Path "repos/zig/test" build.zig -Recurse | Remove-Item
zig build run -- repos/zls/zig-out/bin/zls[.exe] [mode]
# example with 'markov input dir' arg
zig build run -Dblock-len=8 -- repos/zls/zig-out/bin/zls markov repos/zig/test/
```
