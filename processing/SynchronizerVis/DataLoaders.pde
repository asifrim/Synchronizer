// DataLoaders.pde — CSV / audio data loading and derived data structures.
// All functions populate global state declared in SynchronizerVis.pde.

void loadSegments() {
  File f = new File(dataPath(SEGMENTS_FILE));
  if (!f.exists()) return;  // segments are optional
  Table t = loadTable(SEGMENTS_FILE, "header");
  for (TableRow r : t.rows()) {
    segments.add(new Segment(
      r.getFloat("start_time"),
      r.getFloat("end_time"),
      r.getInt("label")
    ));
  }
}

void buildSegmentColors() {
  segmentColors = new color[N_SEGMENT_LABELS];
  colorMode(HSB, 360, 100, 100);
  // Distinct but muted hues — kept low-saturation so they don't overwhelm the
  // waveform strokes drawn on top.
  for (int i = 0; i < N_SEGMENT_LABELS; i++)
    segmentColors[i] = color(i * 360.0 / N_SEGMENT_LABELS + 25, 55, 80);
  colorMode(RGB, 255);
}

void loadGrid() {
  File f = new File(dataPath(GRID_FILE));
  if (!f.exists()) return;  // grid is optional
  Table t = loadTable(GRID_FILE, "header");
  for (TableRow r : t.rows()) {
    gridTicks.add(new GridTick(
      r.getFloat("time"),
      r.getInt("division"),
      r.getInt("beat"),
      r.getInt("phase")
    ));
  }
}

void buildDivisionColors() {
  divisionColors = new color[DIVISIONS.length];
  colorMode(HSB, 360, 100, 100);
  // Quarter = warm/bright; finer subdivisions shift cooler so denser rows read
  // as "background" pulse.
  for (int i = 0; i < DIVISIONS.length; i++)
    divisionColors[i] = color(45 + i * 55, 70, 95);
  colorMode(RGB, 255);
}

int divisionRow(int d) {
  for (int i = 0; i < DIVISIONS.length; i++) if (DIVISIONS[i] == d) return i;
  return DIVISIONS.length - 1;
}

void buildSnapTickArray() {
  // Snap targets = the 1/32 ticks. Coarser divisions are subsets of 1/32, so
  // snapping to the finest grid is sufficient.
  if (gridTicks.isEmpty()) { snapTickTimes = new float[0]; return; }
  int finest = DIVISIONS[DIVISIONS.length - 1];
  ArrayList<Float> times = new ArrayList<Float>();
  for (GridTick g : gridTicks)
    if (g.division == finest) times.add(g.t);
  snapTickTimes = new float[times.size()];
  for (int i = 0; i < times.size(); i++) snapTickTimes[i] = times.get(i);
}

float snapToNearestTick(float t) {
  // Binary-search the sorted snapTickTimes array; return the nearest tick if
  // within GRID_SNAP_TOLERANCE_S, otherwise return t unchanged.
  if (snapTickTimes == null || snapTickTimes.length == 0) return t;
  int lo = 0, hi = snapTickTimes.length;
  while (lo < hi) {
    int mid = (lo + hi) / 2;
    if (snapTickTimes[mid] < t) lo = mid + 1; else hi = mid;
  }
  float best = (lo < snapTickTimes.length) ? snapTickTimes[lo] : snapTickTimes[snapTickTimes.length - 1];
  if (lo > 0) {
    float prev = snapTickTimes[lo - 1];
    if (abs(prev - t) < abs(best - t)) best = prev;
  }
  return (abs(best - t) <= GRID_SNAP_TOLERANCE_S) ? best : t;
}

void applyGridSnap() {
  // Rebuild every event's visual time from origT. Idempotent.
  for (Event e : events)
    e.t = gridSnapEnabled ? snapToNearestTick(e.origT) : e.origT;
}

