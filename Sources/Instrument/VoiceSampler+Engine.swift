import AudioEngine

/// The conformance that lets a `VoiceSampler` be driven by the transport. It lives in its own file
/// because it is the only place `Instrument` touches `AudioEngine`: the sampler itself is testable
/// without an engine, which is what keeps its offline test suite honest.
extension VoiceSampler: ScheduledSource {
    public func transportDidStart(_ transport: Transport) {
        transportDidStart(originSampleTime: Int64(transport.originSampleTime),
                          sampleRate: transport.sampleRate)
    }
}
