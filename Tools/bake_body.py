#!/usr/bin/env python3
"""Bake a MakeHuman (CC0) adult athletic male into Cinder's body.mesh resource.

Pipeline: base.obj + caucasian-male-young morph (1.0) + male maxmuscle morph
(0.55) -> extract `body` group -> normalize (height 1.75, feet y=0, torso at
x=z=0, facing +z) -> smooth vertex normals -> classify vertices into 17 muscle
groups (Swift MuscleGroup.allCases order) using limb-axis frames -> binary out.

Format: 'CMB1', u32 vertCount, u32 indexCount, pos f32*3, normal f32*3,
muscleId i16, blend f32, indices u32.
"""
import numpy as np
import struct, sys, os

D = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(D, 'mh-base.obj')
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(D, 'body.mesh')
MUSCLE_W = float(sys.argv[2]) if len(sys.argv) > 2 else 0.55

GROUPS = ['chest','frontDelts','sideDelts','rearDelts','biceps','triceps','forearms',
          'traps','lats','upperBack','lowerBack','abs','obliques','glutes','quads',
          'hamstrings','calves']
G = {name: i for i, name in enumerate(GROUPS)}

# ---- parse base -------------------------------------------------------------
verts, faces, group = [], [], None
for line in open(SRC):
    if line.startswith('v '):
        verts.append([float(x) for x in line.split()[1:4]])
    elif line.startswith('g '):
        group = line.split(None, 1)[1].strip()
    elif line.startswith('f ') and group == 'body':
        faces.append([int(t.split('/')[0]) - 1 for t in line.split()[1:]])

V = np.array(verts, dtype=np.float64)

# ---- apply morph targets ------------------------------------------------------
def apply_target(path, w):
    n = 0
    for line in open(path):
        if line.startswith('#') or not line.strip():
            continue
        parts = line.split()
        i = int(parts[0])
        if i < len(V):
            V[i] += w * np.array([float(parts[1]), float(parts[2]), float(parts[3])])
            n += 1
    print(f"applied {os.path.basename(path)} x{w} ({n} deltas)")

apply_target(os.path.join(D, 'male-young.target'), 1.0)
apply_target(os.path.join(D, 'male-muscle.target'), MUSCLE_W)

# ---- extract body -------------------------------------------------------------
used = sorted(set(i for f in faces for i in f))
remap = {old: new for new, old in enumerate(used)}
P = V[used]
quads = np.array([[remap[i] for i in f] for f in faces], dtype=np.int64)
tris = np.concatenate([quads[:, [0, 1, 2]], quads[:, [0, 2, 3]]])

# ---- normalize ------------------------------------------------------------------
ymin, ymax = P[:, 1].min(), P[:, 1].max()
s = 1.75 / (ymax - ymin)
P = P * s
P[:, 1] -= ymin * s
band = P[(P[:, 1] > 0.95) & (P[:, 1] < 1.35) & (np.abs(P[:, 0]) < 0.16)]
P[:, 2] -= np.median(band[:, 2])
P = P.astype(np.float32)

# ---- landmarks ---------------------------------------------------------------------
X = np.abs(P[:, 0]); Y = P[:, 1]; Z = P[:, 2]
Pm = P.copy(); Pm[:, 0] = X

sh = P[(Y > 1.32) & (Y < 1.52) & (X > 0.17) & (X < 0.30)]
SHOULDER = np.array([np.abs(sh[:, 0]).mean(), sh[:, 1].mean(), sh[:, 2].mean()])

armv = Pm[X > SHOULDER[0] + 0.02]
xmax = armv[:, 0].max()
WRIST_X = xmax - 0.075
wb = armv[(armv[:, 0] > WRIST_X - 0.015) & (armv[:, 0] < WRIST_X + 0.015)]
WRIST = wb.mean(axis=0)

