import Accelerate
import Foundation

/// What the main window's display shows.
enum VisualizerMode: Sendable, CaseIterable {
    case spectrum, scope, off

    var next: VisualizerMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// A spectrum analyzer for one channel: log-spaced frequency bars from 80 Hz to 7.5 kHz that
/// jump up instantly and fall back slowly, with peak caps that hold, then drop.
final class SpectrumAnalyzer {
    static let fftSize = 1024
    private static let log2n = vDSP_Length(10)

    private let setup: FFTSetup
    private let window: [Float]
    private(set) var levels: [Double] = []
    private(set) var peaks: [Double] = []
    private var holds: [Double] = []

    init() {
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.fftSize, isHalfWindow: false)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Advances the bars by `elapsed` seconds using the newest audio (16 kHz).
    func update(samples: [Float], bars: Int, elapsed: Double) {
        if levels.count != bars {
            levels = Array(repeating: 0, count: bars)
            peaks = levels
            holds = levels
        }
        let targets = bands(of: samples, count: bars)
        for bar in 0..<bars {
            levels[bar] = max(targets[bar], levels[bar] - 1.6 * elapsed)
            if levels[bar] >= peaks[bar] {
                peaks[bar] = levels[bar]
                holds[bar] = 0.6
            } else if holds[bar] > 0 {
                holds[bar] -= elapsed
            } else {
                peaks[bar] = max(levels[bar], peaks[bar] - 0.5 * elapsed)
            }
        }
    }

    /// Band energies scaled to 0...1.
    private func bands(of samples: [Float], count: Int) -> [Double] {
        let n = Self.fftSize
        guard samples.count >= n, count > 0 else { return Array(repeating: 0, count: count) }
        let windowed = vDSP.multiply(Array(samples.suffix(n)), window)
        var real = [Float](repeating: 0, count: n / 2)
        var imaginary = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        let binHz = 16_000.0 / Double(n)
        let low = 80.0, high = 7_500.0
        return (0..<count).map { band in
            let from = low * pow(high / low, Double(band) / Double(count))
            let to = low * pow(high / low, Double(band + 1) / Double(count))
            let first = max(1, Int(from / binHz))
            let last = max(first, min(n / 2 - 1, Int(to / binHz)))
            let strongest = power[first...last].max() ?? 0
            let decibels = 10 * log10(Double(strongest) + 1e-9)
            return min(1, max(0, (decibels - 4) / 40))
        }
    }
}
