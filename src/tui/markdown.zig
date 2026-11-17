const std = @import("std");
const vaxis = @import("vaxis");
const syntax = @import("syntax.zig");

pub const Theme = struct {
    /// Background of inline code and code blocks; `.default` renders them unshaded.
    tint: vaxis.Color = .default,
    /// Strings in tagged code blocks: a palette color, which terminals keep readable on light and dark backgrounds.
    string: vaxis.Color = .{ .index = 6 },
};

const Kind = enum { prose, heading, code, table, quote, list, other };

const max_cols = 16;
const col_gap = 2;

const Line = struct {
    text: []const u8,
    kind: Kind = .prose,
    /// One blank row above the line.
    gap: bool = false,
    /// Tables: a terminated line after the last row ended the block.
    closed: bool = true,
    /// Classification may change when more text arrives.
    undecided: bool = false,
    /// Code lines of a recognized language, with the lexer state at the start of the line.
    lang: ?syntax.Lang = null,
    lex: syntax.State = .none,
};

const State = struct {
    pos: usize = 0,
    fence: ?struct { char: u8, len: usize, lang: ?syntax.Lang = null } = null,
    lex: syntax.State = .none,
    prev: Kind = .other,
    blank: bool = false,
    emitted: bool = false,
};

const Align = enum { left, center, right };

fn isBlank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t").len == 0;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

fn isListItem(body: []const u8) bool {
    if (body.len >= 2 and (body[0] == '-' or body[0] == '*' or body[0] == '+') and body[1] == ' ') return true;
    var n: usize = 0;
    while (n < body.len and n < 9 and std.ascii.isDigit(body[n])) n += 1;
    return n > 0 and n + 1 < body.len and (body[n] == '.' or body[n] == ')') and body[n + 1] == ' ';
}

fn isRule(body: []const u8) bool {
    var count: usize = 0;
    var mark: u8 = 0;
    for (body) |c| {
        if (c == ' ') continue;
        if (c != '-' and c != '*' and c != '_') return false;
        if (mark != 0 and c != mark) return false;
        mark = c;
        count += 1;
    }
    return count >= 3;
}

const Cells = struct {
    rest: []const u8,
    done: bool = false,

    fn init(line: []const u8) Cells {
        var s = std.mem.trim(u8, line, " \t");
        if (s.len > 0 and s[0] == '|') s = s[1..];
        if (s.len > 0 and s[s.len - 1] == '|' and !(s.len > 1 and s[s.len - 2] == '\\')) s = s[0 .. s.len - 1];
        return .{ .rest = s };
    }

    fn next(c: *Cells) ?[]const u8 {
        if (c.done) return null;
        var i: usize = 0;
        while (i < c.rest.len) : (i += 1) {
            if (c.rest[i] == '\\') {
                i += 1;
            } else if (c.rest[i] == '|') {
                const cell = c.rest[0..i];
                c.rest = c.rest[i + 1 ..];
                return std.mem.trim(u8, cell, " \t");
            }
        }
        c.done = true;
        return std.mem.trim(u8, c.rest, " \t");
    }
};

fn cellCount(line: []const u8) usize {
    var cells = Cells.init(line);
    var n: usize = 0;
    while (cells.next()) |_| n += 1;
    return n;
}

fn parseDelimiter(line: []const u8, aligns: ?*[max_cols]Align) ?usize {
    if (std.mem.indexOfScalar(u8, line, '|') == null) return null;
    var cells = Cells.init(line);
    var n: usize = 0;
    while (cells.next()) |cell| : (n += 1) {
        if (n == max_cols) return null;
        const left = std.mem.startsWith(u8, cell, ":");
        const right = cell.len > 0 and cell[cell.len - 1] == ':';
        const dashes = cell[@intFromBool(left) .. cell.len - @intFromBool(right and cell.len > @intFromBool(left))];
        if (dashes.len == 0 or std.mem.indexOfNone(u8, dashes, "-") != null) return null;
        if (aligns) |a| a[n] = if (left and right) .center else if (right) .right else .left;
    }
    return n;
}

