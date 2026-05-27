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
// Always 8 cluster panels; the k-selector strip sits at the very top.
// Each cluster gets a compact equal slice (≈127 px at 1080px height).
//
// Within each cluster section (relative to panelClusterY(c)):
//   2  .. 18    header label strip
//   20 .. 58    envelope curve (38 px)
//   62 .. 98    sliders A/D/S/R (centre Y at 62, 74, 86, 98)
//   112         CC level meter centre
//
// LIN/EXP shape toggles are omitted — no room in compact mode.

float panelKSelectorY()       { return 28; }  // centre Y of the k-selector button row
float panelClusterH()         { return (height - 60) / (float)N_TRANSIENT_CLUSTERS; }
float panelClusterY(int c)    { return 40 + c * panelClusterH(); }

float panelCurveT(int c)      { return panelClusterY(c) + 20; }
float panelCurveB(int c)      { return panelCurveT(c) + 38; }
float panelSliderY(int c, int p) { return panelClusterY(c) + 62 + p * 12; }
float panelMeterY(int c)      { return panelClusterY(c) + 112; }

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
