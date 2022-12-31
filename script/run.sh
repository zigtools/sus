export PATH="$(pwd)/repos/zig:$PATH"
zig build -Drelease-fast
./zig-out/bin/sus
