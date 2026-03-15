import Foundation
import simd

public enum GCodeParserError: Error, LocalizedError {
    case unsupportedInput

    public var errorDescription: String? {
        switch self {
        case .unsupportedInput:
            return "Unable to parse this G-code input."
        }
    }
}

public struct GCodeParser {
    public let defaultLineWidth: Float
    public let defaultLayerHeight: Float

    public init(defaultLineWidth: Float = 0.42, defaultLayerHeight: Float = 0.2) {
        self.defaultLineWidth = defaultLineWidth
        self.defaultLayerHeight = defaultLayerHeight
    }

    public func parse(_ gcode: String, maxLayer: Int? = nil) throws -> PrintModel {
        guard gcode.contains(where: { !$0.isWhitespace }) else {
            throw GCodeParserError.unsupportedInput
        }

        var state = ParserState(
            lineWidth: defaultLineWidth,
            layerHeight: defaultLayerHeight
        )
        var segments: [Segment] = []

        gcode.enumerateLines { rawLine, stop in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                return
            }

            let pieces = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            let commandPart = pieces.first.map(String.init) ?? ""
            let commentPart = pieces.count > 1 ? String(pieces[1]) : ""

            apply(comment: commentPart, to: &state)

            let trimmedCommand = commandPart.trimmingCharacters(in: .whitespaces)
            if trimmedCommand.isEmpty {
                return
            }

            let shouldStop = apply(
                commandLine: trimmedCommand,
                state: &state,
                segments: &segments,
                maxLayer: maxLayer
            )
            if shouldStop {
                stop = true
            }
        }

        return PrintModel(segments: segments, buildPlate: state.buildPlate)
    }
}

private struct ParserState {
    var position = SIMD3<Float>(0, 0, 0)
    var extruderPosition: Float = 0
    var absoluteXYZ = true
    var absoluteExtruder = true
    var layerIndex = 0
    var currentLayerZ: Float = .nan
    var moveType: MoveType = .unknown
    var filamentIndex = 0
    var lineWidth: Float
    var layerHeight: Float
    var buildPlate: BuildPlate?
    /// Amount of filament currently retracted (0 when not retracted).
    var retractedAmount: Float = 0
}

private extension GCodeParser {
    func apply(comment: String, to state: inout ParserState) {
        let normalized = comment.uppercased()

        if let buildPlate = parseBuildPlate(from: comment) {
            state.buildPlate = buildPlate
        }

        if normalized.contains("TYPE:SUPPORT") ||
            normalized.contains("FEATURE: SUPPORT") ||
            normalized.contains("SUPPORT-INTERFACE") {
            state.moveType = .support
        } else if normalized.contains("TYPE:WALL") || normalized.contains("PERIMETER") {
            state.moveType = .perimeter
        } else if normalized.contains("TYPE:FILL") || normalized.contains("INFILL") {
            state.moveType = .infill
        } else if normalized.contains("TYPE:SKIRT") || normalized.contains("BRIM") {
            state.moveType = .skirt
        }

        if let width = extractCommentFloat(normalized, keys: ["LINE_WIDTH", "WIDTH", "EXTRUSION_WIDTH"]) {
            state.lineWidth = max(width, 0.01)
        }

        if let height = extractCommentFloat(normalized, keys: ["LAYER_HEIGHT", "HEIGHT"]) {
            state.layerHeight = max(height, 0.01)
        }
    }

    func apply(commandLine: String, state: inout ParserState, segments: inout [Segment], maxLayer: Int?) -> Bool {
        let tokens = commandLine.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else {
            return false
        }

        guard let commandIndex = tokens.firstIndex(where: { isCommandToken($0) }) else {
            return false
        }

        let rawCommand = tokens[commandIndex].uppercased()
        let args = Array(tokens.dropFirst(commandIndex + 1))

        // Normalize commands: extract letter prefix and numeric ID so that
        // G00/G01 are treated the same as G0/G1.
        let commandLetter = rawCommand.first
        let commandNumber = commandLetter.flatMap { _ in Int(rawCommand.dropFirst()) }

        switch (commandLetter, commandNumber) {
        case ("G", 90):
            state.absoluteXYZ = true
        case ("G", 91):
            state.absoluteXYZ = false
        case ("M", 82):
            state.absoluteExtruder = true
        case ("M", 83):
            state.absoluteExtruder = false
        case ("G", 92):
            applySetPosition(args: args, state: &state)
        case ("G", 0), ("G", 1):
            let isRapid = commandNumber == 0
            return applyLinearMove(args: args, isRapid: isRapid, state: &state, segments: &segments, maxLayer: maxLayer)
        case ("G", 2), ("G", 3):
            let clockwise = commandNumber == 2
            return applyArcMove(args: args, clockwise: clockwise, state: &state, segments: &segments, maxLayer: maxLayer)
        case ("T", let n?) where n >= 0:
            state.filamentIndex = n
        default:
            break
        }

        return false
    }

