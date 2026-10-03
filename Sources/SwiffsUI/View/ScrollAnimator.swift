import AppKit
import SwiffsCore

/// What scrolling needs to know about the document and viewport.
protocol ScrollGeometry {
    var scrollTop: CGFloat { get }
    var viewportHeight: CGFloat { get }
    /// Height of the sticky header covering the top of the viewport.
    var stickyOffset: CGFloat { get }
    func clampScrollTop(_ value: CGFloat) -> CGFloat
    func targetRect(_ location: DiffScrollTarget.Location) -> CGRect?
}

extension DiffView: ScrollGeometry {}

/// Resolves scroll targets to offsets and steps a critically damped spring
/// toward them.
struct ScrollAnimator {
    private(set) var target: DiffScrollTarget?
    private var state: (position: CGFloat, velocity: CGFloat, timestamp: Double)?

    var isAnimating: Bool { target != nil }

    /// The scroll offset that shows a target, or nil when it is unknown or,
    /// for `.nearest`, already in view.
    func destination(for target: DiffScrollTarget, in geometry: some ScrollGeometry) -> CGFloat? {
        guard let target = resolved(target, in: geometry), let rect = geometry.targetRect(target.location) else { return nil }
        let sticky: CGFloat = if case .item = target.location { 0 } else { geometry.stickyOffset }
        let viewport = geometry.viewportHeight
        let top: CGFloat = switch target.alignment {
        case .center where rect.height < viewport: rect.minY - (viewport - rect.height) / 2
        case .end: rect.maxY - viewport
        default: rect.minY - sticky
        }
        return geometry.clampScrollTop(top)
    }

    /// Replaces `.nearest` with the edge to align, or nil when the target is
    /// already in view.
    private func resolved(_ target: DiffScrollTarget, in geometry: some ScrollGeometry) -> DiffScrollTarget? {
        guard target.alignment == .nearest else { return target }
        guard let rect = geometry.targetRect(target.location) else { return nil }
        let sticky: CGFloat = if case .item = target.location { 0 } else { geometry.stickyOffset }
        let visibleTop = geometry.scrollTop + sticky
        let visibleBottom = geometry.scrollTop + geometry.viewportHeight
        var resolved = target
        if rect.minY < visibleTop, rect.maxY <= visibleBottom {
            resolved.alignment = .start
        } else if rect.maxY > visibleBottom, rect.minY >= visibleTop {
            resolved.alignment = .end
        } else {
            return nil
        }
        return resolved
    }

    mutating func begin(target: DiffScrollTarget, from position: CGFloat, at now: Double, in geometry: some ScrollGeometry) {
        self.target = resolved(target, in: geometry)
        if state == nil { state = (position, 0, now) }
    }

    mutating func stop() {
        target = nil
        state = nil
    }

    /// Advances the spring to `now`, in milliseconds. Returns the new offset,
    /// or nil when there is nothing to animate; the animation ends when it
    /// settles.
    mutating func step(at now: Double, in geometry: some ScrollGeometry, settings: SmoothScrollSettings) -> CGFloat? {
        guard let target, let current = state, let destination = destination(for: target, in: geometry) else {
            stop()
            return nil
        }
        let dt = max(0, now - current.timestamp)
        let omega = settings.omega
        let decay = exp(-omega * dt)
        let displacement = Double(current.position - destination)
        let springCoefficient = Double(current.velocity) + omega * displacement
        let position = Double(destination) + (displacement + springCoefficient * dt) * decay
        let velocity = (springCoefficient * (1 - omega * dt) - omega * displacement) * decay
        if abs(position - Double(destination)) < settings.positionEpsilon, abs(velocity) < settings.velocityEpsilon {
            stop()
            return destination
        }
        state = (CGFloat(position), CGFloat(velocity), now)
        return CGFloat(position)
    }
}
