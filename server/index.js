const express = require("express");
const sqlite3 = require("better-sqlite3")(":memory:");
const child_process = require("child_process");

const args = process.argv.slice(2);
// TODO: stop this hacky shit (JSON options? env? sane defaults?)
console.info("Calling fuzzer with", args);
const fuzzer_process = child_process.spawn("../zig-out/bin/sus", args);

sqlite3.exec(`CREATE TABLE entries (
    entry_id      INTEGER     PRIMARY KEY                           NOT NULL,
    created_at    TIMESTAMP               DEFAULT CURRENT_TIMESTAMP NOT NULL,
    zig_version   VARCHAR(32)                                       NOT NULL,
    zls_version   VARCHAR(32)                                       NOT NULL,

    message       TEXT                                           NOT NULL,
    stderr        TEXT                                           NOT NULL
);`);

fuzzer_process.stdout.on("data", data => {
    if (!Buffer.isBuffer(data)) return;
    
    const timestamp = new Date(Number(data.readBigInt64LE()));
    const zig_version_len = data.readInt8(8);
    const zig_version = data.subarray(9, 9 + zig_version_len).toString("ascii");
    const zls_version_len = data.readInt8(9 + zig_version_len);
    const zls_version = data.subarray(10 + zig_version_len, 10 + zig_version_len + zls_version_len).toString("ascii");
    const message_len = data.readUInt16LE(10 + zig_version_len + zls_version_len);
    const message = data.subarray(12 + zig_version_len + zls_version_len, 12 + zig_version_len + zls_version_len + message_len).toString("utf8");
    const stderr_len = data.readUInt16LE(14 + zig_version_len + zls_version_len);
    const stderr = data.subarray(14 + zig_version_len + zls_version_len + message_len, 14 + zig_version_len + zls_version_len + message_len + stderr_len).toString("utf8");

    sqlite3.prepare(`
INSERT INTO entries (created_at, zig_version, zls_version, message, stderr)
VALUES (?, ?, ?, ?, ?);    
`).bind([+timestamp, zig_version, zls_version, message, stderr]).run();
});

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
