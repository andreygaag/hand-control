import Testing
@testable import HandControlCore

/// Real messages captured from appleh13camerad (macOS 26, FaceTime HD), including the lines
/// that must NOT be counted.
enum DaemonLine {
    static let connect = "ConnectClient: Added client [81510] <private> <<private>>"
    static let disconnect = "DisconnectClient: Removed client [81510] <<private>>"
    static let tcc = "SEND: 0/7 synchronous to com.apple.tccd.system: request: msgID=524.68, function=TCCAccessRequest, service=kTCCServiceCamera, target_token={pid:89067, auid:501, euid:501},"
    static let tccNoPid = "TCCAccessRequest() IPC"
    static let start = "CMIOExtensionProvider.m:3553:-[CMIOExtensionProvider _clientQueue_startStreamForClientID:streamID:requestAudio:requestVideo:reply:] <CMIOExtensionProvider>: start streaming for client <CMIOExtensionClient: pid -, clientID ->"
    static let stop = "CMIOExtensionProvider.m:3652:-[CMIOExtensionProvider stopStreamForClientID:streamID:reply:]_block_invoke <CMIOExtensionProvider>, stop streaming for client <CMIOExtensionClient: pid -, clientID ->"
    static let addAttribution = "CMIOExtensionProvider.m:4066:-[CMIOExtensionProvider _addSystemStatusAttributionsForClient:stream:requestVideo:requestAudio:]_block_invoke <CMIOExtensionProvider>: added attribution <private> with key 1FD4B3A2-236E-492B-8CE5-255DD288CE50_67C3B6C4-D1D7-4113-BCB2-37640B3CBDF8, for <CMIOExtensionClient: pid -, clientID ->"
    static let removedAttribution = "CMIOExtensionProvider.m:4140:-[CMIOExtensionProvider _removeSystemStatusAttributionsForClient:stream:allowAudioRemoval:]_block_invoke Removed attribution <private> with key 1FD4B3A2-236E-492B-8CE5-255DD288CE50_67C3B6C4-D1D7-4113-BCB2-37640B3CBDF8"
    static let notFoundAttribution = "CMIOExtensionProvider.m:4145:-[CMIOExtensionProvider _removeSystemStatusAttributionsForClient:stream:allowAudioRemoval:]_block_invoke Couldn't find attribution to remove, 67C3B6C4-D1D7-4113-BCB2-37640B3CBDF8, 1FD4B3A2-236E-492B-8CE5-255DD288CE50 <CMIOExtensionClient: pid -, clientID ->"
    static let removeAttempt = "CMIOExtensionProvider.m:4089:-[CMIOExtensionProvider _removeSystemStatusAttributionsForClient:stream:allowAudioRemoval:] _removeSystemStatusAttributionsForClient for client <private>"
    static let newConnection = "CMIOExtensionProvider.m:2400:-[CMIOExtensionProvider finishProviderContextRegistration:]_block_invoke New connection(<CMIOExtensionClient: pid -, clientID ->)"
    static let startInternal = "CMIOExtensionProvider.m:3357:-[CMIOExtensionProvider startStreamForClientID:streamID:reply:] <CMIOExtensionProvider>, <private>"
}

@Suite struct CameraClientsTests {
    @Test func parsesRealDaemonLines() {
        #expect(CameraClients.parse(DaemonLine.connect) == .connected(81510))
        #expect(CameraClients.parse(DaemonLine.disconnect) == .disconnected(81510))
        #expect(CameraClients.parse(DaemonLine.tcc) == .streamRequested(89067))
        #expect(CameraClients.parse(DaemonLine.addAttribution) == .streamStarted)
        #expect(CameraClients.parse(DaemonLine.removedAttribution) == .streamStopped)
    }

    // start/stop streaming lines are ignored on purpose: a killed client logs no stop.
    // The retry after a clean stop ("Couldn't find ...") must not count as a second stop.
    @Test(arguments: [DaemonLine.tccNoPid, DaemonLine.start, DaemonLine.stop, DaemonLine.notFoundAttribution,
                      DaemonLine.removeAttempt, DaemonLine.startInternal, DaemonLine.newConnection, "",
                      "ConnectClient: Added client [] x", "ConnectClient: Added client [99999999999] x",
                      DaemonLine.tcc.replacingOccurrences(of: "kTCCServiceCamera", with: "kTCCServiceMicrophone")])
    func ignoresOtherLines(_ line: String) {
        #expect(CameraClients.parse(line) == nil)
    }

    func state(_ events: [CameraClients.Event]) -> CameraClients {
        var c = CameraClients()
        events.forEach { c.apply($0) }
        return c
    }

    @Test func tracksForeignStreamsAndCandidates() {
        let me: Int32 = 100
        let c = state([.connected(me), .streamRequested(me), .streamStarted,
                       .connected(300), .connected(200), .streamRequested(200), .streamStarted])
        #expect(c.foreignStreams(own: 1) == 1)
        // 200 started a stream, so it is listed before the merely connected 300.
        #expect(c.candidates(excluding: me) == [200, 300])
    }

    // Daemon sequence for a clean stop, then exit: add → Removed at stop → Couldn't find at exit.
    @Test func cleanStopScenario() {
        let lines = [DaemonLine.connect, DaemonLine.tcc, DaemonLine.start, DaemonLine.addAttribution,
                     DaemonLine.stop, DaemonLine.removeAttempt, DaemonLine.removedAttribution,
                     DaemonLine.removeAttempt, DaemonLine.notFoundAttribution, DaemonLine.disconnect]
        #expect(state(lines.compactMap(CameraClients.parse)).activeStreams == 0)
    }

    // Client killed mid-stream: no stop line, attribution removed on disconnect.
    @Test func killedClientScenario() {
        let lines = [DaemonLine.connect, DaemonLine.start, DaemonLine.addAttribution,
                     DaemonLine.removeAttempt, DaemonLine.removedAttribution, DaemonLine.disconnect]
        let c = state(lines.compactMap(CameraClients.parse))
        #expect(c.activeStreams == 0)
        #expect(c.connected.isEmpty)
    }

    @Test func streamRequestWithoutConnectIsNotACandidate() {
        #expect(state([.streamRequested(200)]).candidates(excluding: 1).isEmpty)
    }

    @Test func disconnectForgetsProcess() {
        let c = state([.connected(200), .streamRequested(200), .disconnected(200)])
        #expect(c.connected.isEmpty)
        #expect(c.startedStream.isEmpty)
    }

    @Test func stopBeforeStartNeverGoesNegative() {
        let c = state([.streamStopped, .streamStopped, .streamStarted])
        #expect(c.activeStreams == 1)
        #expect(c.foreignStreams(own: 1) == 0)
        #expect(c.foreignStreams(own: 2) == 0)
    }

    @Test func reconcileClearsStaleStreams() {
        var c = state([.streamStarted, .streamStarted])
        c.reconcileNothingRunning()
        #expect(c.activeStreams == 0)
    }
}
