# sus

zls fuzzing tooling.

```bash
git clone https://github.com/ziglang/zig repos/zig
git clone https://github.com/zigtools/zls repos/zls
zig build -- repos/zls/zig-out/bin/zls[.exe]
# example with 'markov training dir'
zig build run -- --zls-path repos/zls/zig-out/bin/zls[.exe] --mode markov -- --training-dir repos/zig/test/
```

# usage

```console
Usage:  sus [options] --mode [mode] -- <mode specific arguments>
        sus [options] --mode [mode] -- <mode specific arguments>

General Options:
  --help                Print this help and exit
  --zls-path [path]     Specify path to ZLS executable
  --mode [mode]         Specify fuzzing mode - one of { best_behavior, markov }
  --deflate             Compress log files with DEFLATE
  --cycles-per-gen      How many times to fuzz a random feature before regenerating a new file. (default: 25)

For a listing of mode specific options, use 'sus --mode [mode] -- --help'.
For a listing of build options, use 'zig build --help'.
```

# .env
if a .env file is present at project root or next to the exe, the following keys will be used as default values.  
```console
zls_path=repos/zls/zig-out/bin/zls
mode=markov
markov_training_dir=repos/zig/test/behavior
```

this allows the project to be run with no args:
```console
zig build run
```