const Lines = struct {
    text: []const u8,
    st: State = .{},

    const Raw = struct { raw: []const u8, start: usize, end: usize, terminated: bool };

    fn rawAt(self: *const Lines, start: usize) ?Raw {
        if (start > self.text.len) return null;
        const end = std.mem.indexOfScalarPos(u8, self.text, start, '\n') orelse self.text.len;
        return .{ .raw = std.mem.trimEnd(u8, self.text[start..end], "\r"), .start = start, .end = end, .terminated = end < self.text.len };
    }

    fn emit(self: *Lines, line_in: Line, continuation: bool) Line {
        var line = line_in;
        if (self.st.emitted) {
            line.gap = self.st.blank or line.kind == .heading or (line.kind == .prose and !continuation and self.st.prev == .prose);
        }
        self.st.blank = false;
        self.st.emitted = true;
        if (!continuation) self.st.prev = line.kind;
        return line;
    }

    fn next(self: *Lines) ?Line {
        while (self.st.pos <= self.text.len) {
            const cur = self.rawAt(self.st.pos).?;
            const raw = cur.raw;
            self.st.pos = if (cur.end == self.text.len) self.text.len + 1 else cur.end + 1;
            const body = std.mem.trimStart(u8, raw, " ");
            const indent = raw.len - body.len;
            if (indent <= 3 and body.len >= 3 and (body[0] == '`' or body[0] == '~')) {
                const n = std.mem.indexOfNone(u8, body, body[0..1]) orelse body.len;
                if (n >= 3) {
                    if (self.st.fence) |f| {
                        if (body[0] == f.char and n >= f.len and std.mem.trim(u8, body[n..], " \t").len == 0) {
                            self.st.fence = null;
                            self.st.lex = .none;
                            continue;
                        }
                    } else {
                        self.st.fence = .{ .char = body[0], .len = n, .lang = syntax.langFromInfo(body[n..]) };
                        self.st.lex = .none;
                        continue;
                    }
                }
            }
            if (self.st.fence) |f| {
                const line = self.emit(.{ .text = raw, .kind = .code, .lang = f.lang, .lex = self.st.lex }, false);
                if (f.lang) |lang| self.st.lex = syntax.advance(lang, self.st.lex, raw);
                return line;
            }
            if (isBlank(raw)) {
                self.st.blank = true;
                self.st.prev = .other;
                continue;
            }
            const marks = std.mem.indexOfNone(u8, body, "#") orelse body.len;
            if (indent <= 3 and marks > 0 and marks <= 6 and marks < body.len and body[marks] == ' ')
                return self.emit(.{ .text = body[marks + 1 ..], .kind = .heading }, false);
            if (indent <= 3 and body[0] == '>') {
                const rest = body[1..];
                return self.emit(.{ .text = if (rest.len > 0 and rest[0] == ' ') rest[1..] else rest, .kind = .quote }, false);
            }
            if (isRule(body)) return self.emit(.{ .text = raw, .kind = .other }, false);
            if (isListItem(body)) return self.emit(.{ .text = raw, .kind = .list }, false);
            if (indent <= 3 and cur.terminated and std.mem.indexOfScalar(u8, raw, '|') != null) {
                if (self.table(cur)) |line| return line;
                if (self.undecided(cur)) {
                    var line = self.emit(.{ .text = raw }, false);
                    line.undecided = true;
                    return line;
                }
            }
            const continuation = !self.st.blank and (self.st.prev == .list or self.st.prev == .quote);
            return self.emit(.{ .text = raw }, continuation);
        }
        return null;
    }

    fn undecided(self: *const Lines, header: Raw) bool {
        const nxt = self.rawAt(header.end + 1) orelse return true;
        if (nxt.terminated) return false;
        return std.mem.indexOfNone(u8, nxt.raw, "|-: \t") == null;
    }

    fn table(self: *Lines, header: Raw) ?Line {
        const delim = self.rawAt(header.end + 1) orelse return null;
        const cols = parseDelimiter(delim.raw, null) orelse return null;
        if (cellCount(header.raw) != cols) return null;
        var end = delim.end;
        var closed = false;
        var at = if (delim.terminated) delim.end + 1 else self.text.len + 1;
        while (self.rawAt(at)) |row| {
            if (isBlank(row.raw) or std.mem.indexOfScalar(u8, row.raw, '|') == null) {
                closed = row.terminated;
                break;
            }
            end = row.end;
            at = if (row.terminated) row.end + 1 else self.text.len + 1;
        }
        self.st.pos = at;
        return self.emit(.{ .text = self.text[header.start..end], .kind = .table, .closed = closed }, false);
    }
};

const Span = struct {
    kind: enum { code, bold, italic, link },
    open: usize,
    end: usize,
    close: usize,
    url: []const u8 = "",
};

fn span(t: []const u8, i: usize) ?Span {
    switch (t[i]) {
        '`' => {
            const end = std.mem.indexOfPos(u8, t, i + 1, "`") orelse return null;
            return .{ .kind = .code, .open = 1, .end = end, .close = 1 };
        },
        '*' => {
            if (std.mem.startsWith(u8, t[i..], "**")) {
                const end = std.mem.indexOfPos(u8, t, i + 2, "**") orelse return null;
                return .{ .kind = .bold, .open = 2, .end = end, .close = 2 };
            }
            if (i + 1 >= t.len or t[i + 1] == ' ') return null;
            const end = std.mem.indexOfScalarPos(u8, t, i + 1, '*') orelse return null;
            if (t[end - 1] == ' ' or (end + 1 < t.len and t[end + 1] == '*')) return null;
            return .{ .kind = .italic, .open = 1, .end = end, .close = 1 };
        },
        '_' => {
            if ((i > 0 and isWord(t[i - 1])) or i + 1 >= t.len or t[i + 1] == ' ' or t[i + 1] == '_') return null;
            var end = i + 1;
            while (std.mem.indexOfScalarPos(u8, t, end, '_')) |e| : (end = e + 1) {
                if (t[e - 1] != ' ' and (e + 1 >= t.len or !isWord(t[e + 1]))) return .{ .kind = .italic, .open = 1, .end = e, .close = 1 };
            }
            return null;
        },
        '[' => {
            if (i > 0 and t[i - 1] == '!') return null;
            const close = std.mem.indexOfScalarPos(u8, t, i + 1, ']') orelse return null;
            if (close == i + 1 or close + 1 >= t.len or t[close + 1] != '(') return null;
            const paren = std.mem.indexOfScalarPos(u8, t, close + 2, ')') orelse return null;
            const url = t[close + 2 .. paren];
            if (url.len == 0 or std.mem.indexOfAny(u8, url, " \n") != null) return null;
            return .{ .kind = .link, .open = 1, .end = close, .close = paren + 1 - close, .url = url };
        },
        else => return null,
    }
}