    func applySetPosition(args: [String], state: inout ParserState) {
        for token in args {
            let upper = token.uppercased()
            guard let prefix = upper.first, let value = Float(upper.dropFirst()) else {
                continue
            }

            switch prefix {
            case "X": state.position.x = value
            case "Y": state.position.y = value
            case "Z": state.position.z = value
            case "E": state.extruderPosition = value
            default: continue
            }
        }
    }

    func applyLinearMove(args: [String], isRapid: Bool, state: inout ParserState, segments: inout [Segment], maxLayer: Int?) -> Bool {
        var nextPosition = state.position
        var hasExtruderValue = false
        var nextExtruder = state.extruderPosition

        for token in args {
            let upper = token.uppercased()
            guard let prefix = upper.first, let value = Float(upper.dropFirst()) else {
                continue
            }

            switch prefix {
            case "X":
                nextPosition.x = state.absoluteXYZ ? value : nextPosition.x + value
            case "Y":
                nextPosition.y = state.absoluteXYZ ? value : nextPosition.y + value
            case "Z":
                nextPosition.z = state.absoluteXYZ ? value : nextPosition.z + value
            case "E":
                hasExtruderValue = true
                nextExtruder = state.absoluteExtruder ? value : nextExtruder + value
            default:
                continue
            }
        }

        if state.currentLayerZ.isNaN {
            state.currentLayerZ = nextPosition.z
        } else if nextPosition.z > state.currentLayerZ + 0.000_1 {
            state.layerIndex += 1
            state.currentLayerZ = nextPosition.z
        }

        let didMove = simd_length(nextPosition - state.position) > 0.000_1
        let extrusionDelta = hasExtruderValue ? nextExtruder - state.extruderPosition : 0

        // Track retraction state so we can distinguish real extrusion from
        // pressure restoration (unretract).  When the nozzle is retracted the
        // first positive-E movement just restores filament pressure — it does
        // not deposit material and must not produce a rendered segment.
        var realExtrusion: Float = 0
        if extrusionDelta < -0.000_01 {
            // Retraction (or wipe): accumulate the retracted amount.
            state.retractedAmount += abs(extrusionDelta)
        } else if extrusionDelta > 0.000_01 {
            if state.retractedAmount > 0.000_01 {
                // Part or all of this E advance is pressure restoration.
                realExtrusion = max(extrusionDelta - state.retractedAmount, 0)
                state.retractedAmount = max(state.retractedAmount - extrusionDelta, 0)
            } else {
                realExtrusion = extrusionDelta
            }
        }

        let isExtrusion = !isRapid && didMove && realExtrusion > 0.000_01

        let canAppend = maxLayer.map { state.layerIndex <= $0 } ?? true
        if isExtrusion && canAppend {
            let moveType = state.moveType == .travel ? .unknown : state.moveType
            segments.append(
                Segment(
                    start: state.position,
                    end: nextPosition,
                    width: state.lineWidth,
                    layerHeight: state.layerHeight,
                    moveType: moveType,
                    filamentIndex: state.filamentIndex,
                    layerIndex: state.layerIndex
                )
            )
        }

        state.position = nextPosition
        if hasExtruderValue {
            state.extruderPosition = nextExtruder
        }

        if let maxLayer {
            return state.layerIndex > maxLayer
        }
        return false
    }

    // MARK: - G2/G3 Arc moves

