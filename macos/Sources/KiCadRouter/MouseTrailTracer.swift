// Ported from KiCad 10.0.7: pcbnew/router/pns_mouse_trail_tracer.h and pns_mouse_trail_tracer.cpp.
// Copyright The KiCad Developers, see KiCad's AUTHORS.txt.
// GNU General Public License version 3 or later, as KiCad (see KICAD-NOTICE.md).

import Foundation

/// Which way a trace should leave its start, read from the way the pointer went (KiCad's MOUSE_TRAIL_TRACER): the
/// trail kept, and whichever of a straight or a diagonal first segment fits it better
public final class MouseTrailTracer {
    private var trail = LineChain()
    public var tolerance = 0
    private var direction = Direction45()
    private var lastSegDirection = Direction45()
    private var forced = false
    public var mouseDisabled = false
    public private(set) var isManuallyForced = false

    public init() {}

    public func clear() {
        forced = false
        isManuallyForced = false
        trail.clear()
    }

    public func setDefaultDirections(_ initial: Direction45, _ lastSeg: Direction45) {
        direction = initial
        lastSegDirection = lastSeg
    }

    public func addTrailPoint(_ p: IPoint) {
        if trail.segmentCount == 0 {
            trail.append(p)
        } else {
            let sNew = Seg(trail.lastPoint, p)
            if trail.segmentCount > 2 {
                let limit = tolerance * tolerance
                for i in 0..<(trail.segmentCount - 2) where trail.segment(i).squaredDistance(sNew) <= limit {
                    trail = trail.slice(0, i)
                    break
                }
            }
            trail.append(p)
        }
        trail.simplify()
        Router.dbg("mt-trail: \(trail.points)")
    }

    public func posture(_ p: IPoint) -> Direction45 {
        // how much better a fit one posture's must be, how much to damp flutter, and how far out (in tolerances) the
        // area test starts, the posture is locked in, and is unlocked again
        let areaRatioThreshold = 1.3, areaRatioEpsilon = 0.25, minAreaCutoffDistanceFactor = 6.0
        let lockDistanceFactor = 30, unlockDistanceFactor = 10
        if trail.pointCount < 2 || isManuallyForced {
            if !isManuallyForced && lastSegDirection.isDefined {
                direction = mouseDisabled ? lastSegDirection.right : lastSegDirection
            }
            return direction
        }
        let p0 = trail.point(0)
        let refLength = Double(Seg(p0, p).length)
        var straight = Direction45().buildInitialTrace(p0, p, startDiagonal: false)
        straight.setClosed(true)
        straight.append(trail.reversed())
        straight.simplify()
        let areaS = straight.area()
        var diag = Direction45().buildInitialTrace(p0, p, startDiagonal: true)
        diag.append(trail.reversed())
        diag.setClosed(true)
        diag.simplify()
        let areaDiag = diag.area()
        let ratio = areaS / (areaDiag + 1.0)
        Router.dbg("mt-straight: \(straight.points)")
        Router.dbg("mt-diag: \(diag.points)")
        // dragged back to the start: the posture free again, the trail begun again
        if forced && refLength < Double(unlockDistanceFactor * tolerance) {
            forced = false
            let start = p0
            trail.clear()
            trail.append(start)
        }
        var areaOk = false
        // (a trail nearly straight is no guide: no flutter)
        if !forced && refLength > minAreaCutoffDistanceFactor * Double(tolerance) {
            let areaCutoff = Double(tolerance) * refLength
            var t = trail
            t.setClosed(true)
            if t.area() > areaCutoff { areaOk = true }
        }
        Router.dbg(String(format: "Posture: rl %d thr %d tol %d as %.3f area OK %d forced %d", Int(refLength),
                          Int(minAreaCutoffDistanceFactor) * tolerance * 10 / 6, tolerance, ratio, areaOk ? 1 : 0, forced ? 1 : 0))
        let straightDirection = Direction45(straight.segment(0))
        let diagDirection = Direction45(diag.segment(0))
        var newDirection: Direction45
        if !forced && areaOk && ratio > areaRatioThreshold + areaRatioEpsilon {
            newDirection = diagDirection
        } else if !forced && areaOk && ratio < (1.0 / areaRatioThreshold) - areaRatioEpsilon {
            newDirection = straightDirection
        } else {
            newDirection = direction.isDiagonal ? diagDirection : straightDirection
        }
        if !mouseDisabled && newDirection != direction { direction = newDirection }
        // a last segment: the direction set against it, for the least obtuse exit
        if !isManuallyForced && !mouseDisabled && lastSegDirection.isDefined {
            if straightDirection == lastSegDirection {
                direction = straightDirection
            } else if diagDirection == lastSegDirection {
                direction = diagDirection
            } else {
                switch direction.angle(lastSegDirection) {
                case .halfFull:
                    direction = direction.isDiagonal ? straightDirection : diagDirection
                case .acute:
                    let candidate = direction.isDiagonal ? straightDirection : diagDirection
                    if candidate.angle(lastSegDirection) == .right { direction = candidate }
                case .right:
                    let candidate = direction.isDiagonal ? straightDirection : diagDirection
                    if candidate.angle(lastSegDirection) == .obtuse { direction = candidate }
                default:
                    break
                }
            }
        }
        // far from the start: the posture locked in
        if !forced && refLength > Double(lockDistanceFactor * tolerance) { forced = true }
        return direction
    }

    public func flipPosture() {
        direction = direction.right
        forced = true
        isManuallyForced = true
    }

    public var trailLeadVector: IPoint { trail.pointCount < 2 ? .zero : trail.lastPoint - trail.point(0) }
}
