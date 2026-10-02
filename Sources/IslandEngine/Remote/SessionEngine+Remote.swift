import Foundation
import OpenIslandCore

/// SSH remote sessions in the engine (P745 to P748): the host each came from, its flag, its jump, and the end of a
/// removed host's sessions.
extension SessionEngine {
    /// The host a remote session came in from; nil for a local one.
    public func remoteHost(for sessionID: String) -> RemoteSessionDirectory.Entry? { remoteSessions.entry(for: sessionID) }

    /// The tunnels for the app's set-up hosts, relaying to this engine's bridge and request broker.
    public func makeRemoteTunnels(launcher: TunnelLauncher = .ssh) -> RemoteTunnels {
        RemoteTunnels(endpoints: RemoteRelay.Endpoints(bridge: configuration.socketURL, broker: configuration.hookRequestsSocketURL),
                      directory: remoteSessions, launcher: launcher)
    }

    /// A removed host's sessions end (upstream keeps a remote session alive for as long as hooks may come, and none
    /// will), and the directory forgets them.
    public func endRemoteSessions(hostID: String) {
        for sessionID in remoteSessions.sessions(onHost: hostID) where state.session(id: sessionID) != nil {
            dismiss(sessionID: sessionID)
        }
        remoteSessions.forget(host: hostID)
    }

    /// A session the relay filed under a host is remote, whatever the event that made it said: the process monitor never
    /// ends it, as no local process runs it (P745). A session restored after a relaunch becomes remote again here, at its
    /// next hook.
    func markRemoteIfKnown(_ sessionID: String) {
        guard remoteSessions.entry(for: sessionID) != nil, var session = state.session(id: sessionID), !session.isRemote else { return }
        session.isRemote = true
        replace(session)
    }

    /// The local ssh tab to the session's host, read now (the owner's click), off the main thread.
    func remoteJumpTarget(_ remote: RemoteSessionDirectory.Entry, workspace: String) async -> (JumpTarget, JumpContext)? {
        let processes = dependencies.remoteProcesses
        let ports = dependencies.localPorts
        let appForPID = dependencies.appForPID
        return await Task.detached(priority: .userInitiated) {
            guard let output = processes(),
                  let process = RemoteJump.pick(RemoteJump.sshProcesses(psOutput: output), destination: remote.destination,
                                                clientPort: remote.context.sshClientPort, localPorts: ports) else { return nil }
            return RemoteJump.target(for: process, workspace: workspace, appForPID: appForPID)
        }.value
    }
}
