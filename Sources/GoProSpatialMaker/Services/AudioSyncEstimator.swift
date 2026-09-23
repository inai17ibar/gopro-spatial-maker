import Foundation
import AVFoundation
import Accelerate

struct AudioSyncResult {
    /// Seconds to add to the target clip's time to reach the same instant as the reference clip.
    let offsetSeconds: Double
    /// Normalised cross-correlation peak (0...1). Values above ~0.3 are usually reliable.
    let confidence: Double
}

/// Estimates the time offset between two clips by cross-correlating their audio tracks.
enum AudioSyncEstimator {
    static let sampleRate: Double = 8000

    static func estimateOffset(reference: AVAsset, target: AVAsset, analysisDuration: Double) async throws -> AudioSyncResult {
        let refSamples = try await loadMonoSamples(asset: reference, duration: analysisDuration)
        let targetSamples = try await loadMonoSamples(asset: target, duration: analysisDuration)
        guard refSamples.count > Int(sampleRate), targetSamples.count > Int(sampleRate) else {
            throw SpatialMakerError.unsupported("音声が短すぎるため同期できません")
        }
        return try estimateOffset(reference: refSamples, target: targetSamples, sampleRate: sampleRate)
    }

    /// Pure DSP entry point (also used by unit tests).
    /// Returns the lag such that `target[t + offset] ≈ reference[t]`.
    static func estimateOffset(reference: [Float], target: [Float], sampleRate: Double) throws -> AudioSyncResult {
        let a = preprocess(reference)
        let b = preprocess(target)

        let n = nextPowerOfTwo(a.count + b.count)
        let log2n = vDSP_Length(log2(Double(n)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            throw SpatialMakerError.unsupported("FFTの初期化に失敗しました")
        }

        // 12 zeroed scratch planes: a, b (time), A, B (freq), A·conj(B), and the correlation result.
        let planeCount = 12
        let planes = UnsafeMutablePointer<Float>.allocate(capacity: n * planeCount)
        planes.initialize(repeating: 0, count: n * planeCount)
        defer { planes.deallocate() }
        func plane(_ i: Int) -> UnsafeMutablePointer<Float> { planes + i * n }

        a.withUnsafeBufferPointer { plane(0).update(from: $0.baseAddress!, count: a.count) }
        b.withUnsafeBufferPointer { plane(2).update(from: $0.baseAddress!, count: b.count) }

        let aTime = DSPSplitComplex(realp: plane(0), imagp: plane(1))
        let bTime = DSPSplitComplex(realp: plane(2), imagp: plane(3))
        var aFreq = DSPSplitComplex(realp: plane(4), imagp: plane(5))
        var bFreq = DSPSplitComplex(realp: plane(6), imagp: plane(7))
        var product = DSPSplitComplex(realp: plane(8), imagp: plane(9))
        var correlation = DSPSplitComplex(realp: plane(10), imagp: plane(11))

        fft.forward(input: aTime, output: &aFreq)
        fft.forward(input: bTime, output: &bFreq)
        // product = A · conj(B)
        vDSP_zvmul(&aFreq, 1, &bFreq, 1, &product, 1, vDSP_Length(n), -1)
        fft.inverse(input: product, output: &correlation)

        // c[k] = Σ a[n + k] · b[n]; with b[n] = a[n − d] the peak sits at k = −d.
        var peakIndex: vDSP_Length = 0
        var peakValue: Float = 0
        vDSP_maxvi(plane(10), 1, &peakValue, &peakIndex, vDSP_Length(n))

        var k = Int(peakIndex)
        if k > n / 2 { k -= n }
        let d = -k

        let energyA = vDSP.sumOfSquares(a)
        let energyB = vDSP.sumOfSquares(b)
        // Inverse FFT is unnormalised (scaled by n).
        let normalised = Double(peakValue) / Double(n) / sqrt(Double(energyA) * Double(energyB))

        return AudioSyncResult(
            offsetSeconds: Double(d) / sampleRate,
            confidence: max(0, min(1, normalised))
        )
    }

    // MARK: Helpers

    /// Removes DC, applies a first-order high-pass to attenuate wind rumble and normalises level.
    private static func preprocess(_ samples: [Float]) -> [Float] {
        guard samples.count > 1 else { return samples }
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))
        var centred = [Float](repeating: 0, count: samples.count)
        var negMean = -mean
        vDSP_vsadd(samples, 1, &negMean, &centred, 1, vDSP_Length(samples.count))

        var highPassed = [Float](repeating: 0, count: samples.count)
        let alpha: Float = 0.97
        var previousInput: Float = 0
        var previousOutput: Float = 0
        for i in 0..<centred.count {
            let x = centred[i]
            let y = alpha * (previousOutput + x - previousInput)
            highPassed[i] = y
            previousInput = x
            previousOutput = y
        }

        var rms: Float = 0
        vDSP_rmsqv(highPassed, 1, &rms, vDSP_Length(highPassed.count))
        guard rms > 0 else { return highPassed }
        var scale = 1 / rms
        var normalised = [Float](repeating: 0, count: highPassed.count)
        vDSP_vsmul(highPassed, 1, &scale, &normalised, 1, vDSP_Length(highPassed.count))
        return normalised
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var n = 1
        while n < value { n <<= 1 }
        return n
    }

    /// Decodes the first `duration` seconds of the asset's first audio track to mono Float32 at `sampleRate`.
    static func loadMonoSamples(asset: AVAsset, duration: Double) async throws -> [Float] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SpatialMakerError.noAudioTrack((asset as? AVURLAsset)?.url ?? URL(fileURLWithPath: "/"))
        }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw SpatialMakerError.readerFailed(reader.error?.localizedDescription ?? "audio")
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(duration * sampleRate))
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = chunk.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            if status == kCMBlockBufferNoErr {
                samples.append(contentsOf: chunk)
            }
        }
        if reader.status == .failed {
            throw SpatialMakerError.readerFailed(reader.error?.localizedDescription ?? "audio")
        }
        return samples
    }
}