    /// Linearise a G2 (clockwise) / G3 (counter-clockwise) arc into short
    /// line segments so that position tracking and extrusion classification
    /// stay correct even when arc-fitting is enabled in the slicer.
    func applyArcMove(
        args: [String],
        clockwise: Bool,
        state: inout ParserState,
        segments: inout [Segment],
        maxLayer: Int?
    ) -> Bool {
        // Resolve target coordinates to absolute values regardless of mode.
        var targetX = state.position.x
        var targetY = state.position.y
        var targetZ = state.position.z
        var hasExtruderValue = false
        var nextExtruder = state.extruderPosition
        var offsetI: Float = 0
        var offsetJ: Float = 0

        for token in args {
            let upper = token.uppercased()
            guard let prefix = upper.first, let value = Float(upper.dropFirst()) else {
                continue
            }
            switch prefix {
            case "X": targetX = state.absoluteXYZ ? value : state.position.x + value
            case "Y": targetY = state.absoluteXYZ ? value : state.position.y + value
            case "Z": targetZ = state.absoluteXYZ ? value : state.position.z + value
            case "I": offsetI = value
            case "J": offsetJ = value
            case "E":
                hasExtruderValue = true
                nextExtruder = state.absoluteExtruder ? value : state.extruderPosition + value
            default: continue
            }
        }

        // Centre of the arc (always relative to the start position).
        let cx = state.position.x + offsetI
        let cy = state.position.y + offsetJ

        // Vectors from center to start / end points.
        let sx = state.position.x - cx, sy = state.position.y - cy
        let ex = targetX - cx, ey = targetY - cy

        let startAngle = atan2(sy, sx)
        let radius = hypot(sx, sy)

        // Use cross/dot product to get the signed angle between the two
        // radii.  This avoids the atan2 ±π discontinuity that would
        // otherwise turn tiny arcs near 180° into near-full circles.
        let cross = sx * ey - sy * ex   // |s|·|e|·sin(θ)
        let dot   = sx * ex + sy * ey   // |s|·|e|·cos(θ)
        var sweep = atan2(cross, dot)    // signed angle, –π … +π

        // Adjust so that the sweep direction matches the command:
        //   G2 (CW)  → sweep must be negative
        //   G3 (CCW) → sweep must be positive
        // A sweep of exactly 0 means a full circle (start == end).
        if clockwise {
            if sweep > 0 { sweep -= 2 * .pi }
            if sweep == 0 { sweep = -2 * .pi }
        } else {
            if sweep < 0 { sweep += 2 * .pi }
            if sweep == 0 { sweep = 2 * .pi }
        }

        let absSweep = abs(sweep)

        // Linearise: one segment per ~2 mm of arc length (at least 4 segments).
        let arcLen = radius * absSweep
        let stepCount = max(Int(ceil(arcLen / 2)), 4)

        let totalExtrusionDelta = hasExtruderValue ? nextExtruder - state.extruderPosition : 0
        let zDelta = targetZ - state.position.z
        let ePerStep = hasExtruderValue ? totalExtrusionDelta / Float(stepCount) : 0
        let angleStep = sweep / Float(stepCount)

        // Save starting values to compute absolute positions for each step
        // independently of how applyLinearMove updates state.
        let startPos = state.position
        let startE = state.extruderPosition

        // Temporarily force absolute mode so synthetic args are unambiguous.
        let savedAbsXYZ = state.absoluteXYZ
        let savedAbsE = state.absoluteExtruder
        state.absoluteXYZ = true
        state.absoluteExtruder = true

        for i in 1 ... stepCount {
            let t = Float(i)
            let angle = startAngle + angleStep * t

            let stepX, stepY, stepZ: Float
            if i == stepCount {
                // Snap last step to the exact target to avoid float drift.
                stepX = targetX; stepY = targetY; stepZ = targetZ
            } else {
                stepX = cx + radius * cos(angle)
                stepY = cy + radius * sin(angle)
                stepZ = startPos.z + zDelta * (t / Float(stepCount))
            }

            var synArgs = [
                "X\(stepX)",
                "Y\(stepY)",
                "Z\(stepZ)"
            ]
            if hasExtruderValue {
                // Absolute E target for this step.
                let stepE = startE + ePerStep * t
                synArgs.append("E\(stepE)")
            }

            let shouldStop = applyLinearMove(
                args: synArgs,
                isRapid: false,
                state: &state,
                segments: &segments,
                maxLayer: maxLayer
            )
            if shouldStop {
                state.absoluteXYZ = savedAbsXYZ
                state.absoluteExtruder = savedAbsE
                return true
            }
        }

        state.absoluteXYZ = savedAbsXYZ
        state.absoluteExtruder = savedAbsE
        return false
    }

    func isCommandToken(_ token: String) -> Bool {
        guard let first = token.uppercased().first else {
            return false
        }
        return first == "G" || first == "M" || first == "T"
    }

    func extractCommentFloat(_ comment: String, keys: [String]) -> Float? {
        for key in keys {
            guard let keyRange = comment.range(of: key) else {
                continue
            }

            let tail = comment[keyRange.upperBound...]
            if let parsed = parseLeadingFloat(in: tail) {
                return parsed
            }
        }
        return nil
    }

    func parseLeadingFloat(in text: Substring) -> Float? {
        let allowed: Set<Character> = ["+", "-", ".", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
        var buffer = ""
        var started = false

        for char in text {
            if char == ":" || char == "=" || char.isWhitespace {
                if started {
                    break
                }
                continue
            }

            if allowed.contains(char) {
                buffer.append(char)
                started = true
                continue
            }

            if started {
                break
            }
        }

        return Float(buffer)
    }

    func parseBuildPlate(from comment: String) -> BuildPlate? {
        let normalized = comment.uppercased()
        guard normalized.contains("BED_SHAPE") || normalized.contains("PRINTABLE_AREA") else {
            return nil
        }

        let pattern = #"(-?\d+(?:\.\d+)?)\s*[xX]\s*(-?\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsRange = NSRange(comment.startIndex..<comment.endIndex, in: comment)
        let matches = regex.matches(in: comment, range: nsRange)

        var points: [SIMD2<Float>] = []
        points.reserveCapacity(matches.count)

        for match in matches {
            guard let xRange = Range(match.range(at: 1), in: comment),
                  let yRange = Range(match.range(at: 2), in: comment),
                  let x = Float(comment[xRange]),
                  let y = Float(comment[yRange]) else {
                continue
            }

            points.append(SIMD2<Float>(x, y))
        }

        guard let firstPoint = points.first else {
            return nil
        }

        var minX = firstPoint.x
        var maxX = firstPoint.x
        var minY = firstPoint.y
        var maxY = firstPoint.y

        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        guard maxX - minX > 0.1, maxY - minY > 0.1 else {
            return nil
        }

        return BuildPlate(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }
}
