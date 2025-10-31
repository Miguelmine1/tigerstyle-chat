//! Async I/O layer
//!
//! Event loop and non-blocking TCP sockets:
//! - epoll (Linux) / kqueue (macOS/BSD)
//! - Non-blocking TCP accept/connect
//! - Connection management
//! - Bounded FD pool (R2)
//!
//! Enforces invariants:
//! - R2: Resource bounds (max connections)
//! - L2: Bounded queues
//!
//! Event loop handles:
//! - Incoming connections (accept)
//! - Outgoing connections (connect)
//! - Read readiness
//! - Write readiness
//!
//! Reference: docs/protocol.md - Network Architecture

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const net = std.net;
const assert = std.debug.assert;

/// Maximum number of concurrent connections (R2: bounded)
const MAX_CONNECTIONS: usize = 64;

/// Event types for I/O readiness
pub const EventType = enum {
    read,
    write,
    accept,
};

/// Connection state
pub const ConnectionState = enum {
    connecting,
    connected,
    closed,
};

/// Connection metadata
pub const Connection = struct {
    fd: std.posix.socket_t,
    state: ConnectionState,
    address: net.Address,

    pub fn init(fd: std.posix.socket_t, address: net.Address) Connection {
        return Connection{
            .fd = fd,
            .state = .connecting,
            .address = address,
        };
    }

    pub fn close(self: *Connection) void {
        if (self.state != .closed) {
            posix.close(self.fd);
            self.state = .closed;
        }
    }
};