crotch_band = P[(np.abs(P[:, 0]) < 0.02)]
CROTCH_Y = crotch_band[(crotch_band[:, 1] > 0.5) & (crotch_band[:, 1] < 1.0)][:, 1].min()
ank = Pm[(Y > 0.05) & (Y < 0.11) & (X > 0.02)]
ANKLE = np.array([ank[:, 0].mean(), 0.08, ank[:, 2].mean()])
hipv = Pm[(Y > CROTCH_Y + 0.02) & (Y < CROTCH_Y + 0.10) & (X > 0.02)]
HIP = np.array([hipv[:, 0].mean(), hipv[:, 1].mean(), hipv[:, 2].mean()])
print("SHOULDER", SHOULDER.round(3), "WRIST", WRIST.round(3))
print("CROTCH_Y", round(float(CROTCH_Y), 3), "HIP", HIP.round(3), "ANKLE", ANKLE.round(3))

ARM_DIRV = WRIST - SHOULDER
ARM_LEN = np.linalg.norm(ARM_DIRV); ARM_DIR = ARM_DIRV / ARM_LEN
LEG_DIRV = ANKLE - HIP
LEG_LEN = np.linalg.norm(LEG_DIRV); LEG_DIR = LEG_DIRV / LEG_LEN

# ---- classify ------------------------------------------------------------------------
N = len(P)
ids = np.full(N, -1, dtype=np.int16)

def along(origin, direction, length):
    rel = Pm - origin
    t = rel @ direction / length
    radial = rel - np.outer(t * length, direction)
    return t, radial

# arms: two segments (shoulder->elbow->wrist) so the bent arm is followed.
t0_arm = (Pm - SHOULDER) @ ARM_DIR / ARM_LEN
rough = (t0_arm > -0.05) & (t0_arm < 1.05) & (X > SHOULDER[0] + 0.01)
ELBOW = Pm[rough & (t0_arm > 0.44) & (t0_arm < 0.54)].mean(axis=0)

def seg_frame(a, b):
    d = b - a
    L = np.linalg.norm(d); d = d / L
    rel = Pm - a
    t = rel @ d / L
    radial = rel - np.outer(t * L, d)
    f = np.array([0, 0, 1.0]) - d[2] * d
    f /= np.linalg.norm(f)
    return t, np.linalg.norm(radial, axis=1), radial @ f

# delts: cap around the shoulder joint.
dist_sh = np.linalg.norm(Pm - SHOULDER, axis=1)
delt = (ids == -1) & (dist_sh < 0.085) & (Y > SHOULDER[1] - 0.08)
zrel = Z - SHOULDER[2]
ids[delt & (zrel > 0.030)] = G['frontDelts']
ids[delt & (zrel < -0.038)] = G['rearDelts']
ids[delt & (ids == -1)] = G['sideDelts']

# upper arm.
t_u, r_u, fr_u = seg_frame(SHOULDER, ELBOW)
upper = (ids == -1) & (t_u > 0.10) & (t_u < 1.0) & (r_u < 0.085) & (X > SHOULDER[0] - 0.02)
mid_u = np.median(fr_u[upper]) if upper.any() else 0.0
ids[upper & (fr_u >= mid_u)] = G['biceps']
ids[upper & (fr_u < mid_u)] = G['triceps']

# forearm.
t_f, r_f, _ = seg_frame(ELBOW, WRIST)
fore = (ids == -1) & (t_f > 0.0) & (t_f < 1.0) & (r_f < 0.075) & (X > SHOULDER[0])
ids[fore] = G['forearms']

# glutes before legs
glute = (ids == -1) & (Y > CROTCH_Y - 0.03) & (Y < CROTCH_Y + 0.17) & (Z < -0.03) & (X < 0.17)
ids[glute] = G['glutes']

# legs
t_leg, rad_leg = along(HIP, LEG_DIR, LEG_LEN)
leg_r = np.linalg.norm(rad_leg, axis=1)
is_leg = (ids == -1) & (Y < CROTCH_Y + 0.13) & (t_leg > -0.18) & (t_leg < 1.0) & (leg_r < 0.14)

