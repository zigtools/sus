const fs = require("fs");
const path = require("path");
const express = require("express");

const app = express();

app.use(express.static("static"));

const savedLogsPath = path.join(__dirname, "../..", "saved_logs");

const panicRegex = /panic:(?:[^]*\n?)*/gm;
const crashLocationRegex = /(.*.zig):(\d*):(\d*)/;

let logData = [];
let logGroups = [];
let logMap = new Map();

function populateStderrData(log) {
    const stderr = fs.readFileSync(path.join(savedLogsPath, log.name, "stderr.log")).toString();

    let match = stderr.match(panicRegex);
    if (!match) {
        log.summary = "No summary available"
        return;
    }

    const lines = match[0].split("\n");
    const cl = lines[1].match(crashLocationRegex);

    if (cl) {
        log.summary = `In ${path.relative(path.join(__dirname, "../.."), cl[1])}:${cl[2]}:${cl[3]}; \`${lines[2].trim()}\``;
    } else {
        log.summary = "No summary available"
        return;
    }
}

function updateLogData() {
    let ld = fs.readdirSync(savedLogsPath).map(log => ({
        name: log,
        date: new Date(+log.split("-")[1]),
    })).sort((a, b) => b.date - a.date);

    ld.map(populateStderrData);
    logData = ld;

    ld.map((_, i) => logMap.set(_.name, i));
}

updateLogData();

app.get("/", (req, res) => {
    res.render("index.ejs", {
        logs: logData,
    });
});

app.get("/log/:log", (req, res) => {
    const log = path.basename(req.params.log);
    const logDir = path.join(savedLogsPath, log);

    const err = fs.readFileSync(path.join(logDir, "stderr.log")).toString();
    const related = relations.find(_ => {
        for (const p of _) {
            if (p.log.name === log) return true;
        }
        return false;
    });

    res.render("info.ejs", {
        logs: getLogs(),
        log: logInfo(log),
        err: err.match(panicRegex)[0],
        related
    });
});

app.get("/log/:log/:kind", (req, res) => {
    // Prevent OWASP / \ injection attack (is there a safer way to do this?)
    const log = path.basename(req.params.log);
    const logDir = path.join(savedLogsPath, log);
    const kind = req.params.kind;

    if (!fs.existsSync(logDir) || !["stderr", "stdin", "stdout"].includes(kind)) return res.status(404).end("404");

    res.contentType("text");
    res.end(fs.readFileSync(path.join(logDir, kind + ".log")).toString());
});

app.listen(80);
