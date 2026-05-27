// SynchronizerVis — paginated event grid + waveform thumbnail.
//
// Layout (top to bottom):
//   - HUD line
//   - Event grid: 5 rows (pitch, brightness, energy, duration, timbre).
//     Each event is a vertical stack of 5 colored cells, positioned by its
//     start_time within the current page window. Cells flash on onset and
//     fade through the transient's duration.
//   - Metronome grid: 4 rows (1/4, 1/8, 1/16, 1/32 note ticks), beat-anchored
//     so they follow the detected tempo. Each tick flashes as the playhead
//     crosses it; on-beat ticks (phase 0) are taller/brighter.
//   - Waveform thumbnail: full-track peaks; current page window highlighted;
//     playhead marker shows position in the entire track.
//
// Keys:
//   space         play / pause
//   ← / →         page back / forward
//   r             jump to start
//   q             toggle grid-snap (events near a 1/32 tick snap to it; the
//                 onset and beat-tracking algorithms place a "kick on the
//                 beat" a few ms apart, so without snap the rect centers
//                 sit just off the ticks)
//   - / =         slow down / speed up (0.25x steps, range 0.25x–2.0x; alters pitch)
//   e             toggle the per-cluster ADSR envelope editor
//   m             toggle MIDI output on/off
//   0-9           (grid) reassign hovered event's cluster; (editor) select cluster to edit
//   ctrl/cmd+s    save: editor open -> ADSR config; else event edits to <basename>_v<N>.csv
//
// Mouse:
//   left-click on an event        toggle disabled (excluded from saved CSV)
//   shift+left-click on an event  preview: plays from onset for its duration, then stops
//   right-click + drag on cell    drag up = higher bucket value
//                                 (drag down = lower), per-row bucket ladder
//   (editor open) drag handles    reshape the selected cluster's ADSR envelope
//
// MIDI output (drives TouchDesigner): as the playhead crosses each transient,
// an ADSR envelope is emitted as a 7-bit MIDI CC. Each transient_cluster has
// its own ADSR shape and its own CC. Contract (do not change without updating
// the TD patch): MIDI channel 1; cluster i -> CC (BASE_CC + i); value 0-127,
// sent only when it changes. Envelope total time = the transient's duration
// (floored at MIN_ENV_S). Smooth the 7-bit stepping in TD with a Lag/Filter
// CHOP. Sent to the virtual port whose name contains MIDI_PORT_NAME (loopMIDI
// on Windows); if absent, the sketch runs as a visualizer with MIDI off.
//
// Data files in data/:
//   <AUDIO_FILE>   the audio that plays (WAV/MP3/AIFF/OGG — Processing Sound
//                  does NOT support FLAC)
//   <CSV_FILE>     events from `synchronizer ... -o ...`
//   <WAVE_FILE>    waveform peaks, auto-generated as
//                  <csv_stem>_waveform.csv alongside the events CSV.
//   <SEGMENTS_FILE> structural segments (optional), <csv_stem>_segments.csv.
//   <GRID_FILE>    metronome ticks (optional), <csv_stem>_grid.csv.
//   <MELODY_*_FILE> per-stem note events (optional), <csv_stem>_<stem>_melody.csv.
//   <csv_stem>_adsr.csv  per-cluster ADSR params (optional), written by the editor.

import processing.sound.*;
import java.io.File;
// MIDI output lives in MidiOut.java (a plain-Java tab) — the Processing
// preprocessor can't parse javax.sound.midi's nested types in this .pde.

final String AUDIO_FILE     = "04_Krib.wav";
final String CSV_FILE       = "04_Krib.csv";
final String WAVE_FILE      = "04_Krib_waveform.csv";
final String SEGMENTS_FILE  = "04_Krib_segments.csv";
final String GRID_FILE      = "04_Krib_grid.csv";
// Per-stem melody CSVs. Sketch loads each lazily (skipped if absent), so
// adding/removing a stem just means dropping the file in or out of data/.
final String[] MELODY_STEMS = {"vocals", "bass", "other"};
final String[] MELODY_FILES = {
  "04_Krib_vocals_melody.csv",
  "04_Krib_bass_melody.csv",
  "04_Krib_other_melody.csv",
};
final int   N_TIMBRE_CLUSTERS     = 6;
final int   N_TRANSIENT_CLUSTERS  = 2;
final int   N_SEGMENT_LABELS  = 4;
final int[] DIVISIONS         = {4, 8, 16, 32};  // metronome note values
final float PAGE_DURATION_S   = 4.0;
final float DRAG_PIXELS_PER_STEP = 25;

// Onset detection and beat tracking are independent estimators, so a transient
// the ear hears as "on the beat" lands a few ms off the nearest tick. Snap
// events whose detected time is within this tolerance of a 1/32 tick to that
// tick — purely visual, the saved CSV keeps the original time. Genuinely
// off-beat hits (> tolerance) keep their natural position. Toggle with 'q'.
final float GRID_SNAP_TOLERANCE_S = 0.030;

// --- MIDI / ADSR output ------------------------------------------------------
// Virtual MIDI port to send to (substring match). loopMIDI on Windows; on Mac
// the IAC Driver, on Linux an ALSA virtual port. If no match is found the
// sketch still runs, with MIDI disabled.
final String MIDI_PORT_NAME = "loopMIDI Port";
final int    MIDI_CHANNEL   = 0;     // 0-indexed; 0 = MIDI channel 1
final int    BASE_CC        = 20;    // cluster i -> CC (BASE_CC + i)
// Envelope length = max(transient duration, MIN_ENV_S). The floor guarantees
// even very short transients produce a CC gesture the frame loop can resolve;
// set to 0 for strict duration-only timing.
final float  MIN_ENV_S      = 0.08;
final boolean RELEASE_ON_PAUSE = false;  // true = send 0s on pause instead of holding

SoundFile sound;
Table eventsTable;
Table waveformTable;

ArrayList<Event> events = new ArrayList<Event>();
ArrayList<Segment> segments = new ArrayList<Segment>();
ArrayList<GridTick> gridTicks = new ArrayList<GridTick>();
ArrayList<ArrayList<Note>> melodyNotes;  // one list per MELODY_STEMS row
color[] segmentColors;
color[] divisionColors;
color[] chromaColors;          // 12-pitch-class palette for note bars
float[] wavePeaks;
float   waveformWindowDur;    // duration of each wavePeaks window in seconds
float[] snapTickTimes;        // sorted 1/32 tick times — snap targets
boolean gridSnapEnabled = true;
float   trackDuration;
PGraphics waveformBuffer;

