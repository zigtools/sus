# sus

zls fuzzing tooling.

```bash
git clone https://github.com/ziglang/zig repos/zig
git clone --recurse-submodules https://github.com/zigtools/zls repos/zls
rm repos/zig/build.zig
zig build run -- repos/zls/zig-out/bin/zls[.exe] [mode]
```