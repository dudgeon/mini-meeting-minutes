import ArgumentParser
import MinutesCore

/// How the recording screen looks. Press K to switch while recording.
enum Look: String, CaseIterable, ExpressibleByArgument, Sendable {
    /// Calm, in the style of Claude's apps: a sidebar of status beside the transcript. The default.
    case sidebar
    /// A pixel-art sunset over a neon grid, whose skyline is the live spectrum analyzer.
    case synthwave

    var next: Look { self == .sidebar ? .synthwave : .sidebar }

    /// Draws a frame. Also returns how many transcript rows can be scrolled back.
    func render(
        _ state: LiveState.Snapshot, analyzers: [Channel: SpectrumAnalyzer], width: Int, height: Int, time: Double,
        frameInterval: Double
    ) -> (canvas: Canvas, maxScroll: Int) {
        switch self {
        case .sidebar:
            SidebarView.render(
                state, analyzers: analyzers, width: width, height: height, time: time, frameInterval: frameInterval)
        case .synthwave:
            SynthwaveView.render(
                state, analyzers: analyzers, width: width, height: height, time: time, frameInterval: frameInterval)
        }
    }
}