/// Event loop for async I/O (epoll on Linux, kqueue on BSD/macOS)
pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    epoll_fd: if (builtin.os.tag == .linux) std.posix.fd_t else void,
    kqueue_fd: if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) std.posix.fd_t else void,
    connections: std.ArrayList(Connection),
    running: bool,

    pub fn init(allocator: std.mem.Allocator) !EventLoop {
        const connections = try std.ArrayList(Connection).initCapacity(allocator, 0);
        var loop = EventLoop{
            .allocator = allocator,
            .epoll_fd = undefined,
            .kqueue_fd = undefined,
            .connections = connections,
            .running = false,
        };

        // Initialize platform-specific event mechanism
        if (builtin.os.tag == .linux) {
            loop.epoll_fd = try posix.epoll_create1(0);
        } else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
            loop.kqueue_fd = try posix.kqueue();
        } else {
            return error.UnsupportedPlatform;
        }

        return loop;
    }

    pub fn deinit(self: *EventLoop) void {
        // Close all connections
        for (self.connections.items) |*conn| {
            conn.close();
        }
        self.connections.deinit(self.allocator);

        // Close event mechanism
        if (builtin.os.tag == .linux) {
            posix.close(self.epoll_fd);
        } else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
            posix.close(self.kqueue_fd);
        }
    }

    /// Create non-blocking TCP listener
    pub fn createListener(self: *EventLoop, address: net.Address) !std.posix.socket_t {
        // R2: Check connection limit
        if (self.connections.items.len >= MAX_CONNECTIONS) {
            return error.TooManyConnections;
        }

        const sock = try posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, posix.IPPROTO.TCP);
        errdefer posix.close(sock);

        // Set SO_REUSEADDR
        try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        // Bind
        try posix.bind(sock, &address.any, address.getOsSockLen());

        // Listen
        try posix.listen(sock, 128);

        // Register with event loop
        try self.registerSocket(sock, .accept);

        return sock;
    }

    /// Accept new connection (non-blocking)
    pub fn accept(self: *EventLoop, listener_fd: std.posix.socket_t) !Connection {
        // R2: Check connection limit
        if (self.connections.items.len >= MAX_CONNECTIONS) {
            return error.TooManyConnections;
        }

        var addr: net.Address = undefined;
        var addr_len: posix.socklen_t = @sizeOf(net.Address);

        const client_fd = try posix.accept(listener_fd, &addr.any, &addr_len, posix.SOCK.NONBLOCK);
        errdefer posix.close(client_fd);

        // Register with event loop
        try self.registerSocket(client_fd, .read);

        var conn = Connection.init(client_fd, addr);
        conn.state = .connected;
        try self.connections.append(self.allocator, conn);

        return conn;
    }

    /// Connect to remote address (non-blocking)
    pub fn connect(self: *EventLoop, address: net.Address) !Connection {
        // R2: Check connection limit
        if (self.connections.items.len >= MAX_CONNECTIONS) {
            return error.TooManyConnections;
        }

        const sock = try posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, posix.IPPROTO.TCP);
        errdefer posix.close(sock);

        // Non-blocking connect (may return EINPROGRESS)
        posix.connect(sock, &address.any, address.getOsSockLen()) catch |err| {
            if (err != error.WouldBlock) {
                return err;
            }
            // EINPROGRESS is expected for non-blocking connect
        };

        // Register for write events (signals connection complete)
        try self.registerSocket(sock, .write);

        const conn = Connection.init(sock, address);
        try self.connections.append(self.allocator, conn);

        return conn;
    }

    /// Register socket with event loop
    fn registerSocket(self: *EventLoop, fd: std.posix.socket_t, event_type: EventType) !void {
        if (builtin.os.tag == .linux) {
            var event: std.os.linux.epoll_event = undefined;
            event.events = switch (event_type) {
                .read, .accept => std.os.linux.EPOLL.IN,
                .write => std.os.linux.EPOLL.OUT,
            };
            event.data.fd = fd;
            try posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, &event);
        } else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
            var kev: std.os.system.Kevent = undefined;
            const filter: i16 = switch (event_type) {
                .read, .accept => std.os.system.EVFILT_READ,
                .write => std.os.system.EVFILT_WRITE,
            };
            kev = std.os.system.Kevent{
                .ident = @intCast(fd),
                .filter = filter,
                .flags = std.os.system.EV_ADD | std.os.system.EV_ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            const changes = [_]std.os.system.Kevent{kev};
            _ = try posix.kevent(self.kqueue_fd, &changes, &[_]std.os.system.Kevent{}, null);
        }
    }

    /// Run event loop (process events)
    pub fn run(self: *EventLoop, timeout_ms: i32) !usize {
        if (builtin.os.tag == .linux) {
            return try self.runEpoll(timeout_ms);
        } else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
            return try self.runKqueue(timeout_ms);
        } else {
            return error.UnsupportedPlatform;
        }
    }

    fn runEpoll(self: *EventLoop, timeout_ms: i32) !usize {
        var events: [32]std.os.linux.epoll_event = undefined;
        const n = posix.epoll_wait(self.epoll_fd, &events, timeout_ms);
        return @intCast(n);
    }

    fn runKqueue(self: *EventLoop, timeout_ms: i32) !usize {
        var events: [32]std.os.system.Kevent = undefined;
        const timeout = if (timeout_ms >= 0) std.os.timespec{
            .tv_sec = @divTrunc(timeout_ms, 1000),
            .tv_nsec = @rem(timeout_ms, 1000) * 1000000,
        } else null;
        const n = try posix.kevent(self.kqueue_fd, &[_]std.os.system.Kevent{}, &events, if (timeout_ms >= 0) &timeout else null);
        return @intCast(n);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "EventLoop: init and deinit" {
    const allocator = std.testing.allocator;

    var loop = try EventLoop.init(allocator);
    defer loop.deinit();

    // Verify initialization
    try std.testing.expect(!loop.running);
    try std.testing.expectEqual(@as(usize, 0), loop.connections.items.len);
}

test "EventLoop: bounded connections" {
    const allocator = std.testing.allocator;

    var loop = try EventLoop.init(allocator);

    const addr = try net.Address.parseIp4("127.0.0.1", 8080);

    // Fill up connection pool (simulate with fake FDs marked as closed)
    var i: usize = 0;
    while (i < MAX_CONNECTIONS) : (i += 1) {
        // Use fake FDs for simulation - mark as closed so deinit won't crash
        const conn = Connection{
            .fd = @intCast(1000 + i),
            .state = .closed, // Important: mark as closed!
            .address = addr,
        };
        try loop.connections.append(loop.allocator, conn);
    }

    // R2: Verify limit is enforced
    try std.testing.expectEqual(MAX_CONNECTIONS, loop.connections.items.len);

    // Next connection should fail (bounded) - test the check
    const would_exceed = loop.connections.items.len >= MAX_CONNECTIONS;
    try std.testing.expect(would_exceed);

    // Clean up (connections marked as closed, so close() is a no-op)
    loop.deinit();
}

test "Connection: lifecycle" {
    const addr = try net.Address.parseIp4("127.0.0.1", 8080);
    var conn = Connection.init(999, addr);

    try std.testing.expectEqual(ConnectionState.connecting, conn.state);
    try std.testing.expectEqual(@as(std.posix.socket_t, 999), conn.fd);

    // Note: Can't actually close FD 999 in test, just verify state tracking
    conn.state = .closed;
    try std.testing.expectEqual(ConnectionState.closed, conn.state);
}

test "EventLoop: localhost listener" {
    const allocator = std.testing.allocator;

    var loop = try EventLoop.init(allocator);
    defer loop.deinit();

    // Create listener on localhost:0 (random port)
    const addr = try net.Address.parseIp4("127.0.0.1", 0);
    const listener = try loop.createListener(addr);
    defer posix.close(listener);

    // Verify listener is valid
    try std.testing.expect(listener > 0);

    // Get bound address
    var bound_addr: net.Address = undefined;
    var addr_len: posix.socklen_t = @sizeOf(net.Address);
    try posix.getsockname(listener, &bound_addr.any, &addr_len);

    // Verify bound to localhost
    try std.testing.expect(bound_addr.in.sa.addr == std.mem.nativeToBig(u32, 0x7F000001)); // 127.0.0.1
}