const Inline = struct {
    text: []const u8,
    pos: usize = 0,
    base: vaxis.Style = .{},
    code_bg: vaxis.Color = .default,
    url: []const u8 = "",
    url_stage: u2 = 0,

    fn next(self: *Inline) ?vaxis.Segment {
        if (self.url_stage != 0) {
            var style = self.base;
            style.dim = true;
            const text: []const u8 = switch (self.url_stage) {
                1 => " (",
                2 => self.url,
                else => ")",
            };
            self.url_stage = if (self.url_stage == 3) 0 else self.url_stage + 1;
            return .{ .text = text, .style = style };
        }
        if (self.pos >= self.text.len) return null;
        var i = self.pos;
        while (i < self.text.len) : (i += 1) {
            const found = span(self.text, i) orelse continue;
            if (i > self.pos) {
                const plain = self.text[self.pos..i];
                self.pos = i;
                return .{ .text = plain, .style = self.base };
            }
            self.pos = found.end + found.close;
            var style = self.base;
            switch (found.kind) {
                .code => style.bg = self.code_bg,
                .bold => style.bold = true,
                .italic => style.italic = true,
                .link => {
                    self.url = found.url;
                    self.url_stage = 1;
                },
            }
            return .{ .text = self.text[i + found.open .. found.end], .style = style };
        }
        const plain = self.text[self.pos..];
        self.pos = self.text.len;
        return .{ .text = plain, .style = self.base };
    }
};

fn rows(result: vaxis.Window.PrintResult) u16 {
    return @max(1, result.row + @intFromBool(result.col > 0));
}

fn printTabbed(win: vaxis.Window, text: []const u8, style: vaxis.Style, from: vaxis.Window.PrintResult, commit: bool) vaxis.Window.PrintResult {
    var result = from;
    var pos: usize = 0;
    while (pos < text.len) {
        const tab = std.mem.indexOfScalarPos(u8, text, pos, '\t') orelse text.len;
        result = win.printSegment(.{ .text = text[pos..tab], .style = style }, .{ .row_offset = result.row, .col_offset = result.col, .commit = commit });
        if (tab == text.len) break;
        result = win.printSegment(.{ .text = "    ", .style = style }, .{ .row_offset = result.row, .col_offset = result.col, .commit = commit });
        pos = tab + 1;
    }
    return result;
}

const Code = struct {
    lang: ?syntax.Lang = null,
    lex: syntax.State = .none,
};

fn tokenStyle(base: vaxis.Style, class: syntax.Class, theme: Theme) vaxis.Style {
    var style = base;
    switch (class) {
        .plain => {},
        .comment => style.dim = true,
        .string => style.fg = theme.string,
        .keyword => style.bold = true,
    }
    return style;
}

fn codeLine(win: vaxis.Window, text: []const u8, base: vaxis.Style, code: Code, theme: Theme, commit: bool) u16 {
    var result: vaxis.Window.PrintResult = .{ .row = 0, .col = 0, .overflow = false };
    if (code.lang) |lang| {
        var lexer = syntax.Lexer.init(lang, code.lex, text);
        while (lexer.next()) |token| {
            result = printTabbed(win, text[token.start..token.end], tokenStyle(base, token.class, theme), result, commit);
        }
    } else result = printTabbed(win, text, base, result, commit);
    return rows(result);
}

fn shade(win: vaxis.Window, count: u16, bg: vaxis.Color) void {
    for (0..count) |r| for (0..win.width) |c| {
        var cell = win.readCell(@intCast(c), @intCast(r)) orelse continue;
        cell.style.bg = bg;
        cell.default = false;
        win.writeCell(@intCast(c), @intCast(r), cell);
    };
}

fn printCode(row: vaxis.Window, text: []const u8, code: Code, theme: Theme, commit: bool) u16 {
    if (row.width <= 2) return codeLine(row, text, .{}, code, theme, commit);
    if (theme.tint != .default) {
        const used = codeLine(row.child(.{ .x_off = 1, .width = row.width - 2 }), text, .{ .bg = theme.tint }, code, theme, commit);
        if (commit) shade(row, used, theme.tint);
        return used;
    }
    const bar: vaxis.Style = .{ .dim = true };
    const used = codeLine(row.child(.{ .x_off = 2 }), text, .{}, code, theme, commit);
    for (0..used) |r| _ = row.printSegment(.{ .text = "│ ", .style = bar }, .{ .row_offset = @intCast(r), .commit = commit });
    return used;
}

fn printProse(row: vaxis.Window, text: []const u8, base: vaxis.Style, theme: Theme, commit: bool) u16 {
    var spans: Inline = .{ .text = text, .base = base, .code_bg = theme.tint };
    var result: vaxis.Window.PrintResult = .{ .row = 0, .col = 0, .overflow = false };
    while (spans.next()) |segment| {
        result = row.printSegment(segment, .{ .row_offset = result.row, .col_offset = result.col, .wrap = .word, .commit = commit });
    }
    return rows(result);
}

fn printQuote(row: vaxis.Window, text: []const u8, theme: Theme, commit: bool) u16 {
    if (row.width <= 2) return printProse(row, text, .{}, theme, commit);
    const used = printProse(row.child(.{ .x_off = 2 }), text, .{}, theme, commit);
    for (0..used) |r| _ = row.printSegment(.{ .text = "│ ", .style = .{ .dim = true } }, .{ .row_offset = @intCast(r), .commit = commit });
    return used;
}

fn unescapedWidth(win: vaxis.Window, text: []const u8) u16 {
    var w: u16 = 0;
    var rest = text;
    while (std.mem.indexOf(u8, rest, "\\|")) |at| {
        w +|= win.gwidth(rest[0..at]) +| 1;
        rest = rest[at + 2 ..];
    }
    return w +| win.gwidth(rest);
}

fn cellWidth(win: vaxis.Window, cell: []const u8) u16 {
    var spans: Inline = .{ .text = cell };
    var w: u16 = 0;
    while (spans.next()) |segment| w +|= unescapedWidth(win, segment.text);
    return w;
}

