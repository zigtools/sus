const fs = require("fs");
const ls = require("vscode-languageserver/node");
const TextDocument = require("vscode-languageserver-textdocument").TextDocument;
const Readable = require("stream").Readable;
const DevNull = require("dev-null");

function simulate(data) {
    return new Promise(resolve => {
        const s = new Readable({
            read () {}
        });
        for (const datum of data) {
            s.push(`Content-Length: ${Buffer.byteLength(datum, "utf-8")}\r\n\r\n`);
            s.push(Buffer.from(datum, "utf-8"));
        }
        const shutdown = JSON.stringify({
            jsonrpc: "2.0",
            method: "shutdown",
            id: "shutitdown",
        });
        s.push(`Content-Length: ${Buffer.byteLength(shutdown, "utf-8")}\r\n\r\n${shutdown}`);
    
        let connection = ls.createConnection(s, new DevNull());
    
        let documents = new ls.TextDocuments(TextDocument);
        documents.listen(connection);
    
        connection.onInitialize((params, cancel, progress) => {
            return {};
        });
    
        connection.onShutdown(() => {
            connection.dispose();
            resolve(documents.all()[0]);
        });
    
        // Listen on the connection
        connection.listen();
    })
}

module.exports = simulate;
