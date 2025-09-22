const express = require("express");
const sqlite3 = require("better-sqlite3")(":memory:");
const child_process = require("child_process");
const axios = require("axios").default;
const fs = require("fs");
const path = require("path");

function getHostZigName() {
    let os = process.platform;
    if (os == "darwin") os = "macos";
    if (os == "win32") os = "windows";
    let arch = process.arch;
    if (arch == "ia32") arch = "x86";
    if (arch == "x64") arch = "x86_64";
    if (arch == "arm64") arch = "aarch64";
    if (arch == "ppc") arch = "powerpc";
    if (arch == "ppc64") arch = "powerpc64le";
    return `${os}-${arch}`;
}

function getZigDownloadUrl(builtWithZigVersion) {
    return `https://ziglang.org/builds/zig-${getHostZigName()}-${builtWithZigVersion}.${process.platform === "win32" ? "zip" : "tar.xz"}`;
}

async function checkAndUpdateZigAndZls() {
    const index = (await axios.get("https://zigtools-releases.nyc3.digitaloceanspaces.com/zls/index.json", {
        responseType: "json",
    })).data;
    const latest = index.versions[index.latest];

    const zigExePath = path.join(__dirname, "zig_install", `zig${process.platform === "win32" ? ".exe" : ""}`);

    var doWeNeedToInstallNewZig = true;
    if (fs.existsSync(zigExePath)) {
        const versionResult = child_process.spawnSync(zigExePath, ["version"]);
        doWeNeedToInstallNewZig = versionResult.stdout.toString("ascii").trim() !== latest.builtWithZigVersion;
    }

    if (doWeNeedToInstallNewZig) {
        console.log("Installing new Zig version", latest.builtWithZigVersion);
        fs.rmSync(path.join(__dirname, "zig_install"), {
            force: true,
            recursive: true,
        });
        fs.mkdirSync(path.join(__dirname, "zig_install"));

        const tarball = (await axios.get(getZigDownloadUrl(latest.builtWithZigVersion), {
            responseType: "arraybuffer"
        })).data;

        const untar_result = child_process.spawnSync("tar", ["-xJf", "-", "-C", path.join(__dirname, "zig_install"), "--strip-components=1"], {
            input: tarball
        });

        if (untar_result.status !== 0) throw "Failed to untar";
    }

    if (!fs.existsSync(path.join(__dirname, "zls_repo"))) {
        const clone_result = child_process.spawnSync("git", ["clone", "https://github.com/zigtools/zls", "zls_repo"]);
        if (clone_result.status !== 0) throw "Failed to clone";
    }

    const checkout_result = child_process.spawnSync("git", ["checkout", latest.commit], {
        cwd: path.join(__dirname, "zls_repo"),
        stdio: ["ignore", "inherit", "inherit"]
    });
    if (checkout_result.status !== 0) throw "Failed to checkout";

    const build_result = child_process.spawnSync(zigExePath, ["build"], {
        cwd: path.join(__dirname, "zls_repo"),
        stdio: ["ignore", "inherit", "inherit"]
    });
    if (build_result.status !== 0) throw "Failed to build";

    commit_hash = latest.commit;
}

// TODO: handle multiple queued messages

var commit_hash;
/**
 * @type {child_process.ChildProcess | undefined}
 */
var fuzzer_process;
var remaining_length = 0;
var received_data = [];

async function updateAllAndFuzz() {
    if (fuzzer_process) {
        fuzzer_process.kill("SIGKILL");
    }

    await checkAndUpdateZigAndZls();

    fuzzer_process = child_process.spawn("../zig-out/bin/sus", ["--rpc"], {
        stdio: ["pipe", "pipe", "ignore"],
        env: {
            zig_path: path.join(__dirname, "zig_install", `zig${process.platform === "win32" ? ".exe" : ""}`),
            zls_path: path.join(__dirname, "zls_repo", "zig-out", "bin", `zls${process.platform === "win32" ? ".exe" : ""}`),
            cycles_per_gen: "250",
            mode: "markov",
            markov_training_dir: path.join(__dirname, "zig_install", "lib", "std"),
            ...process.env
        }
    });

    fuzzer_process.stdout.on("data", data => {
        if (!Buffer.isBuffer(data)) throw "expected buffer";
    
        if (remaining_length === 0) {
            remaining_length = data.readUInt32LE();
    
            const d = data.subarray(4);
            received_data.push(d);
            remaining_length -= d.byteLength;
        } else {
            remaining_length -= data.byteLength;
            received_data.push(data);
        }
    
        if (remaining_length === 0) {
            handleData(Buffer.concat(received_data));
            received_data = [];
        }
    
        if (remaining_length < 0) {
            console.error(remaining_length);
            throw "too much data";
        }
    });
}

sqlite3.exec(`CREATE TABLE entries (
    entry_id      INTEGER     PRIMARY KEY                           NOT NULL,
    created_at    TIMESTAMP               DEFAULT CURRENT_TIMESTAMP NOT NULL,
    zig_version   VARCHAR(32)                                       NOT NULL,
    zls_version   VARCHAR(32)                                       NOT NULL,
    zls_commit    VARCHAR(40)                                       NOT NULL,

    principal     TEXT                                           NOT NULL,
    message       TEXT                                           NOT NULL,
    stderr        TEXT                                           NOT NULL
);`);

/**
 * @param {Buffer} data 
 */
function handleData(data) {
    var offset = 0;
    const timestamp = new Date(Number(data.readBigInt64LE()));
    offset += 8;

    const zig_version_len = data.readInt8(offset);
    offset += 1;
    const zig_version = data.subarray(offset, offset + zig_version_len).toString("ascii");
    offset += zig_version_len;

    const zls_version_len = data.readInt8(offset);
    offset += 1;
    const zls_version = data.subarray(offset, offset + zls_version_len).toString("ascii");
    offset += zls_version_len;

    const principal_len = data.readUInt32LE(offset);
    offset += 4;
    const principal = data.subarray(offset, offset + principal_len).toString("utf8");
    offset += principal_len;

    const message_len = data.readUInt16LE(offset);
    offset += 2;
    const message = data.subarray(offset, offset + message_len).toString("utf8");
    offset += message_len;

    const stderr_len = data.readUInt16LE(offset);
    offset += 2;
    const stderr = data.subarray(offset, offset + stderr_len).toString("utf8");
    offset += stderr_len;

    sqlite3.prepare(`
INSERT INTO entries (created_at, zig_version, zls_version, zls_commit, principal, message, stderr)
VALUES (?, ?, ?, ?, ?, ?, ?);
`).bind([+timestamp, zig_version, zls_version, commit_hash, principal, message, stderr]).run();
}

const app = express();
app.set("views", __dirname);

app.get("/", (req, res) => {
    res.render("index.ejs", {
        entries: sqlite3.prepare("SELECT * from entries ORDER BY created_at DESC").all(),
    });
});

app.listen(3000, () => {
    console.log("Server listening @ http://localhost:3000");
});

updateAllAndFuzz();

setInterval(() => {
    updateAllAndFuzz();
}, 60_000);
