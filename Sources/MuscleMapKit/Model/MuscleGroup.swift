//
//  MuscleGroup.swift
//  Cinder
//
//  The gym-vocabulary muscle groups rendered by MuscleBody3DView. Each case is
//  one selectable/colorable region of the 3D body (mirrored left/right where
//  anatomical). Kept deliberately coarse — this matches how lifters log and
//  think ("chest day"), not medical nomenclature.
//

import Foundation

public enum MuscleGroup: String, CaseIterable, Codable, Identifiable, Sendable {
    case chest
    case frontDelts
    case sideDelts
    case rearDelts
    case biceps
    case triceps
    case forearms
    case traps
    case lats
    case upperBack
    case lowerBack
    case abs
    case obliques
    case glutes
    case quads
    case hamstrings
    case calves

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chest:      return "Chest"
        case .frontDelts: return "Front Delts"
        case .sideDelts:  return "Side Delts"
        case .rearDelts:  return "Rear Delts"
        case .biceps:     return "Biceps"
        case .triceps:    return "Triceps"
        case .forearms:   return "Forearms"
        case .traps:      return "Traps"
        case .lats:       return "Lats"
        case .upperBack:  return "Upper Back"
        case .lowerBack:  return "Lower Back"
        case .abs:        return "Abs"
        case .obliques:   return "Obliques"
        case .glutes:     return "Glutes"
        case .quads:      return "Quads"
        case .hamstrings: return "Hamstrings"
        case .calves:     return "Calves"
        }
    }
}

// MARK: - Preset splits

/// Named training splits — used by the muscle picker (select a whole day's
/// muscles at once) and handy for coach features.
enum MuscleSplit: String, CaseIterable, Identifiable {
    case pushDay = "Push Day"
    case pullDay = "Pull Day"
    case legDay = "Leg Day"
    case upperBody = "Upper Body"
    case lowerBody = "Lower Body"
    case fullBody = "Full Body"
    case core = "Core"

    var id: String { rawValue }

    var muscles: Set<MuscleGroup> {
        switch self {
        case .pushDay:
            return [.chest, .frontDelts, .sideDelts, .triceps]
        case .pullDay:
            return [.lats, .upperBack, .traps, .rearDelts, .biceps, .forearms]
        case .legDay:
            return [.quads, .hamstrings, .glutes, .calves, .lowerBack]
        case .upperBody:
            return [.chest, .frontDelts, .sideDelts, .rearDelts, .biceps,
                    .triceps, .forearms, .traps, .lats, .upperBack]
        case .lowerBody:
            return [.quads, .hamstrings, .glutes, .calves]
        case .fullBody:
            return Set(MuscleGroup.allCases)
        case .core:
            return [.abs, .obliques, .lowerBack]
        }
    }
}
