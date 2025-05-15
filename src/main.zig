const std = @import("std");
const time = std.time;
const builtin = @import("builtin");

const windows = @import("windows.zig");

const TerminalSize = windows.TerminalSize;

var stdout: std.fs.File.Writer = undefined;
var buffered: std.io.BufferedWriter(4096, std.fs.File.Writer) = undefined;
var writer: @TypeOf(buffered).Writer = undefined;

var global_state: ?*State = null;

const State = struct {
    size: TerminalSize,
    characters: []const u8 = "qwertyuiopasdfghjklzxcvbnmMNBVCXZLKJHGFDSAPOIUYTREWQ1234567890",
    prng: std.Random.Xoshiro256,
    resize_needed: bool = false,
    map: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !State {
        const seed: u64 = @intCast(std.time.timestamp());
        const prng = std.Random.DefaultPrng.init(seed);

        const size = try windows.getTerminalSize();

        const map = try allocator.alloc(u8, size.rows * size.cols);
        for (map) |*cell| {
            cell.* = ' ';
        }

        return State{
            .size = size,
            .prng = prng,
            .map = map,
            .resize_needed = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.map);
    }

     pub fn updateMap(self: *State) !void {
        const rand = self.prng.random();

        var row: usize = self.size.rows;
        while (row > 0) : (row -= 1) {
            const current_row = row - 1;
            const y = current_row * self.size.cols;

            for (0..self.size.cols) |col| {
                const current_index = y + col;
                if (current_index >= self.map.len) continue;

                const cell = self.map[current_index];
                if (cell != ' ' and current_row < self.size.rows - 1) {
                    const next_index = current_index + self.size.cols;
                    if (next_index < self.map.len) {
                        self.map[next_index] = cell;
                        self.map[current_index] = ' ';
                    }
                }
            }

            if (row == 1) {
                for (0..self.size.cols) |col| {
                    if (rand.intRangeAtMost(usize, 0, 100) < 5) {
                        const new_char = try self.getRandomChar();
                        self.map[col] = new_char;
                    } else if (self.map[col] != ' ') {
                        self.map[col] = ' ';
                    }
                }
            }
        }
    }

    pub fn drawMap(self: *State) !void {
        try writer.writeAll("\x1b[s");
        try writer.writeAll("\x1b[H");
        try buffered.flush();

        for (self.map, 0..) |cell, i| {
            if (i % self.size.cols == 0 and i != 0) {
                try writer.writeAll("\n");
            }
            const row = i / self.size.cols;
            if (row == self.size.rows - 1) {
                try writer.writeAll("\x1b[91m");
                try writer.writeByte(cell);
            } else if (cell != ' ') {
                try writer.writeAll("\x1b[92m");
                try writer.writeByte(cell);
            } else {
                try writer.writeAll("\x1b[0m");
                try writer.writeByte(cell);
            }
        }

        try writer.writeAll("\x1b[u");
        try buffered.flush();
    }

    pub inline fn updateTerminalSize(self: *State) !void {
        const newSize = try windows.getTerminalSize();
        if (newSize.rows != self.size.rows or newSize.cols != self.size.cols) {
            try self.resize(newSize);
        }
    }

    pub fn resize(self: *State, newSize: TerminalSize) !void {
        self.size = newSize;
        self.map = try self.allocator.realloc(self.map, newSize.rows * newSize.cols);
        for (self.map) |*cell| {
            cell.* = ' ';
        }
    }

    pub fn getRandomChar(self: *State) !u8 {
        const rand = self.prng.random();
        const random_index = rand.intRangeAtMost(usize, 0, self.characters.len - 1);
        return self.characters[random_index];
    }
};

fn clearScreen() !void {
    try stdout.writeAll("\x1b[2J\x1b[H");
}

fn setupSignalHandler() void {
    windows.setupSignalHandler(handleSignal);
}

fn handleSignal(crtlType: windows.Term.DWORD) callconv(windows.Term.WIN_API) windows.Term.BOOL {
    if (crtlType == windows.Term.CRTL_C_EVENT) {
        stdout.writeAll("\x1b[?25h") catch {};
        stdout.writeAll("\x1b[2J\x1b[H") catch {};
        std.process.exit(0);
    }

    return 0;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout_file = std.io.getStdOut();
    stdout = stdout_file.writer();
    buffered = std.io.bufferedWriter(stdout);
    writer = buffered.writer();

    try stdout.writeAll("\x1b[?251");

    try clearScreen();

    setupSignalHandler();
    
    windows.enableAnsiEscapes();

    var state = try State.init(allocator);
    defer state.deinit();
    global_state = &state;

    while (true) {
        try state.updateTerminalSize();

        try state.updateMap();
        try state.drawMap();
        time.sleep(20 * time.ns_per_ms);
    }
}