fn printCell(win: vaxis.Window, x: u16, cell: []const u8, base: vaxis.Style, theme: Theme) void {
    var spans: Inline = .{ .text = cell, .base = base, .code_bg = theme.tint };
    var col = x;
    while (spans.next()) |segment| {
        var rest = segment.text;
        while (true) {
            const at = std.mem.indexOf(u8, rest, "\\|");
            const piece = if (at) |a| rest[0..a] else rest;
            _ = win.printSegment(.{ .text = piece, .style = segment.style }, .{ .col_offset = col, .wrap = .none });
            col +|= win.gwidth(piece);
            const a = at orelse break;
            _ = win.printSegment(.{ .text = "|", .style = segment.style }, .{ .col_offset = col, .wrap = .none });
            col +|= 1;
            rest = rest[a + 2 ..];
        }
    }
}

const Table = struct {
    cols: usize,
    aligns: [max_cols]Align = undefined,
    widths: [max_cols]u16 = @splat(0),
    total: u16 = 0,

    fn body(block: []const u8) std.mem.SplitIterator(u8, .scalar) {
        return std.mem.splitScalar(u8, block, '\n');
    }

    fn measure(win: vaxis.Window, block: []const u8) ?Table {
        var lines = body(block);
        const header = std.mem.trimEnd(u8, lines.next().?, "\r");
        var t: Table = .{ .cols = 0 };
        t.cols = parseDelimiter(std.mem.trimEnd(u8, lines.next() orelse return null, "\r"), &t.aligns) orelse return null;
        measureRow(win, &t, header);
        while (lines.next()) |line| measureRow(win, &t, std.mem.trimEnd(u8, line, "\r"));
        t.total = @intCast(@min(std.math.maxInt(u16), (t.cols - 1) * col_gap));
        for (t.widths[0..t.cols]) |w| t.total +|= w;
        return if (t.total > win.width) null else t;
    }

    fn measureRow(win: vaxis.Window, t: *Table, line: []const u8) void {
        var cells = Cells.init(line);
        var i: usize = 0;
        while (cells.next()) |cell| : (i += 1) {
            if (i == t.cols) break;
            t.widths[i] = @max(t.widths[i], cellWidth(win, cell));
        }
    }

    fn printRow(t: *const Table, win: vaxis.Window, line: []const u8, base: vaxis.Style, theme: Theme) void {
        var cells = Cells.init(line);
        var x: u16 = 0;
        for (0..t.cols) |i| {
            const cell = cells.next() orelse "";
            const pad = t.widths[i] -| cellWidth(win, cell);
            const at = x + switch (t.aligns[i]) {
                .left => @as(u16, 0),
                .center => pad / 2,
                .right => pad,
            };
            printCell(win, at, cell, base, theme);
            x +|= t.widths[i] +| col_gap;
        }
    }
};

fn printTable(win: vaxis.Window, block: []const u8, theme: Theme, commit: bool) u16 {
    const t = Table.measure(win, block) orelse {
        var height: u16 = 0;
        var lines = Table.body(block);
        while (lines.next()) |line| {
            height +|= printProse(win.child(.{ .y_off = @intCast(height) }), std.mem.trimEnd(u8, line, "\r"), .{}, theme, commit);
        }
        return height;
    };
    var lines = Table.body(block);
    var height: u16 = 0;
    const header = std.mem.trimEnd(u8, lines.next().?, "\r");
    _ = lines.next();
    if (commit) t.printRow(win, header, .{ .dim = true }, theme);
    height = 1;
    while (lines.next()) |line| : (height +|= 1) {
        if (commit) t.printRow(win.child(.{ .y_off = @intCast(height) }), std.mem.trimEnd(u8, line, "\r"), .{}, theme);
    }
    return height;
}

fn printLine(win: vaxis.Window, line: Line, theme: Theme, commit: bool) u16 {
    const top: u16 = @intFromBool(line.gap);
    const row = win.child(.{ .y_off = top });
    const used = switch (line.kind) {
        .code => printCode(row, line.text, .{ .lang = line.lang, .lex = line.lex }, theme, commit),
        .heading => printProse(row, line.text, .{ .bold = true }, theme, commit),
        .quote => printQuote(row, line.text, theme, commit),
        .table => printTable(row, line.text, theme, commit),
        .prose, .list, .other => printProse(row, line.text, .{}, theme, commit),
    };
    return top +| used;
}

pub fn print(win: vaxis.Window, text: []const u8, theme: Theme, commit: bool) u16 {
    var lines: Lines = .{ .text = text };
    var height: u16 = 0;
    while (lines.next()) |line| {
        const row = win.child(.{ .y_off = @intCast(height) });
        height +|= printLine(row, line, theme, commit);
    }
    return @max(1, height);
}

