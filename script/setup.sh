# Install Zig
tarball_url=$(curl https://ziglang.org/download/index.json | jq '.master | .["x86_64-linux"] | .tarball' -r)
wget $tarball_url -O repos/zig.tar.xz
rm -rf repos/zig
tar -xf repos/zig.tar.xz --directory repos
mv repos/zig-linux* repos/zig

export PATH="$(pwd)/repos/zig:$PATH"

# Install zls
rm -rf repos/zls
git clone https://github.com/zigtools/zls repos/zls
cd repos/zls
zig build
cd ../..

# Pull latest fuzzer
git pull
zig build -Doptimize=ReleaseSafe
