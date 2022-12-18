const fs = require("fs");
const path = require("path");
const express = require("express");

const app = express();

const savedLogsPath = path.join(__dirname, "../..", "saved_logs");

app.get("/", (req, res) => {
    res.render("index.ejs", {
        logs: fs.readdirSync(savedLogsPath),
    });
});

app.get("/log/:log", (req, res) => {
    // Prevent OWASP / \ injection attack (is there a safer way to do this?)
    const logDir = path.join(savedLogsPath, path.basename(req.params.log));

    if (!fs.existsSync(logDir)) return res.status(404).end("404");

    res.render("log.ejs", {
        logs: fs.readdirSync(savedLogsPath),
    });
});

app.listen(80);