pub const Cache = struct {
    const CachedLine = struct { offset: usize, len: usize, kind: Kind, gap: bool, lang: ?syntax.Lang, lex: syntax.State, y: u16, rows: u16 };
    lines: std.ArrayList(CachedLine) = .empty,
    width: u16 = 0,
    st: State = .{},
    height: u16 = 0,

    pub fn deinit(c: *Cache, gpa: std.mem.Allocator) void {
        c.lines.deinit(gpa);
    }

    /// Lines whose layout may still change (partial, undecided table header, open table) stay out of the cache.
    pub fn draw(c: *Cache, gpa: std.mem.Allocator, win: vaxis.Window, text: []const u8, theme: Theme, commit: bool) u16 {
        if (c.width != win.width or c.st.pos > text.len) {
            c.lines.clearRetainingCapacity();
            c.width = win.width;
            c.st = .{};
            c.height = 0;
        }
        var parser: Lines = .{ .text = text, .st = c.st };
        while (true) {
            const before = parser.st;
            const line = parser.next() orelse break;
            if (parser.st.pos > text.len or line.undecided or (line.kind == .table and !line.closed)) {
                parser.st = before;
                break;
            }
            const h = printLine(win, line, theme, false);
            c.lines.append(gpa, .{ .offset = @intFromPtr(line.text.ptr) - @intFromPtr(text.ptr), .len = line.text.len, .kind = line.kind, .gap = line.gap, .lang = line.lang, .lex = line.lex, .y = c.height, .rows = h }) catch return print(win, text, theme, commit);
            c.height +|= h;
            c.st = parser.st;
        }
        if (commit) for (c.lines.items) |line| {
            if (@as(i32, win.y_off) + line.y + line.rows <= 0) continue;
            if (@as(i32, win.y_off) + line.y >= win.screen.height) break;
            _ = printLine(win.child(.{ .y_off = @intCast(line.y) }), .{ .text = text[line.offset..][0..line.len], .kind = line.kind, .gap = line.gap, .lang = line.lang, .lex = line.lex }, theme, true);
        };
        var height = c.height;
        parser = .{ .text = text, .st = c.st };
        while (parser.next()) |line| height +|= printLine(win.child(.{ .y_off = @intCast(height) }), line, theme, commit);
        return @max(1, height);
    }
};

const testing = std.testing;
const tint: vaxis.Color = .{ .rgb = .{ 20, 20, 20 } };

const Shot = struct {
    screen: vaxis.Screen,
    win: vaxis.Window,

    fn init(shot: *Shot, a: std.mem.Allocator, cols: u16) !void {
        shot.screen = try vaxis.Screen.init(a, .{ .cols = cols, .rows = 32, .x_pixel = 0, .y_pixel = 0 });
        shot.win = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = cols, .height = 32, .screen = &shot.screen };
    }

    fn deinit(shot: *Shot, a: std.mem.Allocator) void {
        shot.screen.deinit(a);
    }

    fn row(shot: *const Shot, a: std.mem.Allocator, r: u16) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        var col: u16 = 0;
        while (col < shot.screen.width) {
            const c = shot.screen.readCell(col, r).?;
            try out.appendSlice(a, if (c.char.grapheme.len == 0) " " else c.char.grapheme);
            col += @max(1, c.char.width);
        }
        return a.dupe(u8, std.mem.trimEnd(u8, out.items, " "));
    }

    fn expect(shot: *const Shot, a: std.mem.Allocator, want: []const []const u8) !void {
        for (want, 0..) |line, r| {
            const got = try shot.row(a, @intCast(r));
            defer a.free(got);
            try testing.expectEqualStrings(line, got);
        }
    }

    fn cell(shot: *const Shot, col: u16, r: u16) vaxis.Cell {
        return shot.screen.readCell(col, r).?;
    }
};

fn drawText(shot: *Shot, text: []const u8, theme: Theme) u16 {
    return print(shot.win, text, theme, true);
}

const Parsed = struct { kind: Kind, gap: bool, text: []const u8 };

fn expectLines(text: []const u8, want: []const Parsed) !void {
    var lines: Lines = .{ .text = text };
    for (want) |w| {
        const line = lines.next().?;
        try testing.expectEqual(w.kind, line.kind);
        try testing.expectEqual(w.gap, line.gap);
        try testing.expectEqualStrings(w.text, line.text);
    }
    try testing.expect(lines.next() == null);
}

test "fences, indentation, and headings" {
    try expectLines("~~~zig\n  one\n~~~\n```\ntwo", &.{
        .{ .kind = .code, .gap = false, .text = "  one" },
        .{ .kind = .code, .gap = false, .text = "two" },
    });
    try expectLines("  # Title\n    # plain", &.{
        .{ .kind = .heading, .gap = false, .text = "Title" },
        .{ .kind = .prose, .gap = false, .text = "    # plain" },
    });
}

test "paragraph breaks: blank lines collapse, single newlines between prose separate" {
    try expectLines("one\ntwo", &.{ .{ .kind = .prose, .gap = false, .text = "one" }, .{ .kind = .prose, .gap = true, .text = "two" } });
    try expectLines("one\n\n\n\ntwo", &.{ .{ .kind = .prose, .gap = false, .text = "one" }, .{ .kind = .prose, .gap = true, .text = "two" } });
    try expectLines("\n\none\n\n", &.{.{ .kind = .prose, .gap = false, .text = "one" }});
    try expectLines("a\n\n  \nb", &.{ .{ .kind = .prose, .gap = false, .text = "a" }, .{ .kind = .prose, .gap = true, .text = "b" } });
}

