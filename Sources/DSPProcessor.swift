import Foundation

final class DSPProcessor {
    let processingGain: Float = 1.0
    let unityGain: Float = 1.0
    let bassBoostEnabled = true
    let bassBoostCutoffHz: Float = 160.0
    let bassBoostAmount: Float = 1.0
    let startupRampDuration: TimeInterval = 0.40
    let shutdownRampDuration: TimeInterval = 0.25
    let routeChangeRampDuration: TimeInterval = 0.15

    func configureInitialGain(on ringBuffer: RealtimeRingBuffer) {
        ringBuffer.setGainImmediate(unityGain)
    }

    func configureBassBoost(on ringBuffer: RealtimeRingBuffer, sampleRate: Double) {
        ringBuffer.configureBassBoost(
            enabled: bassBoostEnabled,
            sampleRate: sampleRate,
            cutoffHz: bassBoostCutoffHz,
            amount: bassBoostAmount
        )
    }

    func requestProcessingGainRamp(
        on ringBuffer: RealtimeRingBuffer,
        sampleRate: Double
    ) {
        ringBuffer.requestGainRamp(
            targetGain: processingGain,
            rampFrames: rampFrameCount(sampleRate: sampleRate, duration: startupRampDuration)
        )
    }

    func requestUnityGainRamp(
        on ringBuffer: RealtimeRingBuffer,
        sampleRate: Double,
        duration: TimeInterval
    ) {
        ringBuffer.requestGainRamp(
            targetGain: unityGain,
            rampFrames: rampFrameCount(sampleRate: sampleRate, duration: duration)
        )
    }

    private func rampFrameCount(sampleRate: Double, duration: TimeInterval) -> UInt32 {
        max(UInt32((sampleRate * duration).rounded(.up)), 1)
    }
}
