const std = @import("std");

fn renderHeader(writer: anytype) !void {
    try writer.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <meta http-equiv="X-UA-Compatible" content="IE=edge">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\    <title>sus</title>
        \\
        \\    <link rel="stylesheet" href="/static/style.css">
        \\</head>
        \\<body>
    );
}

fn renderFooter(writer: anytype) !void {
    try writer.writeAll(
        \\</body>
        \\</html>
    );
}

pub fn renderIndex(writer: anytype) !void {
    try renderHeader(writer);
    try writer.writeAll(
        \\<h1>zigtools fuzzing</h1>
    );
    try renderFooter(writer);
}