test "no paragraph gap around lists, quotes, headings, code and tables" {
    try expectLines("- a\ncont\n  more\n1. b", &.{
        .{ .kind = .list, .gap = false, .text = "- a" },
        .{ .kind = .prose, .gap = false, .text = "cont" },
        .{ .kind = .prose, .gap = false, .text = "  more" },
        .{ .kind = .list, .gap = false, .text = "1. b" },
    });
    try expectLines("para\n- item", &.{ .{ .kind = .prose, .gap = false, .text = "para" }, .{ .kind = .list, .gap = false, .text = "- item" } });
    try expectLines("> q\nlazy\n> r", &.{
        .{ .kind = .quote, .gap = false, .text = "q" },
        .{ .kind = .prose, .gap = false, .text = "lazy" },
        .{ .kind = .quote, .gap = false, .text = "r" },
    });
    try expectLines("para\n# H\ntext", &.{
        .{ .kind = .prose, .gap = false, .text = "para" },
        .{ .kind = .heading, .gap = true, .text = "H" },
        .{ .kind = .prose, .gap = false, .text = "text" },
    });
    try expectLines("para\n```\ncode\n```\nafter", &.{
        .{ .kind = .prose, .gap = false, .text = "para" },
        .{ .kind = .code, .gap = false, .text = "code" },
        .{ .kind = .prose, .gap = false, .text = "after" },
    });
    try expectLines("para\n| a | b |\n|---|---|\n| 1 | 2 |\nnext", &.{
        .{ .kind = .prose, .gap = false, .text = "para" },
        .{ .kind = .table, .gap = false, .text = "| a | b |\n|---|---|\n| 1 | 2 |" },
        .{ .kind = .prose, .gap = false, .text = "next" },
    });
    try expectLines("a\n\n```\nx\n\ny\n```\n\nb", &.{
        .{ .kind = .prose, .gap = false, .text = "a" },
        .{ .kind = .code, .gap = true, .text = "x" },
        .{ .kind = .code, .gap = false, .text = "" },
        .{ .kind = .code, .gap = false, .text = "y" },
        .{ .kind = .prose, .gap = true, .text = "b" },
    });
}

test "headings keep bold default foreground and get one blank row above except first" {
    const a = testing.allocator;
    var shot: Shot = undefined;
    try shot.init(a, 20);
    defer shot.deinit(a);
    try testing.expectEqual(@as(u16, 5), drawText(&shot, "# Top\nintro\n## Title\nbody", .{}));
    try shot.expect(a, &.{ "Top", "intro", "", "Title", "body" });
    try testing.expect(shot.cell(0, 0).style.bold);
    try testing.expectEqual(vaxis.Color.default, shot.cell(0, 3).style.fg);
    try testing.expect(!shot.cell(0, 1).style.bold);
}

test "inline code tint and no-tint fallback" {
    const a = testing.allocator;
    var shot: Shot = undefined;
    try shot.init(a, 20);
    defer shot.deinit(a);
    _ = drawText(&shot, "a `b` c", .{ .tint = tint });
    try shot.expect(a, &.{"a b c"});
    try testing.expectEqual(tint, shot.cell(2, 0).style.bg);
    try testing.expectEqual(vaxis.Color.default, shot.cell(0, 0).style.bg);
    try testing.expectEqual(vaxis.Color.default, shot.cell(2, 0).style.fg);
    shot.screen.clear();
    _ = drawText(&shot, "a `b` c", .{});
    try testing.expectEqual(vaxis.Color.default, shot.cell(2, 0).style.bg);
    try testing.expectEqual(vaxis.Color.default, shot.cell(2, 0).style.fg);
}

test "code blocks: tinted with padding, bar fallback, info string hidden" {
    const a = testing.allocator;
    var shot: Shot = undefined;
    try shot.init(a, 12);
    defer shot.deinit(a);
    try testing.expectEqual(@as(u16, 2), drawText(&shot, "```zig\nlet x\n\ty\n```", .{ .tint = tint }));
    try shot.expect(a, &.{ " let x", "     y" });
    for (0..12) |c| try testing.expectEqual(tint, shot.cell(@intCast(c), 0).style.bg);
    try testing.expectEqual(vaxis.Color.default, shot.cell(1, 0).style.fg);
    try testing.expectEqual(vaxis.Color.default, shot.cell(0, 2).style.bg);
    shot.screen.clear();
    _ = drawText(&shot, "```zig\nlet x\n```", .{});
    try shot.expect(a, &.{"│ let x"});
    try testing.expect(shot.cell(0, 0).style.dim);
    try testing.expectEqual(vaxis.Color.default, shot.cell(0, 0).style.fg);
    try testing.expectEqual(vaxis.Color.default, shot.cell(2, 0).style.bg);
}

test "italic, links and quotes" {
    const a = testing.allocator;
    var shot: Shot = undefined;
    try shot.init(a, 60);
    defer shot.deinit(a);
    _ = drawText(&shot, "*it* and _it2_ snake_case_x 2 * 3 * 4", .{});
    try shot.expect(a, &.{"it and it2 snake_case_x 2 * 3 * 4"});
    try testing.expect(shot.cell(0, 0).style.italic);
    try testing.expect(!shot.cell(3, 0).style.italic);
    try testing.expect(shot.cell(7, 0).style.italic);
    try testing.expect(!shot.cell(13, 0).style.italic);
    shot.screen.clear();
    _ = drawText(&shot, "[docs](https://x.dev/a) and https://y.dev ![i](p)", .{});
    try shot.expect(a, &.{"docs (https://x.dev/a) and https://y.dev ![i](p)"});
    try testing.expect(!shot.cell(0, 0).style.dim);
    try testing.expect(shot.cell(4, 0).style.dim);
    try testing.expect(shot.cell(10, 0).style.dim);
    try testing.expect(!shot.cell(24, 0).style.dim);
    shot.screen.clear();
    try testing.expectEqual(@as(u16, 2), drawText(&shot, "> quoted **b**\n> second", .{}));
    try shot.expect(a, &.{ "│ quoted b", "│ second" });
    try testing.expect(shot.cell(0, 0).style.dim);
    try testing.expect(!shot.cell(2, 0).style.dim);
    try testing.expect(shot.cell(9, 0).style.bold);
}

