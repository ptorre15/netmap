import Vapor

// MARK: - WebSocket broadcaster (actor for thread safety)
//
// Usage:
//   await WebSocketBroadcaster.shared.add(ws)      — called from the WS upgrade handler
//   await WebSocketBroadcaster.shared.broadcast(msg) — called after every record insert

public actor WebSocketBroadcaster {
    public static let shared = WebSocketBroadcaster()

    private var clients: [WebSocket] = []

    public func add(_ ws: WebSocket) {
        clients.append(ws)

        ws.onClose.whenComplete { [weak self] _ in
            guard let self else { return }
            Task { await self.remove(ws) }
        }
    }

    private func remove(_ ws: WebSocket) {
        clients.removeAll { $0 === ws }
    }

    /// Send a pre-encoded JSON string to all open connections.
    public func broadcast(_ text: String) async {
        var dead: [Int] = []
        for (i, ws) in clients.enumerated() {
            guard !ws.isClosed else { dead.append(i); continue }
            try? await ws.send(text)
        }
        for i in dead.reversed() { clients.remove(at: i) }
    }
}

// MARK: - Application storage key so routes.swift can access the same instance

extension Application {
    var wsBroadcaster: WebSocketBroadcaster { .shared }
}

// MARK: - Log broadcaster (admin log-stream WebSocket clients)

public actor LogBroadcaster {
    public static let shared = LogBroadcaster()

    private var clients: [WebSocket] = []

    public func add(_ ws: WebSocket) {
        clients.append(ws)
        ws.onClose.whenComplete { [weak self] _ in
            guard let self else { return }
            Task { await self.remove(ws) }
        }
    }

    private func remove(_ ws: WebSocket) {
        clients.removeAll { $0 === ws }
    }

    /// Broadcast a single log entry JSON to all open admin log viewers.
    public func broadcast(_ text: String) async {
        var dead: [Int] = []
        for (i, ws) in clients.enumerated() {
            guard !ws.isClosed else { dead.append(i); continue }
            try? await ws.send(text)
        }
        for i in dead.reversed() { clients.remove(at: i) }
    }
}
