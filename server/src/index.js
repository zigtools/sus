const fs = require("fs");
const path = require("path");
const fflate = require("fflate");
const crypto = require("crypto");
const express = require("express");

function hash(data) {
    return crypto.createHash("md5").update(data).digest("hex");
}

const app = express();

app.use(express.static("static"));

const savedLogsPath = path.join(__dirname, "../..", "saved_logs");

const panicRegex = /panic:(?:[^]*\n?)*/gm;
const crashLocationRegex = /(.*.zig):(\d*):(\d*)/;

let logData = [];
let logGroups = new Map();
let logMap = new Map();

function stream2buffer(stream) {
    return new Promise((resolve, reject) => {
        const _buf = [];

        stream.on("data", (chunk) => _buf.push(chunk));
        stream.on("end", () => resolve(Buffer.concat(_buf)));
        stream.on("error", (err) => reject(err));
    });
} 

function populateStderrData(log) {
    const stderr = new TextDecoder("utf-8").decode(fflate.inflateSync(fs.readFileSync(path.join(savedLogsPath, log.name, "stderr.log"))));

    let match = stderr.match(panicRegex);
    if (!match) {
        log.panic = "No summary available";
        log.summary = "No summary available";
        return;
    }

    const lines = match[0].split("\n");
    const cl = lines[1].match(crashLocationRegex);

    log.panic = match[0];

    if (cl) {
        log.summary = `In ${path.relative(path.join(__dirname, "../.."), cl[1])}:${cl[2]}:${cl[3]}; \`${lines[2].trim()}\``;
    } else {
        log.panic = "No summary available";
        log.summary = "No summary available"
        return;
    }
}

function populateVersionData(log) {
    const info = fs.readFileSync(path.join(savedLogsPath, log.name, "info")).toString();
    log.version = {
        zig: info.split("\n")[0].split(":")[1].trim(),
        zls: info.split("\n")[1].split(":")[1].trim(),
    }
}

function populateLogGroups(log) {
    const h = hash(log.summary);
    const g = logGroups.get(h);
    if (g)
        g.push(log);
    else
        logGroups.set(h, [log]);
    logMap.set(log.name, {});
}

function updateLogDataIndividual(log) {
    let l = {
        name: log,
        date: new Date(+log.split("-")[1]),
    };

    populateStderrData(l);
    populateVersionData(l);
    populateLogGroups(l);

    logData.unshift(l);
}

function updateLogData() {
    logData = [];
    logGroups = new Map();
    logMap = new Map();

    let ld = fs.readdirSync(savedLogsPath).map(log => ({
        name: log,
        date: new Date(+log.split("-")[1]),
    })).sort((a, b) => b.date - a.date);

    ld.map(populateStderrData);
    ld.map(populateVersionData);
    ld.map(populateLogGroups);
    logData = ld;
}

updateLogData();
console.log("Ready!");

fs.watch(savedLogsPath, {}, (ev, filename) => {
    console.log(`${filename}: ${ev}`);

    if (logMap.has(filename)) return;

    updateLogDataIndividual(filename);
});

app.get("/", (req, res) => {
    res.render("index.ejs", {
        logData,
        groups: [...logGroups]
    });
});

app.get("/group/:group", (req, res) => {
    const group = req.params.group;

    if (!logGroups.has(group)) return res.status(404).end("404");

    res.render("group.ejs", {
        group,
        groupLogs: logGroups.get(group)
    });
});

app.get("/log/:log/:kind", (req, res) => {
    // Prevent OWASP / \ injection attack (is there a safer way to do this?)
    const log = path.basename(req.params.log);
    const logDir = path.join(savedLogsPath, log);
    const kind = req.params.kind;

    if (!fs.existsSync(logDir) || !["stderr", "stdin", "stdout", "principal.zig"].includes(kind)) return res.status(404).end("404");

    res.contentType("text");

    if (kind === "principal.zig") {
        fs.createReadStream(path.join(logDir, "principal.zig")).pipe(res);
        return;
    }

    res.setHeader("Content-Encoding", "deflate");
    fs.createReadStream(path.join(logDir, kind + ".log")).pipe(res);
});

app.listen(1313, "127.0.0.1");