test "table renders aligned borderless columns by display width" {
    const a = testing.allocator;
    var shot: Shot = undefined;
    try shot.init(a, 60);
    defer shot.deinit(a);
    const text = "| 文件 | 改动 | 说明 |\n|---|:---:|---:|\n| src/grep.zig | +38 −9 | 边界检查 |\n| tests/a.py | +54 | 空 |";
    try testing.expectEqual(@as(u16, 3), drawText(&shot, text, .{}));
    try shot.expect(a, &.{
        "文件" ++ "           " ++ "改动" ++ "       " ++ "说明",
        "src/grep.zig  +38 −9  边界检查",
        "tests/a.py" ++ "     " ++ "+54" ++ "          " ++ "空",
    });
    try testing.expect(shot.cell(0, 0).style.dim and !shot.cell(0, 0).style.bold);
    try testing.expect(!shot.cell(0, 1).style.dim and !shot.cell(0, 1).style.bold);
}

test "table cells keep inline styles, unescape pipes, pad ragged rows" {
    const a = testing.allocator;
    var shot: Shot = undefined;
    try shot.init(a, 40);
    defer shot.deinit(a);
    _ = drawText(&shot, "a|b\n-|-\n`x`|**y**", .{ .tint = tint });
    try shot.expect(a, &.{ "a  b", "x  y" });
    try testing.expectEqual(tint, shot.cell(0, 1).style.bg);
    try testing.expect(shot.cell(3, 1).style.bold);
    shot.screen.clear();
    _ = drawText(&shot, "| a | b |\n|---|---|\n| x\\|y | z |", .{});
    try shot.expect(a, &.{ "a    b", "x|y  z" });
    shot.screen.clear();
    try testing.expectEqual(@as(u16, 3), drawText(&shot, "|a|b|c|\n|-|-|-|\n|1|\n|1|2|3|4|", .{}));
    try shot.expect(a, &.{ "a  b  c", "1", "1  2  3" });
}

test "too-wide tables and non-tables render as plain lines" {
    const a = testing.allocator;
    var shot: Shot = undefined;
    try shot.init(a, 33);
    defer shot.deinit(a);
    const wide = "aaaaaaaaaaaaaaaa|bbbbbbbbbbbbbbbb\n-|-\ncccccccccccccccc|dddddddddddddddd";
    try testing.expectEqual(@as(u16, 3), drawText(&shot, wide, .{}));
    try shot.expect(a, &.{ "aaaaaaaaaaaaaaaa|bbbbbbbbbbbbbbbb", "-|-", "cccccccccccccccc|dddddddddddddddd" });
    shot.screen.clear();
    _ = drawText(&shot, "```\n| a | b |\n|---|---|\n```\nx | y\n\nz | w", .{});
    try shot.expect(a, &.{ "│ | a | b |", "│ |---|---|", "x | y", "", "z | w" });
}

test "table streaming: renders once header and delimiter exist and relays out as rows arrive" {
    const a = testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(a);
    var shot: Shot = undefined;
    try shot.init(a, 40);
    defer shot.deinit(a);
    const steps = [_][]const u8{
        "| a | b |\n",
        "| a | b |\n|---|--",
        "| a | b |\n|---|---|\n| 1 | 2 |\n",
        "| a | b |\n|---|---|\n| 1 | 2 |\n| long cell | 3 |\n",
        "| a | b |\n|---|---|\n| 1 | 2 |\n| long cell | 3 |\n\ntail",
    };
    const want = [_][]const []const u8{
        &.{"| a | b |"},
        &.{"a  b"},
        &.{ "a  b", "1  2" },
        &.{ "a          b", "1          2", "long cell  3" },
        &.{ "a          b", "1          2", "long cell  3", "", "tail" },
    };
    for (steps, want) |text, rows_want| {
        shot.screen.clear();
        const h = cache.draw(a, shot.win, text, .{}, true);
        try testing.expectEqual(print(shot.win, text, .{}, false), h);
        try shot.expect(a, rows_want);
        try testing.expectEqual(@as(u16, @intCast(rows_want.len)), h);
    }
}

test "rendered rows and styles match measurement" {
    const a = testing.allocator;
    var shot: Shot = undefined;
    try shot.init(a, 8);
    defer shot.deinit(a);
    const win = shot.win;
    try testing.expectEqual(@as(u16, 1), print(win, "12345678", .{}, false));
    try testing.expectEqual(@as(u16, 2), print(win, "abcde **def**", .{}, false));
    try testing.expectEqual(@as(u16, 2), print(win, "abcde **def**", .{}, true));
    try testing.expect(shot.cell(0, 1).style.bold);
    shot.screen.clear();
    try testing.expectEqual(@as(u16, 3), print(win, "```\n\txyz\n```\nlast", .{}, false));
    try testing.expectEqual(@as(u16, 3), print(win, "```\n\txyz\n```\nlast", .{}, true));
    try testing.expectEqualStrings("│", shot.cell(0, 0).char.grapheme);
    try testing.expectEqualStrings("z", shot.cell(2, 1).char.grapheme);
    shot.screen.clear();
    try testing.expectEqual(@as(u16, 2), print(win, "~~~\n1234567", .{}, true));
}