leg_front = np.array([0, 0, 1.0]) - LEG_DIR[2] * LEG_DIR
leg_front /= np.linalg.norm(leg_front)
leg_frontness = rad_leg @ leg_front

thigh = is_leg & (t_leg < 0.48)
mid_t = np.median(leg_frontness[thigh]) if thigh.any() else 0.0
ids[thigh & (leg_frontness >= mid_t)] = G['quads']
ids[thigh & (leg_frontness < mid_t)] = G['hamstrings']
calf = is_leg & (t_leg >= 0.54) & (t_leg < 0.97)
mid_c = np.median(leg_frontness[calf]) if calf.any() else 0.0
ids[calf & (leg_frontness < mid_c)] = G['calves']

# torso
torso = (ids == -1) & (Y >= CROTCH_Y + 0.03) & (Y < 1.54) & (X < 0.26)
front_t = torso & (Z > 0.005)
back_t = torso & (Z < -0.005)

ids[front_t & (Y > 1.26) & (Y < 1.45) & (X < 0.21)] = G['chest']
ids[front_t & (Y > CROTCH_Y + 0.08) & (Y <= 1.26) & (X < 0.085)] = G['abs']
obl = (ids == -1) & torso & (Y > CROTCH_Y + 0.06) & (Y <= 1.28) & (X >= 0.085) & (X < 0.20) & (Z > -0.06)
ids[obl] = G['obliques']

ids[back_t & (Y > 1.44)] = G['traps']
ids[(ids == -1) & torso & (Y > 1.47) & (Z <= 0.02) & (X > 0.045) & (X < 0.20)] = G['traps']
ids[back_t & (Y > 1.36) & (Y <= 1.44) & (X < 0.21)] = G['upperBack']
ids[(ids == -1) & back_t & (Y > 1.02) & (Y <= 1.36) & (X >= 0.065)] = G['lats']
ids[(ids == -1) & back_t & (Y > CROTCH_Y + 0.06) & (Y <= 1.15) & (X < 0.08)] = G['lowerBack']

counts = {name: int((ids == i).sum()) for name, i in G.items()}
print("assigned:", counts)
print("base:", int((ids == -1).sum()), "of", N)

# ---- smooth normals -------------------------------------------------------------------
Nrm = np.zeros_like(P)
p0, p1, p2 = P[tris[:, 0]], P[tris[:, 1]], P[tris[:, 2]]
fn = np.cross(p1 - p0, p2 - p0)
for k in range(3):
    np.add.at(Nrm, tris[:, k], fn)
lens = np.linalg.norm(Nrm, axis=1, keepdims=True)
lens[lens == 0] = 1
Nrm = (Nrm / lens).astype(np.float32)

# ---- soft edge blend --------------------------------------------------------------------
from collections import defaultdict
neigh = defaultdict(set)
for a, b, c in tris:
    neigh[a].update((b, c)); neigh[b].update((a, c)); neigh[c].update((a, b))
blend = np.zeros(N, dtype=np.float32)
for v in range(N):
    if ids[v] < 0:
        continue
    ns = neigh[v]
    same = sum(1 for n in ns if ids[n] == ids[v])
    blend[v] = 0.45 + 0.55 * (same / max(len(ns), 1))

# ---- write ----------------------------------------------------------------------------
with open(OUT, 'wb') as f:
    f.write(b'CMB1')
    f.write(struct.pack('<II', N, len(tris) * 3))
    f.write(P.astype('<f4').tobytes())
    f.write(Nrm.astype('<f4').tobytes())
    f.write(ids.astype('<i2').tobytes())
    f.write(blend.astype('<f4').tobytes())
    f.write(tris.astype('<u4').tobytes())
print(f"wrote {OUT}: {N} verts, {len(tris)} tris, {os.path.getsize(OUT)/1e6:.1f} MB")
