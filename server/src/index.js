const fs = require("fs");
const path = require("path");
const express = require("express");

const app = express();

app.use(express.static("static"));

const savedLogsPath = path.join(__dirname, "../..", "saved_logs");

const panicRegex = /thread \d*? panic: ((?:.|\n)*$)/gm;

function logInfo(log) {
    return {
        name: log,
        date: new Date(+log.split("-")[1]),
    };
}

function getLogs() {
    return fs.readdirSync(savedLogsPath).map(logInfo).sort((a, b) => b.date - a.date);
}

let relations = [];

function calculateRelations() {
    const logs = getLogs();

    logScramble: for (const log of logs) {
        let err = fs.readFileSync(path.join(savedLogsPath, log.name, "stderr.log")).toString();
        err = err.match(panicRegex)[0].split("\n").slice(1).join("\n");

        for (const relation of relations) {
            if (relation[0].err == err) {
                relation.push({
                    log
                });
                continue logScramble;
            }
        }

        relations.push([{
            log,
            err,
        }]);
    }
}

calculateRelations();

app.get("/", (req, res) => {
    res.render("index.ejs", {
        logs: getLogs(),
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