test "cached append and resize match uncached markdown" {
    const a = testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(a);
    var shot: Shot = undefined;
    try shot.init(a, 60);
    defer shot.deinit(a);
    var win = shot.win;
    const text = "# Heading\n**late\nclose**\npara one\npara two\n```zig\ncode\n\nmore\n```\n> quote\nlazy\n| a | b |\n|---|--:|\n| 中文 | 1 |\n| x\n- item\ncont\n\n\n中文 👩‍💻 [l](u) *i* tail";
    for ([_]Theme{ .{}, .{ .tint = tint } }) |theme| for ([_]u16{ 60, 20, 60 }) |width| {
        win.width = width;
        for (0..text.len + 1) |n| {
            if (!std.unicode.utf8ValidateSlice(text[0..n])) continue;
            try testing.expectEqual(print(win, text[0..n], theme, false), cache.draw(a, win, text[0..n], theme, false));
            for ([_]i17{ 0, -3, -10 }) |offset| {
                win.y_off = offset;
                win.clear();
                _ = print(win, text[0..n], theme, true);
                const expected = try a.dupe(vaxis.Cell, shot.screen.buf);
                defer a.free(expected);
                win.clear();
                _ = cache.draw(a, win, text[0..n], theme, true);
                try testing.expectEqualDeep(expected, shot.screen.buf);
            }
            win.y_off = 0;
        }
    };
}

const green: vaxis.Color = .{ .index = 2 };
const theme_syntax: Theme = .{ .tint = tint, .string = green };

test "tagged code blocks: dim comments, colored strings, bold keywords" {
    const a = testing.allocator;
    var shot: Shot = undefined;
    try shot.init(a, 40);
    defer shot.deinit(a);
    _ = drawText(&shot, "```zig\nconst s = \"hi\"; // c\n```", theme_syntax);
    try shot.expect(a, &.{" const s = \"hi\"; // c"});
    try testing.expect(shot.cell(1, 0).style.bold);
    try testing.expect(!shot.cell(7, 0).style.bold);
    try testing.expectEqual(vaxis.Color.default, shot.cell(7, 0).style.fg);
    try testing.expectEqual(green, shot.cell(11, 0).style.fg);
    try testing.expectEqual(green, shot.cell(14, 0).style.fg);
    try testing.expect(!shot.cell(15, 0).style.dim and shot.cell(15, 0).style.fg == .default);
    try testing.expect(shot.cell(17, 0).style.dim);
    try testing.expect(shot.cell(20, 0).style.dim);
    for (0..40) |c| try testing.expectEqual(tint, shot.cell(@intCast(c), 0).style.bg);
}

test "untagged and unknown-language blocks and inline code stay plain" {
    const a = testing.allocator;
    var shot: Shot = undefined;
    try shot.init(a, 40);
    defer shot.deinit(a);
    for ([_][]const u8{ "```\nconst s = \"hi\"; // c\n```", "```text\nconst s = \"hi\"; // c\n```" }) |text| {
        shot.screen.clear();
        _ = drawText(&shot, text, theme_syntax);
        for (1..22) |c| {
            const style = shot.cell(@intCast(c), 0).style;
            try testing.expect(!style.bold and !style.dim);
            try testing.expectEqual(vaxis.Color.default, style.fg);
        }
    }
    shot.screen.clear();
    _ = drawText(&shot, "`const \"x\" // y`", theme_syntax);
    for (0..14) |c| {
        const style = shot.cell(@intCast(c), 0).style;
        try testing.expect(!style.bold and !style.dim);
        try testing.expectEqual(vaxis.Color.default, style.fg);
    }
}

test "lexer state carries across code lines and resets at the fence" {
    const a = testing.allocator;
    var shot: Shot = undefined;
    try shot.init(a, 40);
    defer shot.deinit(a);
    _ = drawText(&shot, "```c\n/* one\ntwo */ return\n```\n```c\nreturn\n```", theme_syntax);
    try testing.expect(shot.cell(1, 0).style.dim);
    try testing.expect(shot.cell(1, 1).style.dim);
    try testing.expect(!shot.cell(8, 1).style.dim and shot.cell(8, 1).style.bold);
    try testing.expect(shot.cell(1, 2).style.bold);
    shot.screen.clear();
    _ = drawText(&shot, "```c\n/* open\n```\n```c\nreturn\n```", theme_syntax);
    try testing.expect(shot.cell(1, 1).style.bold and !shot.cell(1, 1).style.dim);
}

test "python triple quotes and tabs render within width" {
    const a = testing.allocator;
    var shot: Shot = undefined;
    try shot.init(a, 20);
    defer shot.deinit(a);
    try testing.expectEqual(@as(u16, 2), drawText(&shot, "```py\n\"\"\"a\n\tb\"\"\" x\n```", theme_syntax));
    try shot.expect(a, &.{ " \"\"\"a", "     b\"\"\" x" });
    try testing.expectEqual(green, shot.cell(1, 0).style.fg);
    try testing.expectEqual(green, shot.cell(5, 1).style.fg);
    try testing.expect(shot.cell(10, 1).style.fg == .default);
}

test "syntax colored blocks stream like uncached ones" {
    const a = testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(a);
    var shot: Shot = undefined;
    try shot.init(a, 24);
    defer shot.deinit(a);
    var win = shot.win;
    const text = "x\n```zig\nconst a = \"é̈\"; /* open\n\tmore */ pub\n\\\\raw 中文 // z\n```\ntail";
    for ([_]u16{ 24, 9, 24 }) |width| {
        win.width = width;
        for (0..text.len + 1) |n| {
            if (!std.unicode.utf8ValidateSlice(text[0..n])) continue;
            try testing.expectEqual(print(win, text[0..n], theme_syntax, false), cache.draw(a, win, text[0..n], theme_syntax, false));
            win.clear();
            _ = print(win, text[0..n], theme_syntax, true);
            const expected = try a.dupe(vaxis.Cell, shot.screen.buf);
            defer a.free(expected);
            win.clear();
            _ = cache.draw(a, win, text[0..n], theme_syntax, true);
            try testing.expectEqualDeep(expected, shot.screen.buf);
        }
    }
}
