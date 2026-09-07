//
//  MuscleGroup.swift
//  MuscleMapKit
//
//  The gym-vocabulary muscle groups rendered by MuscleBody3DView. Each case is
//  one selectable/colorable region of the 3D body (mirrored left/right where
//  anatomical). Kept deliberately coarse — this matches how lifters log and
//  think ("chest day"), not medical nomenclature.
//
//  SERIALIZED ASSET CONTRACT: `allCases` order is the muscle-id order stored
//  in Resources/body.mesh. Reordering or inserting a case silently repaints
//  the body onto the wrong muscles. Tests pin this order.
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

    /// Index stored per vertex in `body.mesh`. Must match `allCases` order.
    public var meshIndex: Int {
        switch self {
        case .chest: return 0
        case .frontDelts: return 1
        case .sideDelts: return 2
        case .rearDelts: return 3
        case .biceps: return 4
        case .triceps: return 5
        case .forearms: return 6
        case .traps: return 7
        case .lats: return 8
        case .upperBack: return 9
        case .lowerBack: return 10
        case .abs: return 11
        case .obliques: return 12
        case .glutes: return 13
        case .quads: return 14
        case .hamstrings: return 15
        case .calves: return 16
        }
    }

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
