export PATH="$(pwd)/repos/zig:$PATH"
zig build -Doptimize=ReleaseSafe
./zig-out/bin/sus
