// Layout.pde — coordinate helpers shared between drawing and hit-testing.
// All values are computed from width/height at call time so the sketch
// tolerates a future resize without layout constants going stale.

// --- Right panel -------------------------------------------------------------

// Right panel occupies the rightmost 352px.
float panelLeft() { return width - 352; }
float panelW()    { return 342; }

// --- Left-column event grid --------------------------------------------------

float gridLeft()   { return 140; }
float gridRight()  { return panelLeft() - 20; }
float gridTop()    { return 90; }
float gridBottom() { return height - 650; }
float rowHeight()  { return (gridBottom() - gridTop()) / rowValues.length; }
float cellSize()   { return min(rowHeight() * 0.7, 48); }

// --- Melody panel ------------------------------------------------------------
// Three rows (vocals / bass / other) of pitched note bars sharing the event
// grid's horizontal extent so notes line up with the onset events above.

float melodyTop()         { return height - 630; }
float melodyBottom()      { return height - 295; }
float melodyRowH()        { return (melodyBottom() - melodyTop()) / MELODY_STEMS.length; }
float melodyRowY(int row) { return melodyTop() + row * melodyRowH() + melodyRowH() / 2; }

// --- Metronome grid panel ----------------------------------------------------
// Sits between the melody panel and the waveform; shares horizontal extent so
// ticks line up with the onset events above.

float metroTop()         { return height - 275; }
float metroBottom()      { return height - 185; }
float metroRowH()        { return (metroBottom() - metroTop()) / DIVISIONS.length; }
float metroRowY(int row) { return metroTop() + row * metroRowH() + metroRowH() / 2; }

// --- Shared page / event coordinate helpers ----------------------------------

float pageStartFor(float now) {
  return ((int)(now / PAGE_DURATION_S)) * PAGE_DURATION_S;
}

float eventX(Event e, float pageStart) {
  return gridLeft() + (e.t - pageStart) / PAGE_DURATION_S * (gridRight() - gridLeft());
}

float rowCenterY(int row) {
  return gridTop() + row * rowHeight() + rowHeight() / 2;
}

// --- Right-panel cluster layout ----------------------------------------------
// Each cluster gets an equal vertical slice of the full panel height.
//
// Within each cluster section the layout (relative to panelClusterY(c)) is:
//   32  .. 162   envelope curve (130 px)
//   174 .. 349   sliders A/D/S/R (centre Y at 174, 218, 262, 306)
//   362 .. 395   LIN/EXP shape toggle row
//   412 .. 441   CC level meter

float panelClusterH()         { return (height - 60) / (float)N_TRANSIENT_CLUSTERS; }
float panelClusterY(int c)    { return 40 + c * panelClusterH(); }

float panelCurveT(int c)      { return panelClusterY(c) + 32; }
float panelCurveB(int c)      { return panelCurveT(c) + 130; }
float panelSliderY(int c, int p) { return panelClusterY(c) + 174 + p * 44; }
float panelToggleY(int c)     { return panelClusterY(c) + 174 + 4 * 44 + 18; }
float panelMeterY(int c)      { return panelClusterY(c) + 174 + 4 * 44 + 60; }

// --- ADSR slider track -------------------------------------------------------
// Shared geometry for all four sliders in a cluster section.

float slTrackL()        { return panelLeft() + 62; }
float slTrackR()        { return panelLeft() + panelW() - 14; }
float slTrackW()        { return slTrackR() - slTrackL(); }
float slValX(float v)   { return slTrackL() + constrain(v, 0, 1) * slTrackW(); }
float slXtoVal(float mx){ return constrain((mx - slTrackL()) / slTrackW(), 0, 1); }

// --- Stem MIDI range helpers (used by drawMelody in Draw.pde) ----------------
// Values mirror the pyin search ranges in synchronizer/melody.py.

int stemPitchLo(int stemIdx) {
  switch (MELODY_STEMS[stemIdx]) {
    case "vocals": return 40;   // E2
    case "bass":   return 24;   // C1
    case "other":  return 36;   // C2
    default:       return 36;
  }
}

int stemPitchHi(int stemIdx) {
  switch (MELODY_STEMS[stemIdx]) {
    case "vocals": return 84;   // C6
    case "bass":   return 72;   // C5
    case "other":  return 96;   // C7
    default:       return 96;
  }
}