final String[] PITCH      = {"unpitched", "low", "mid", "high"};
final String[] BRIGHTNESS = {"dark", "mid", "bright"};
final String[] ENERGY     = {"soft", "medium", "loud"};
final String[] DURATION   = {"short", "medium", "long"};
String[] TIMBRE;
String[] TRANSIENT_CLUSTER;

String[][] rowValues;
final String[] rowNames = {"pitch", "brightness", "energy", "timbre", "cluster"};
final String[] csvCols  = {"pitch_bucket", "brightness_bucket", "energy_bucket", "timbre_cluster", "transient_cluster"};

color[][] palettes;

// Hover state — updated by mouseMoved(); used for digit-key cluster reassignment.
int hoverEventIdx = -1;

// Drag state for right-click bucket editing.
int   dragEventIdx     = -1;
int   dragRow          = -1;
int   dragStartBucket  = -1;
float dragStartY       = 0;

// Playback rate (1.0 = normal, 0.5 = half speed, etc.).
float playbackRate = 1.0;

// Preview stop: when >= 0, pause as soon as the playhead crosses this time.
float stopAtTime = -1;

// Transient save-notice (HUD).
String savedNotice       = "";
int    savedNoticeUntil  = 0;

// Per-cluster ADSR (fractions of the envelope length; sustainLevel is 0..1
// amplitude). Sized to N_TRANSIENT_CLUSTERS in setup().
float[] attackFrac, decayFrac, sustainLevel, releaseFrac;
float[] ccVal;        // current envelope value per cluster, 0..1 (for meters)
int[]   lastSent;     // last quantized CC value sent per cluster (-1 = none yet)

// MIDI output (see MidiOut.java). midiOut.isOpen() false = port not found.
MidiOut midiOut;
boolean midiEnabled = true;

// ADSR editor state.
boolean editorOpen   = false;
int     editorCluster = 0;
int     dragHandle    = -1;   // 0=attack, 1=decay/sustain, 2=release

class Event {
  float origT;          // detected onset time (ground truth, also what we save)
  float t, dur;         // t is the visual position — may be snapped to a grid tick
  int   rowIndex;       // index into eventsTable, needed for save
  int[] bucketIdx;      // current (possibly edited) bucket index per row
  boolean disabled = false;
  Event(int rowIndex, float t, float dur, int[] bucketIdx) {
    this.rowIndex = rowIndex;
    this.origT = t; this.t = t; this.dur = dur; this.bucketIdx = bucketIdx;
  }
}

class Segment {
  float startTime, endTime;
  int   label;
  Segment(float startTime, float endTime, int label) {
    this.startTime = startTime; this.endTime = endTime; this.label = label;
  }
}

class GridTick {
  float t;
  int   division, beat, phase;  // phase 0 = on the beat
  GridTick(float t, int division, int beat, int phase) {
    this.t = t; this.division = division; this.beat = beat; this.phase = phase;
  }
}

class Note {
  float startTime, endTime;
  int   midi;                  // MIDI number (e.g. 60 = C4)
  float confidence;
  String name;                 // e.g. "C4", "F#3"
  Note(float startTime, float endTime, int midi, String name, float confidence) {
    this.startTime = startTime; this.endTime = endTime;
    this.midi = midi; this.name = name; this.confidence = confidence;
  }
}

int indexOfBucket(String[] arr, String s) {
  for (int i = 0; i < arr.length; i++) if (arr[i].equals(s)) return i;
  return -1;
}

void setup() {
  size(1920, 1080, P2D);
  frameRate(120);

  TIMBRE = new String[N_TIMBRE_CLUSTERS];
  for (int i = 0; i < N_TIMBRE_CLUSTERS; i++) TIMBRE[i] = str(i);
  TRANSIENT_CLUSTER = new String[N_TRANSIENT_CLUSTERS];
  for (int i = 0; i < N_TRANSIENT_CLUSTERS; i++) TRANSIENT_CLUSTER[i] = str(i);
  rowValues = new String[][]{PITCH, BRIGHTNESS, ENERGY, TIMBRE, TRANSIENT_CLUSTER};

  buildPalettes();

  eventsTable = loadTable(CSV_FILE, "header");
  int idx = 0;
  for (TableRow r : eventsTable.rows()) {
    int[] bi = new int[rowValues.length];
    for (int i = 0; i < rowValues.length; i++) {
      bi[i] = indexOfBucket(rowValues[i], r.getString(csvCols[i]));
    }
    events.add(new Event(idx, r.getFloat("start_time"), r.getFloat("duration"), bi));
    idx++;
  }

  waveformTable = loadTable(WAVE_FILE, "header");
  int n = waveformTable.getRowCount();
  wavePeaks = new float[n];
  for (int i = 0; i < n; i++) wavePeaks[i] = waveformTable.getFloat(i, "peak");

  loadSegments();
  buildSegmentColors();
  loadGrid();
  buildDivisionColors();
  buildSnapTickArray();
  applyGridSnap();
  loadMelody();
  buildChromaColors();

  sound = new SoundFile(this, AUDIO_FILE);
  trackDuration = sound.duration();
  waveformWindowDur = (wavePeaks.length > 0) ? trackDuration / wavePeaks.length : 1.0 / 44100;

  buildWaveformBuffer();

  sound.rate(playbackRate);

  initAdsr();
  initMidi();
}

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
  for (int i = 0; i < N_SEGMENT_LABELS; i++) {
    segmentColors[i] = color(i * 360.0 / N_SEGMENT_LABELS + 25, 55, 80);
  }
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
  // Quarter = warm/bright, finer subdivisions shift cooler so the denser rows
  // read as "background" pulse.
  for (int i = 0; i < DIVISIONS.length; i++) {
    divisionColors[i] = color(45 + i * 55, 70, 95);
  }
  colorMode(RGB, 255);
}

int divisionRow(int d) {
  for (int i = 0; i < DIVISIONS.length; i++) if (DIVISIONS[i] == d) return i;
  return DIVISIONS.length - 1;
}

void buildSnapTickArray() {
  // Snap targets = the 1/32 ticks. Coarser divisions are subsets of 1/32
  // (each beat tick has phase 0 across all divisions), so this is sufficient.
  if (gridTicks.isEmpty()) { snapTickTimes = new float[0]; return; }
  int finest = DIVISIONS[DIVISIONS.length - 1];
  ArrayList<Float> times = new ArrayList<Float>();
  for (GridTick g : gridTicks) {
    if (g.division == finest) times.add(g.t);
  }
  snapTickTimes = new float[times.size()];
  for (int i = 0; i < times.size(); i++) snapTickTimes[i] = times.get(i);
}

