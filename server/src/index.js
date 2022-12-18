const fs = require("fs");
const path = require("path");
const express = require("express");

const app = express();

const savedLogsPath = path.join(__dirname, "../..", "saved_logs");

function getLogs() {
    return fs.readdirSync(savedLogsPath).map(_ => ({
        name: _,
        date: new Date(+_.split("-")[1]),
    })).sort((a, b) => b.date - a.date);
}

app.get("/", (req, res) => {
    console.log(getLogs());
    res.render("index.ejs", {
        logs: getLogs(),
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