void loadMelody() {
  melodyNotes = new ArrayList<ArrayList<Note>>();
  for (int i = 0; i < MELODY_STEMS.length; i++) {
    ArrayList<Note> list = new ArrayList<Note>();
    melodyNotes.add(list);
    File f = new File(dataPath(MELODY_FILES[i]));
    if (!f.exists()) continue;  // each stem is independently optional
    Table t = loadTable(MELODY_FILES[i], "header");
    for (TableRow r : t.rows()) {
      list.add(new Note(
        r.getFloat("start_time"),
        r.getFloat("end_time"),
        r.getInt("pitch_midi"),
        r.getString("note_name"),
        r.getFloat("confidence")
      ));
    }
  }
}

void buildChromaColors() {
  // One hue per pitch class; C = red, ascending chromatically around the wheel.
  // Same color for the same note across octaves so the melodic shape reads
  // at a glance.
  chromaColors = new color[12];
  colorMode(HSB, 360, 100, 100);
  for (int i = 0; i < 12; i++) chromaColors[i] = color(i * 30, 75, 95);
  colorMode(RGB, 255);
}

color colorForMidi(int midi) {
  int pc = ((midi % 12) + 12) % 12;
  return chromaColors[pc];
}

void buildWaveformBuffer() {
  // Width matches drawWaveform: wLeft=40, wRight=panelLeft()-20 → wW=panelLeft()-60.
  int wW = (int)(panelLeft() - 60);
  int wH = 110;
  waveformBuffer = createGraphics(wW, wH, P2D);
  waveformBuffer.beginDraw();
  waveformBuffer.background(22);

  // Segment color bands drawn first; peak waveform layered on top.
  waveformBuffer.noStroke();
  for (Segment s : segments) {
    float x0 = constrain(s.startTime, 0, trackDuration) / trackDuration * wW;
    float x1 = constrain(s.endTime,   0, trackDuration) / trackDuration * wW;
    color c = segmentColors[constrain(s.label, 0, N_SEGMENT_LABELS - 1)];
    waveformBuffer.fill(red(c), green(c), blue(c), 90);
    waveformBuffer.rect(x0, 0, max(1, x1 - x0), wH);
  }

  waveformBuffer.stroke(220, 230, 245);
  waveformBuffer.strokeWeight(1);
  int   n   = wavePeaks.length;
  float mid = wH / 2.0;
  for (int px = 0; px < wW; px++) {
    int i0 = max(0,     (int)((float) px      / wW * n));
    int i1 = min(n - 1, (int)((float)(px + 1) / wW * n));
    float p = 0;
    for (int i = i0; i <= i1; i++) p = max(p, wavePeaks[i]);
    float h = p * (wH / 2) * 0.95;
    waveformBuffer.line(px, mid - h, px, mid + h);
  }
  waveformBuffer.endDraw();
}

int currentSegmentIndex(float now) {
  for (int i = 0; i < segments.size(); i++) {
    Segment s = segments.get(i);
    if (now >= s.startTime && now < s.endTime) return i;
  }
  return -1;
}

void buildPalettes() {
  palettes = new color[rowValues.length][];
  palettes[0] = new color[]{ color(90,90,100), color(60,110,220), color(90,200,130), color(240,100,100) };
  palettes[1] = new color[]{ color(40,70,130), color(200,170,60), color(250,240,200) };
  palettes[2] = new color[]{ color(90,80,120), color(160,130,200), color(220,80,230) };
  palettes[3] = new color[N_TIMBRE_CLUSTERS];
  palettes[4] = new color[N_TRANSIENT_CLUSTERS];
  colorMode(HSB, 360, 100, 100);
  for (int i = 0; i < N_TIMBRE_CLUSTERS; i++)
    palettes[3][i] = color(i * 360.0 / N_TIMBRE_CLUSTERS, 70, 95);
  for (int i = 0; i < N_TRANSIENT_CLUSTERS; i++)
    palettes[4][i] = color(i * 360.0 / N_TRANSIENT_CLUSTERS, 85, 100);
  colorMode(RGB, 255);
}