float snapToNearestTick(float t) {
  // Returns the nearest tick time if within GRID_SNAP_TOLERANCE_S, else t.
  // Binary search the sorted snapTickTimes array.
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
  // Rebuild every event's visual time from its origT, snapping if enabled.
  // Idempotent — call it any time the snap state changes.
  for (Event e : events) {
    e.t = gridSnapEnabled ? snapToNearestTick(e.origT) : e.origT;
  }
}

void loadMelody() {
  melodyNotes = new ArrayList<ArrayList<Note>>();
  for (int i = 0; i < MELODY_STEMS.length; i++) {
    ArrayList<Note> list = new ArrayList<Note>();
    melodyNotes.add(list);
    File f = new File(dataPath(MELODY_FILES[i]));
    if (!f.exists()) continue;  // each stem's CSV is independently optional
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
  // One hue per pitch class. C is red; ascending the chromatic scale walks
  // the hue wheel. Same color for the same note across octaves so the
  // melodic shape reads at a glance.
  chromaColors = new color[12];
  colorMode(HSB, 360, 100, 100);
  for (int i = 0; i < 12; i++) {
    chromaColors[i] = color(i * 30, 75, 95);
  }
  colorMode(RGB, 255);
}

color colorForMidi(int midi) {
  int pc = ((midi % 12) + 12) % 12;  // handle negative just in case
  return chromaColors[pc];
}

void buildWaveformBuffer() {
  int wW = width - 80;
  int wH = 110;
  waveformBuffer = createGraphics(wW, wH, P2D);
  waveformBuffer.beginDraw();
  waveformBuffer.background(22);

  // Segment color bands (drawn first, peaks layered on top).
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
  palettes[0] = new color[]{ color(90, 90, 100), color(60, 110, 220),
                             color(90, 200, 130), color(240, 100, 100) };
  palettes[1] = new color[]{ color(40, 70, 130), color(200, 170, 60), color(250, 240, 200) };
  palettes[2] = new color[]{ color(90, 80, 120), color(160, 130, 200), color(220, 80, 230) };
  palettes[3] = new color[N_TIMBRE_CLUSTERS];
  palettes[4] = new color[N_TRANSIENT_CLUSTERS];
  colorMode(HSB, 360, 100, 100);
  for (int i = 0; i < N_TIMBRE_CLUSTERS; i++) {
    palettes[3][i] = color(i * 360.0 / N_TIMBRE_CLUSTERS, 70, 95);
  }
  for (int i = 0; i < N_TRANSIENT_CLUSTERS; i++) {
    palettes[4][i] = color(i * 360.0 / N_TRANSIENT_CLUSTERS, 85, 100);
  }
  colorMode(RGB, 255);
}

// --- Layout constants — kept consistent between draw and hit-test. -----------

float gridLeft()   { return 140; }
float gridRight()  { return width - 40; }
float gridTop()    { return 90; }
float gridBottom() { return height - 650; }
float rowHeight()  { return (gridBottom() - gridTop()) / rowValues.length; }
float cellSize()   { return min(rowHeight() * 0.7, 48); }

// Melody panel — three rows (vocals/bass/other) of pitched note bars, sharing
// the event grid's horizontal extent so notes line up with the events above.
float melodyTop()    { return height - 630; }
float melodyBottom() { return height - 295; }
float melodyRowH()   { return (melodyBottom() - melodyTop()) / MELODY_STEMS.length; }
float melodyRowY(int row) { return melodyTop() + row * melodyRowH() + melodyRowH() / 2; }

// Metronome grid panel — sits between the melody panel and the waveform,
// sharing the event grid's horizontal extent and page window so ticks line up
// with the onset events above them.
float metroTop()    { return height - 275; }
float metroBottom() { return height - 185; }
float metroRowH()   { return (metroBottom() - metroTop()) / DIVISIONS.length; }
float metroRowY(int row) { return metroTop() + row * metroRowH() + metroRowH() / 2; }

float pageStartFor(float now) {
  return ((int) (now / PAGE_DURATION_S)) * PAGE_DURATION_S;
}

float eventX(Event e, float pageStart) {
  return gridLeft() + (e.t - pageStart) / PAGE_DURATION_S * (gridRight() - gridLeft());
}

float rowCenterY(int row) {
  return gridTop() + row * rowHeight() + rowHeight() / 2;
}

// --- Draw --------------------------------------------------------------------

void draw() {
  background(15);

  if (stopAtTime >= 0 && sound.position() >= stopAtTime) {
    sound.pause();
    stopAtTime = -1;
  }

  float now = sound.position();

  updateMidi(now);  // emit per-cluster ADSR envelopes as MIDI CC

  int   currentPage = (int) (now / PAGE_DURATION_S);
  float pageStart   = currentPage * PAGE_DURATION_S;
  float pageEnd     = pageStart + PAGE_DURATION_S;

  ArrayList<Event> pageEvents = new ArrayList<Event>();
  for (Event e : events) {
    if (e.t >= pageStart && e.t < pageEnd) pageEvents.add(e);
  }

  drawGrid(pageEvents, pageStart, pageEnd, now);
  drawDragOverlay(pageStart, pageEnd);
  drawMelody(pageStart, pageEnd, now);
  drawMetro(pageStart, pageEnd, now);
  drawWaveform(now, pageStart, pageEnd);
  drawCcMeters();
  drawHUD(now, currentPage, pageEvents.size());

  if (editorOpen) drawAdsrEditor();  // overlay drawn last, on top of everything
}

void drawGridWaveformBackground(float pageStart, float pageEnd) {
  float gL = gridLeft(), gR = gridRight();
  float gT = gridTop(), gB = gridBottom();
  float mid   = (gT + gB) * 0.5;
  float halfH = (gB - gT) * 0.48;
  float pageW = gR - gL;
  float pageDur = pageEnd - pageStart;
  int   n = wavePeaks.length;

  stroke(55, 68, 95);
  strokeWeight(1);
  noFill();
  for (int px = (int)gL; px <= (int)gR; px++) {
    float t0 = pageStart + (px - gL)       / pageW * pageDur;
    float t1 = pageStart + (px - gL + 1.0) / pageW * pageDur;
    if (t0 >= trackDuration) break;  // final page extends past the track — stop here
    // Clamp BOTH ends to the valid range; near the track end t0/t1 map past
    // the last sample, and an unclamped i0 would read out of bounds.
    int i0 = constrain((int)(t0 / waveformWindowDur), 0, n - 1);
    int i1 = constrain((int)(t1 / waveformWindowDur), 0, n - 1);
    if (i1 < i0) i1 = i0;
    float p = 0;
    for (int i = i0; i <= i1; i++) p = max(p, wavePeaks[i]);
    float h = p * halfH;
    line(px, mid - h, px, mid + h);
  }
}

void drawGrid(ArrayList<Event> pageEvents, float pageStart, float pageEnd, float now) {
  float gL = gridLeft(), gR = gridRight(), gT = gridTop(), gB = gridBottom();
  float rowH = rowHeight();
  float cs   = cellSize();
  int   nRows = rowValues.length;

  drawGridWaveformBackground(pageStart, pageEnd);

  textAlign(LEFT, CENTER);
  textSize(18);
  for (int row = 0; row < nRows; row++) {
    float y = rowCenterY(row);
    fill(180);
    text(rowNames[row], 24, y);
    stroke(35);
    strokeWeight(1);
    line(gL, y, gR, y);
  }
  noStroke();

  for (Event e : pageEvents) {
    float x = eventX(e, pageStart);
    float age = now - e.t;
    float intensity;
    if (e.disabled)       intensity = 0.0;
    else if (age < 0)     intensity = 0.30;
    else if (age > e.dur) intensity = 0.55;
    else                  intensity = 0.55 + 0.45 * pow(1 - age / e.dur, 1.4);

    for (int row = 0; row < nRows; row++) {
      int b = e.bucketIdx[row];
      if (b < 0) continue;
      color c = palettes[row][b];
      float y = rowCenterY(row);

      // Outline
      noFill();
      if (e.disabled) {
        stroke(80);
        strokeWeight(1);
      } else {
        stroke(red(c) * 0.5, green(c) * 0.5, blue(c) * 0.5);
        strokeWeight(1);
      }
      rect(x - cs / 2, y - cs / 2, cs, cs, 5);

      if (!e.disabled) {
        noStroke();
        float s = cs * (0.4 + 0.6 * intensity);
        fill(red(c) * intensity, green(c) * intensity, blue(c) * intensity);
        rect(x - s / 2, y - s / 2, s, s, 3);
      }
    }

    // Strike-through for disabled events
    if (e.disabled) {
      stroke(120, 80, 80);
      strokeWeight(1);
      line(x - cs / 2, gT + 6, x + cs / 2, gB - 6);
    }
  }

  // Playhead
  if (now >= pageStart && now < pageEnd) {
    float playX = gL + (now - pageStart) / PAGE_DURATION_S * (gR - gL);
    stroke(255, 200, 50, 200);
    strokeWeight(2);
    line(playX, gT - 12, playX, gB + 12);
    noStroke();
  }

  // Hover highlight: ring around the transient_cluster cell of the hovered event.
  if (hoverEventIdx >= 0 && hoverEventIdx < events.size()) {
    Event he = events.get(hoverEventIdx);
    if (he.t >= pageStart && he.t < pageEnd) {
      int clusterRow = csvCols.length - 1;  // transient_cluster is always last
      float hx = eventX(he, pageStart);
      float hy = rowCenterY(clusterRow);
      noFill();
      stroke(255, 255, 255, 200);
      strokeWeight(2);
      rect(hx - cs / 2 - 4, hy - cs / 2 - 4, cs + 8, cs + 8, 7);
      noStroke();
    }
  }
}

void drawMelody(float pageStart, float pageEnd, float now) {
  if (melodyNotes == null || melodyNotes.isEmpty()) return;
  float gL = gridLeft(), gR = gridRight();
  float rowH = melodyRowH();

  // Row labels + baselines — only for stems with enough notes to be meaningful.
  textAlign(LEFT, CENTER);
  textSize(14);
  for (int i = 0; i < MELODY_STEMS.length; i++) {
    ArrayList<Note> list = melodyNotes.get(i);
    if (list == null || list.size() < 20) continue;
    float y = melodyRowY(i);
    fill(150);
    text(MELODY_STEMS[i], 24, y);
    stroke(35);
    strokeWeight(1);
    line(gL, y, gR, y);
  }

  // Each note is a horizontal pitched bar from start to end, color = chroma.
  // The bar's vertical position within the row encodes octave: low MIDI sits
  // toward the bottom of the row, high MIDI toward the top. This gives a
  // mini piano-roll without giving up the row-per-stem framing.
  for (int i = 0; i < melodyNotes.size(); i++) {
    ArrayList<Note> list = melodyNotes.get(i);
    if (list == null || list.size() < 20) continue;
    int loMidi = stemPitchLo(i);
    int hiMidi = stemPitchHi(i);
    float yCenter = melodyRowY(i);
    float yMin = yCenter - rowH * 0.40;
    float yMax = yCenter + rowH * 0.40;

    for (Note n : list) {
      // Skip notes outside the current page window; clamp the bar to the
      // visible extent if a note straddles a page boundary.
      if (n.endTime < pageStart || n.startTime >= pageEnd) continue;
      float t0 = max(n.startTime, pageStart);
      float t1 = min(n.endTime,   pageEnd);
      float x0 = gL + (t0 - pageStart) / PAGE_DURATION_S * (gR - gL);
      float x1 = gL + (t1 - pageStart) / PAGE_DURATION_S * (gR - gL);
      float w  = max(2, x1 - x0);

      float pitchNorm = constrain((float)(n.midi - loMidi) / max(1, hiMidi - loMidi), 0, 1);
      float yBar = lerp(yMax, yMin, pitchNorm);  // low at bottom, high at top
      float barH = max(4, rowH * 0.15);

      color c = colorForMidi(n.midi);
      boolean playing = (now >= n.startTime && now < n.endTime);
      float intensity = playing ? 1.0 : 0.55;
      // Confidence dims low-probability notes so glitches read as faint.
      float alphaMul = 0.45 + 0.55 * constrain(n.confidence, 0, 1);

      noStroke();
      fill(red(c) * intensity, green(c) * intensity, blue(c) * intensity, 255 * alphaMul);
      rect(x0, yBar - barH / 2, w, barH, 2);

      if (playing) {
        // Halo around the currently-playing note + name label centered in it.
        noFill();
        stroke(red(c), green(c), blue(c), 220);
        strokeWeight(1.5);
        rect(x0 - 2, yBar - barH / 2 - 2, w + 4, barH + 4, 3);
        if (w > 28) {
          noStroke();
          fill(20, 20, 28, 220);
          textAlign(CENTER, CENTER);
          textSize(11);
          text(n.name, x0 + w / 2, yBar);
          textAlign(LEFT, CENTER);
        }
      }
    }
  }
  noStroke();

  // Playhead across the panel.
  if (now >= pageStart && now < pageEnd) {
    float playX = gL + (now - pageStart) / PAGE_DURATION_S * (gR - gL);
    stroke(255, 200, 50, 160);
    strokeWeight(2);
    line(playX, melodyTop() - 4, playX, melodyBottom() + 4);
    noStroke();
  }
}

// Stem-typical MIDI ranges for the piano-roll y-mapping. Values mirror the
// pyin search ranges in synchronizer/melody.py, so notes detected for each
// stem land naturally inside its row.
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

void drawMetro(float pageStart, float pageEnd, float now) {
  float gL = gridLeft(), gR = gridRight();
  float rowH = metroRowH();

  // Row labels + baselines.
  textAlign(LEFT, CENTER);
  textSize(14);
  for (int i = 0; i < DIVISIONS.length; i++) {
    float y = metroRowY(i);
    fill(150);
    text("1/" + DIVISIONS[i], 24, y);
    stroke(35);
    strokeWeight(1);
    line(gL, y, gR, y);
  }

  // Ticks within the current page window.
  for (GridTick g : gridTicks) {
    if (g.t < pageStart || g.t >= pageEnd) continue;
    int row = divisionRow(g.division);
    float x = gL + (g.t - pageStart) / PAGE_DURATION_S * (gR - gL);
    float y = metroRowY(row);
    color c = divisionColors[row];
    boolean onBeat = (g.phase == 0);
    float baseH = rowH * (onBeat ? 0.42 : 0.26);

    // Flash as the playhead crosses the tick (brief pre-roll, then fade out).
    float age = now - g.t;
    float flash = (age >= -0.015 && age < 0.14) ? constrain(1 - age / 0.14, 0, 1) : 0;

    // Dim baseline mark (the static grid).
    stroke(red(c) * 0.55, green(c) * 0.55, blue(c) * 0.55, onBeat ? 200 : 110);
    strokeWeight(onBeat ? 2 : 1);
    line(x, y - baseH, x, y + baseH);

    // Bright pulse + glow dot on hit.
    if (flash > 0) {
      float h = baseH * (1 + 0.6 * flash);
      stroke(red(c), green(c), blue(c), 180 + 75 * flash);
      strokeWeight(onBeat ? 4 : 3);
      line(x, y - h, x, y + h);
      noStroke();
      fill(red(c), green(c), blue(c), 200 * flash);
      float r = (onBeat ? 7 : 5) * flash;
      ellipse(x, y, r * 2, r * 2);
    }
  }
  noStroke();

  // Playhead across the panel (matches the event-grid / waveform playhead).
  if (now >= pageStart && now < pageEnd) {
    float playX = gL + (now - pageStart) / PAGE_DURATION_S * (gR - gL);
    stroke(255, 200, 50, 160);
    strokeWeight(2);
    line(playX, metroTop() - 6, playX, metroBottom() + 6);
    noStroke();
  }
}

void drawDragOverlay(float pageStart, float pageEnd) {
  if (dragEventIdx < 0) return;
  Event e = events.get(dragEventIdx);
  if (e.t < pageStart || e.t >= pageEnd) return;  // dragged event scrolled off page
  float x = eventX(e, pageStart);
  float y = rowCenterY(dragRow);
  float cs = cellSize();
  noFill();
  stroke(255, 230, 80);
  strokeWeight(2);
  rect(x - cs / 2 - 5, y - cs / 2 - 5, cs + 10, cs + 10, 7);
  noStroke();
}

void drawWaveform(float now, float pageStart, float pageEnd) {
  float wLeft   = 40;
  float wTop    = height - 160;
  float wW      = width - 80;
  float wH      = 110;
  float wBottom = wTop + wH;

  image(waveformBuffer, wLeft, wTop);

  noStroke();
  float pageX0 = wLeft + constrain(pageStart, 0, trackDuration) / trackDuration * wW;
  float pageX1 = wLeft + constrain(pageEnd,   0, trackDuration) / trackDuration * wW;
  fill(255, 200, 50, 55);
  rect(pageX0, wTop, max(2, pageX1 - pageX0), wH);

  float playX = wLeft + constrain(now, 0, trackDuration) / trackDuration * wW;
  stroke(255, 200, 50);
  strokeWeight(2);
  line(playX, wTop - 6, playX, wBottom + 6);
  noStroke();
}

void drawHUD(float now, int page, int eventsThisPage) {
  int disabledCount = 0;
  for (Event e : events) if (e.disabled) disabledCount++;

  fill(200);
  textAlign(LEFT, TOP);
  textSize(14);
  String rateStr = (playbackRate != 1.0) ? "  [" + nf(playbackRate, 1, 2) + "x]" : "";
  String state = (sound.isPlaying() ? "" : "  [PAUSED]") + rateStr;

  int segIdx = currentSegmentIndex(now);
  String segLabel;
  if (segIdx >= 0) {
    Segment s = segments.get(segIdx);
    color c = segmentColors[constrain(s.label, 0, N_SEGMENT_LABELS - 1)];
    fill(red(c), green(c), blue(c));
    segLabel = "   segment " + (segIdx + 1) + "/" + segments.size() +
               " (label " + s.label + ")";
  } else {
    segLabel = "";
  }
  text(
    nf(now, 1, 2) + "s / " + nf(trackDuration, 1, 2) + "s   " +
    "page " + page + "   events on page: " + eventsThisPage + "   " +
    "disabled: " + disabledCount + segLabel + state,
    24, 24
  );
  fill(200);

  textAlign(RIGHT, TOP);
  String snapHint = gridSnapEnabled ? "snap:on" : "snap:off";
  text("space play/pause   ← → page   r start   q " + snapHint +
       "   -/= speed   e editor   m midi   ctrl/cmd+s save", width - 24, 24);
  boolean midiOk = (midiOut != null && midiOut.isOpen());
  String midiStatus = midiOk
    ? ("MIDI → " + midiOut.portName() + (midiEnabled ? "" : "  (muted)"))
    : "MIDI: off (port not found)";
  fill(midiOk && midiEnabled ? color(120, 220, 140) : color(210, 160, 80));
  text(midiStatus, width - 24, 44);
  fill(200);

  if (dragEventIdx >= 0) {
    Event e = events.get(dragEventIdx);
    int bi = e.bucketIdx[dragRow];
    String name = rowNames[dragRow];
    String fromVal = rowValues[dragRow][dragStartBucket];
    String toVal   = (bi >= 0 ? rowValues[dragRow][bi] : "?");
    fill(255, 230, 80);
    textAlign(LEFT, TOP);
    text("editing event " + dragEventIdx + " — " + name + ": " + fromVal + " → " + toVal, 24, 50);
  } else if (hoverEventIdx >= 0 && hoverEventIdx < events.size()) {
    Event e = events.get(hoverEventIdx);
    int clusterRow = csvCols.length - 1;
    int cur = e.bucketIdx[clusterRow];
    String curLabel = (cur >= 0 && cur < rowValues[clusterRow].length) ? rowValues[clusterRow][cur] : "?";
    fill(200, 200, 255);
    textAlign(LEFT, TOP);
    text("event " + hoverEventIdx + "   cluster: " + curLabel +
         "   press 0-" + (rowValues[clusterRow].length - 1) + " to reassign", 24, 50);
  }

  if (savedNoticeUntil > millis()) {
    fill(120, 220, 140);
    textAlign(LEFT, TOP);
    text(savedNotice, 24, 50);
  }

  textAlign(LEFT, CENTER);
}

// --- Mouse: edits ------------------------------------------------------------

int findEventNear(float mx, float my) {
  // Hit-test against events on the current page. Returns event index, or -1.
  float now = sound.position();
  float pageStart = pageStartFor(now);
  float pageEnd   = pageStart + PAGE_DURATION_S;
  float cs = cellSize();
  float maxDx = cs / 2 + 6;

  if (mx < gridLeft() - maxDx || mx > gridRight() + maxDx) return -1;
  if (my < gridTop() || my > gridBottom()) return -1;

  int best = -1;
  float bestDx = maxDx;
  for (int i = 0; i < events.size(); i++) {
    Event e = events.get(i);
    if (e.t < pageStart || e.t >= pageEnd) continue;
    float x = eventX(e, pageStart);
    float dx = abs(mx - x);
    if (dx < bestDx) {
      bestDx = dx;
      best = i;
    }
  }
  return best;
}

int rowAt(float my) {
  // Returns row index if my is within cellSize/2 of a row's center, else -1.
  float cs = cellSize();
  for (int row = 0; row < rowValues.length; row++) {
    if (abs(my - rowCenterY(row)) <= cs / 2 + 2) return row;
  }
  return -1;
}

void mousePressed() {
  if (editorOpen) { editorMousePressed(); return; }
  int eventIdx = findEventNear(mouseX, mouseY);
  if (eventIdx < 0) return;
  if (mouseButton == LEFT) {
    Event e = events.get(eventIdx);
    if (mouseEvent.isShiftDown()) {
      stopAtTime = e.origT + e.dur;
      sound.jump(e.origT);
      sound.rate(playbackRate);
    } else {
      e.disabled = !e.disabled;
    }
  } else if (mouseButton == RIGHT) {
    int row = rowAt(mouseY);
    if (row < 0) return;
    Event e = events.get(eventIdx);
    if (e.bucketIdx[row] < 0) return;  // can't drag a cell with no known bucket
    dragEventIdx    = eventIdx;
    dragRow         = row;
    dragStartBucket = e.bucketIdx[row];
    dragStartY      = mouseY;
  }
}

void mouseDragged() {
  if (editorOpen) { editorMouseDragged(); return; }
  if (dragEventIdx < 0) return;
  float deltaY = dragStartY - mouseY;  // drag up = positive
  int steps = (int) (deltaY / DRAG_PIXELS_PER_STEP);
  int nBuckets = rowValues[dragRow].length;
  int newIdx = constrain(dragStartBucket + steps, 0, nBuckets - 1);
  events.get(dragEventIdx).bucketIdx[dragRow] = newIdx;
}

void mouseReleased() {
  if (editorOpen) { dragHandle = -1; return; }
  dragEventIdx = -1;
  dragRow      = -1;
}

void mouseMoved() {
  if (editorOpen) return;  // suspend hover while the editor overlay is up
  hoverEventIdx = findEventNear(mouseX, mouseY);
}

// --- Keys --------------------------------------------------------------------

void keyPressed() {
  // ctrl/cmd + s — save
  if ((keyEvent.isControlDown() || keyEvent.isMetaDown())
      && (key == 's' || key == 'S' || key == '')) {
    if (editorOpen) saveAdsr();
    else            saveEdits();
    return;
  }
  if (key == ' ') {
    stopAtTime = -1;
    if (sound.isPlaying()) sound.pause();
    else sound.play();
    return;
  }
  if (key == 'r' || key == 'R') {
    seek(0);
    return;
  }
  if (keyCode == LEFT) {
    seek(sound.position() - PAGE_DURATION_S);
  } else if (keyCode == RIGHT) {
    seek(sound.position() + PAGE_DURATION_S);
  }
  if (key == 'q' || key == 'Q') {
    gridSnapEnabled = !gridSnapEnabled;
    applyGridSnap();
  }
  if (key == '-' || key == '_') {
    playbackRate = max(0.25, playbackRate - 0.25);
    sound.rate(playbackRate);
  }
  if (key == '=' || key == '+') {
    playbackRate = min(2.0, playbackRate + 0.25);
    sound.rate(playbackRate);
  }
  if (key == 'e' || key == 'E') {
    editorOpen = !editorOpen;
  }
  if (key == 'm' || key == 'M') {
    midiEnabled = !midiEnabled;  // updateMidi() sends 0s on the next frame when off
  }
  // Digit keys: in the editor, select the cluster to edit; otherwise reassign
  // the hovered event's transient_cluster.
  if (key >= '0' && key <= '9') {
    int digit = key - '0';
    if (editorOpen) {
      if (digit < N_TRANSIENT_CLUSTERS) editorCluster = digit;
    } else if (hoverEventIdx >= 0) {
      int clusterRow = csvCols.length - 1;
      if (digit < rowValues[clusterRow].length) {
        events.get(hoverEventIdx).bucketIdx[clusterRow] = digit;
      }
    }
  }
}

void seek(float target) {
  stopAtTime = -1;
  target = constrain(target, 0, max(0, trackDuration - 0.05));
  boolean wasPlaying = sound.isPlaying();
  sound.jump(target);
  sound.rate(playbackRate);
  if (!wasPlaying) sound.pause();
}

// --- Save --------------------------------------------------------------------

void saveEdits() {
  String baseStem = CSV_FILE.replaceAll("\\.csv$", "");
  int v = findNextVersion(baseStem);
  String saveName = baseStem + "_v" + v + ".csv";

  Table out = new Table();
  for (int col = 0; col < eventsTable.getColumnCount(); col++) {
    out.addColumn(eventsTable.getColumnTitle(col));
  }
  int written = 0;
  int disabled = 0;
  for (Event e : events) {
    if (e.disabled) { disabled++; continue; }
    TableRow src = eventsTable.getRow(e.rowIndex);
    TableRow dst = out.addRow();
    for (int col = 0; col < eventsTable.getColumnCount(); col++) {
      dst.setString(col, src.getString(col));
    }
    for (int row = 0; row < rowValues.length; row++) {
      int bi = e.bucketIdx[row];
      if (bi >= 0) dst.setString(csvCols[row], rowValues[row][bi]);
    }
    written++;
  }
  saveTable(out, dataPath(saveName));

  savedNotice      = "saved " + saveName + " — " + written + " events (" + disabled + " disabled)";
  savedNoticeUntil = millis() + 4000;
  println(savedNotice);
}

int findNextVersion(String baseStem) {
  File dir = new File(dataPath(""));
  String prefix = baseStem + "_v";
  int maxV = 0;
  if (dir.exists() && dir.isDirectory()) {
    File[] files = dir.listFiles();
    if (files != null) {
      for (File f : files) {
        String name = f.getName();
        if (name.startsWith(prefix) && name.endsWith(".csv")) {
          String mid = name.substring(prefix.length(), name.length() - 4);
          try {
            int v = Integer.parseInt(mid);
            if (v > maxV) maxV = v;
          } catch (NumberFormatException nfe) {}
        }
      }
    }
  }
  return maxV + 1;
}

// --- ADSR model + persistence ------------------------------------------------

void initAdsr() {
  int n = N_TRANSIENT_CLUSTERS;
  attackFrac   = new float[n];
  decayFrac    = new float[n];
  sustainLevel = new float[n];
  releaseFrac  = new float[n];
  ccVal        = new float[n];
  lastSent     = new int[n];
  for (int i = 0; i < n; i++) {
    // Defaults vary by cluster index so clusters start audibly distinct;
    // the user tunes them in the editor. All are fractions of envelope length
    // except sustainLevel (0..1 amplitude).
    attackFrac[i]   = 0.04 + 0.04 * (i % 3);
    decayFrac[i]    = 0.18;
    sustainLevel[i] = 0.65 - 0.10 * (i % 3);
    releaseFrac[i]  = 0.25 + 0.05 * (i % 3);
    clampAdsr(i);
    ccVal[i]    = 0;
    lastSent[i] = -1;     // force a send on the first frame
  }
  loadAdsr();
}

void clampAdsr(int c) {
  attackFrac[c]   = constrain(attackFrac[c], 0, 1);
  decayFrac[c]    = constrain(decayFrac[c], 0, 1 - attackFrac[c]);
  releaseFrac[c]  = constrain(releaseFrac[c], 0, 1 - attackFrac[c] - decayFrac[c]);
  sustainLevel[c] = constrain(sustainLevel[c], 0, 1);
}

String adsrFileName() {
  return CSV_FILE.replaceAll("\\.csv$", "") + "_adsr.csv";
}

void loadAdsr() {
  File f = new File(dataPath(adsrFileName()));
  if (!f.exists()) return;  // optional — defaults stand otherwise
  Table t = loadTable(adsrFileName(), "header");
  for (TableRow r : t.rows()) {
    int c = r.getInt("cluster");
    if (c < 0 || c >= N_TRANSIENT_CLUSTERS) continue;
    attackFrac[c]   = r.getFloat("attack");
    decayFrac[c]    = r.getFloat("decay");
    sustainLevel[c] = r.getFloat("sustain");
    releaseFrac[c]  = r.getFloat("release");
    clampAdsr(c);
  }
}

void saveAdsr() {
  Table out = new Table();
  out.addColumn("cluster");
  out.addColumn("attack");
  out.addColumn("decay");
  out.addColumn("sustain");
  out.addColumn("release");
  for (int c = 0; c < N_TRANSIENT_CLUSTERS; c++) {
    TableRow row = out.addRow();
    row.setInt("cluster", c);
    row.setFloat("attack",  attackFrac[c]);
    row.setFloat("decay",   decayFrac[c]);
    row.setFloat("sustain", sustainLevel[c]);
    row.setFloat("release", releaseFrac[c]);
  }
  saveTable(out, dataPath(adsrFileName()));
  savedNotice      = "saved " + adsrFileName();
  savedNoticeUntil = millis() + 4000;
  println(savedNotice);
}

// Envelope value at normalized phase p in [0,1). Returns 0 outside that range.
float envValue(int c, float p) {
  if (p < 0 || p >= 1) return 0;
  float aF = attackFrac[c], dF = decayFrac[c], rF = releaseFrac[c], S = sustainLevel[c];
  float relStart = 1 - rF;
  if (p < aF)            return aF > 0 ? p / aF : 1;                       // attack 0->1
  else if (p < aF + dF)  return dF > 0 ? 1 - (1 - S) * (p - aF) / dF : S;  // decay 1->S
  else if (p < relStart) return S;                                        // sustain
  else                   return rF > 0 ? S * (1 - (p - relStart) / rF) : 0; // release S->0
}

// --- MIDI output (javax.sound.midi) ------------------------------------------

void initMidi() {
  midiOut = new MidiOut(MIDI_PORT_NAME);
}

void sendCC(int cc, int val) {
  if (midiOut != null) midiOut.sendCC(MIDI_CHANNEL, cc, val);
}

void closeMidi() {
  if (midiOut != null) { midiOut.close(); midiOut = null; }
}

void dispose() {
  if (midiOut != null && midiOut.isOpen()) {
    for (int c = 0; c < N_TRANSIENT_CLUSTERS; c++) sendCC(BASE_CC + c, 0);  // release all
  }
  closeMidi();
  super.dispose();
}

// Stateless per-frame envelope -> CC send. Computing purely from `now` means
// pause (now frozen -> values hold), seek, and playback-rate changes are all
// handled automatically. Polyphony of overlapping same-cluster transients is
// resolved by taking the max envelope value. Dedup: only send on change.
void updateMidi(float now) {
  int nc = N_TRANSIENT_CLUSTERS;
  for (int c = 0; c < nc; c++) ccVal[c] = 0;

  boolean releasing = RELEASE_ON_PAUSE && !sound.isPlaying();
  if (!releasing) {
    int clusterRow = csvCols.length - 1;
    for (Event e : events) {
      if (e.disabled) continue;
      float envLen = max(e.dur, MIN_ENV_S);
      float p = (now - e.origT) / envLen;
      if (p < 0 || p >= 1) continue;
      int c = e.bucketIdx[clusterRow];
      if (c < 0 || c >= nc) continue;
      float v = envValue(c, p);
      if (v > ccVal[c]) ccVal[c] = v;
    }
  }

  for (int c = 0; c < nc; c++) {
    int q = midiEnabled ? constrain(round(ccVal[c] * 127), 0, 127) : 0;
    if (q != lastSent[c]) {
      sendCC(BASE_CC + c, q);
      lastSent[c] = q;
    }
  }
}

// --- CC level meters (always visible) ----------------------------------------

void drawCcMeters() {
  int nc = N_TRANSIENT_CLUSTERS;
  float stripTop = height - 40, stripH = 30;
  float x0 = 40, totalW = width - 80, gap = 10;
  float barW = (totalW - gap * (nc - 1)) / nc;
  textSize(12);
  for (int c = 0; c < nc; c++) {
    float bx = x0 + c * (barW + gap);
    color col = palettes[4][c];
    float v = constrain(ccVal[c], 0, 1);
    noStroke();
    fill(20);
    rect(bx, stripTop, barW, stripH);              // background
    fill(red(col), green(col), blue(col), midiEnabled ? 220 : 80);
    rect(bx, stripTop, barW * v, stripH);          // level fill (left -> right)
    noFill();
    stroke(60);
    strokeWeight(1);
    rect(bx, stripTop, barW, stripH);              // frame
    int q = constrain(round(v * 127), 0, 127);
    fill(235);
    textAlign(LEFT, CENTER);
    text("c" + c + "  CC" + (BASE_CC + c) + ": " + q, bx + 6, stripTop + stripH / 2);
  }
  noStroke();
}

// --- ADSR editor overlay -----------------------------------------------------

float editPlotL() { return 220; }
float editPlotR() { return width - 220; }
float editPlotT() { return 200; }
float editPlotB() { return 560; }

float plotX(float frac) { return editPlotL() + constrain(frac, 0, 1) * (editPlotR() - editPlotL()); }
float plotY(float val)  { return editPlotB() - constrain(val, 0, 1) * (editPlotB() - editPlotT()); }

void drawEnvCurve(int c, color col, float weight, int alpha) {
  stroke(red(col), green(col), blue(col), alpha);
  strokeWeight(weight);
  noFill();
  beginShape();
  for (int i = 0; i <= 200; i++) {
    float p = (i / 200.0) * 0.99999;  // stay just inside [0,1) so release shows
    vertex(plotX(p), plotY(envValue(c, p)));
  }
  endShape();
}

void drawHandle(float x, float y) {
  noStroke();
  fill(255, 240, 120);
  ellipse(x, y, 14, 14);
  fill(40);
  ellipse(x, y, 6, 6);
}

void drawAdsrEditor() {
  noStroke();
  fill(0, 0, 0, 195);
  rect(0, 0, width, height);

  float pL = editPlotL(), pR = editPlotR(), pT = editPlotT(), pB = editPlotB();

  fill(230);
  textAlign(LEFT, TOP);
  textSize(20);
  text("ADSR editor — cluster " + editorCluster + " / " + (N_TRANSIENT_CLUSTERS - 1), pL, pT - 44);
  fill(170);
  textSize(13);
  textAlign(RIGHT, TOP);
  text("0-9 select cluster    drag handles    ctrl/cmd+s save    e close", pR, pT - 38);

  stroke(80);
  strokeWeight(1);
  noFill();
  rect(pL, pT, pR - pL, pB - pT);

  // Ghost curves for other clusters, then the selected one bold.
  for (int c = 0; c < N_TRANSIENT_CLUSTERS; c++) {
    if (c != editorCluster) drawEnvCurve(c, palettes[4][c], 1, 55);
  }
  color col = palettes[4][editorCluster];
  drawEnvCurve(editorCluster, col, 3, 255);

  float aF = attackFrac[editorCluster], dF = decayFrac[editorCluster];
  float rF = releaseFrac[editorCluster], S = sustainLevel[editorCluster];
  drawHandle(plotX(aF),      plotY(1));   // attack peak
  drawHandle(plotX(aF + dF), plotY(S));   // decay/sustain
  drawHandle(plotX(1 - rF),  plotY(S));   // release start

  fill(220);
  textAlign(LEFT, TOP);
  textSize(15);
  text("A " + nf(aF, 1, 2) + "    D " + nf(dF, 1, 2) +
       "    S " + nf(S, 1, 2) + "    R " + nf(rF, 1, 2) +
       "    (sustain span " + nf(max(0, 1 - aF - dF - rF), 1, 2) + ")", pL, pB + 16);
  int q = constrain(round(ccVal[editorCluster] * 127), 0, 127);
  text("CC " + (BASE_CC + editorCluster) + " = " + q +
       (midiEnabled ? "" : "   (MIDI muted)"), pL, pB + 40);

  noStroke();
}

void editorMousePressed() {
  int c = editorCluster;
  float[] hx = { plotX(attackFrac[c]), plotX(attackFrac[c] + decayFrac[c]), plotX(1 - releaseFrac[c]) };
  float[] hy = { plotY(1),             plotY(sustainLevel[c]),             plotY(sustainLevel[c]) };
  dragHandle = -1;
  float best = 16;  // pick radius in px
  for (int h = 0; h < 3; h++) {
    float d = dist(mouseX, mouseY, hx[h], hy[h]);
    if (d < best) { best = d; dragHandle = h; }
  }
}

void editorMouseDragged() {
  if (dragHandle < 0) return;
  int c = editorCluster;
  float frac = constrain((mouseX - editPlotL()) / (editPlotR() - editPlotL()), 0, 1);
  float val  = constrain((editPlotB() - mouseY) / (editPlotB() - editPlotT()), 0, 1);
  if (dragHandle == 0) {            // attack peak: x -> attack
    attackFrac[c] = frac;
  } else if (dragHandle == 1) {     // decay/sustain: x -> decay end, y -> sustain
    decayFrac[c]    = frac - attackFrac[c];
    sustainLevel[c] = val;
  } else {                          // release start: x -> release
    releaseFrac[c] = 1 - frac;
  }
  clampAdsr(c);
}
