# sus

ZLS fuzzing tooling.

```bash
git clone https://github.com/ziglang/zig repos/zig
git clone https://github.com/zigtools/zls repos/zls
zig build -- repos/zls/zig-out/bin/zls[.exe]
# example with 'markov training dir'
zig build run -- --zls-path repos/zls/zig-out/bin/zls[.exe] --mode markov -- --training-dir repos/zig/src
```

# usage

```console
Usage:   sus [options] --mode [mode] -- <mode specific arguments>

Example: sus --mode markov        -- --training-dir  /path/to/folder/containing/zig/files/
         sus --mode best_behavior -- --source_dir   ~/path/to/folder/containing/zig/files/

General Options:
  --help                Print this help and exit
  --output-as-dir       Output fuzzing results as directories (default: false)
  --zls-path [path]     Specify path to ZLS executable
  --mode [mode]         Specify fuzzing mode - one of { best_behavior, markov }
  --cycles-per-gen      How many times to fuzz a random feature before regenerating a new file. (default: 25)

For a listing of mode specific options, use 'sus --mode [mode] -- --help'.
For a listing of build options, use 'zig build --help'.
```

# .env
if a .env file is present at project root or next to the exe, the following keys will be used as default values.  
```console
zls_path=~/repos/zls/zig-out/bin/zls
mode=markov
markov_training_dir=~/repos/zig/src
```

this allows the project to be run with no args:
```console
zig build run
```
