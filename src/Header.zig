const std = @import("std");

const Header = @This();

content_length: usize,
// NOTE: we ignore Content-Type intentionally

// Caller owns returned memory.
pub fn parse(reader: anytype) !Header {
    var buffer: [256]u8 = undefined;

    var r = Header{
        .content_length = undefined,
    };

    var has_content_length = false;
    while (true) {
        const header = try reader.readUntilDelimiter(&buffer, '\n');

        if (header.len == 0 or header[header.len - 1] != '\r') return error.MissingCarriageReturn;
        if (header.len == 1) break;

        const header_name = header[0 .. std.mem.indexOf(u8, header, ": ") orelse return error.MissingColon];
        const header_value = header[header_name.len + 2 .. header.len - 1];
        if (std.mem.eql(u8, header_name, "Content-Length")) {
            if (header_value.len == 0) return error.MissingHeaderValue;
            r.content_length = std.fmt.parseInt(usize, header_value, 10) catch return error.InvalidContentLength;
            has_content_length = true;
        } else if (std.mem.eql(u8, header_name, "Content-Type")) {} else {
            std.log.info("{s}", .{header_name});
            return error.UnknownHeader;
        }
    }
    if (!has_content_length) return error.MissingContentLength;

    return r;
}

pub fn writeToBuffer(header: Header, buffer: []u8) ![]u8 {
    return std.fmt.bufPrint(buffer, "Content-Length: {d}\r\n\r\n", .{header.content_length});
}
