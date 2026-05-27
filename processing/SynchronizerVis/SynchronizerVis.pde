// SynchronizerVis — paginated event grid + waveform thumbnail.
//
// Layout (top to bottom, left column):
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
// Right panel (always visible):
//   - Per-cluster ADSR envelope curve.
//   - Sliders for A / D / S / R.
//   - LIN / EXP shape toggles for attack and decay.
//   - CC level meter.
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
//   m             toggle MIDI output on/off
//   0-9           reassign hovered event's cluster
//   ctrl/cmd+s    save event edits to <basename>_v<N>.csv
//
// Mouse:
//   left-click on an event        toggle disabled (excluded from saved CSV)
//   shift+left-click on an event  preview: plays from onset for its duration, then stops
//   right-click + drag on cell    drag up = higher bucket value
//                                 (drag down = lower), per-row bucket ladder
//   right panel: drag A/D/S/R sliders   reshape envelope per cluster
//   right panel: click LIN / EXP        toggle attack or decay curve shape
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
//   <csv_stem>_adsr.csv  per-cluster ADSR params (written on drag release / toggle).

import processing.sound.*;
import java.io.File;
// MIDI output lives in MidiOut.java (a plain-Java tab) — the Processing
// preprocessor can't parse javax.sound.midi's nested types in this .pde.

// --- Track / file config (edit these to switch tracks) -----------------------

final String AUDIO_FILE     = "04_Krib.wav";
final String CSV_FILE       = "04_Krib.csv";
final String WAVE_FILE      = "04_Krib_waveform.csv";
final String SEGMENTS_FILE  = "04_Krib_segments.csv";
final String GRID_FILE      = "04_Krib_grid.csv";
// Per-stem melody CSVs — loaded lazily; skip any that are absent.
final String[] MELODY_STEMS = {"vocals", "bass", "other"};
final String[] MELODY_FILES = {
  "04_Krib_vocals_melody.csv",
  "04_Krib_bass_melody.csv",
  "04_Krib_other_melody.csv",
};

// --- Analysis / display config -----------------------------------------------

final int   N_TIMBRE_CLUSTERS    = 6;
final int   N_TRANSIENT_CLUSTERS = 2;
final int   N_SEGMENT_LABELS     = 4;
final int[] DIVISIONS            = {4, 8, 16, 32};  // metronome note values
final float PAGE_DURATION_S      = 4.0;
final float DRAG_PIXELS_PER_STEP = 25;

// Onset detection and beat tracking are independent estimators, so a transient
// the ear hears as "on the beat" lands a few ms off the nearest tick. Snap
// events whose detected time is within this tolerance of a 1/32 tick to that
// tick — purely visual, the saved CSV keeps the original time. Genuinely
// off-beat hits (> tolerance) keep their natural position. Toggle with 'q'.
final float GRID_SNAP_TOLERANCE_S = 0.030;

// --- MIDI / ADSR config ------------------------------------------------------
// Virtual MIDI port to send to (substring match). loopMIDI on Windows; on Mac
// the IAC Driver, on Linux an ALSA virtual port. If no match is found the
// sketch still runs, with MIDI disabled.
final String  MIDI_PORT_NAME   = "loopMIDI Port";
final int     MIDI_CHANNEL     = 0;      // 0-indexed; 0 = MIDI channel 1
final int     BASE_CC          = 20;     // cluster i -> CC (BASE_CC + i)
// Envelope length = max(transient duration, MIN_ENV_S). The floor guarantees
// even very short transients produce a CC gesture the frame loop can resolve.
final float   MIN_ENV_S        = 0.08;
final boolean RELEASE_ON_PAUSE = false;  // true = send 0s on pause instead of holding

// --- Audio / data state ------------------------------------------------------

SoundFile sound;
Table     eventsTable;
Table     waveformTable;

ArrayList<Event>              events    = new ArrayList<Event>();
ArrayList<Segment>            segments  = new ArrayList<Segment>();
ArrayList<GridTick>           gridTicks = new ArrayList<GridTick>();
ArrayList<ArrayList<Note>>    melodyNotes;  // one list per MELODY_STEMS entry
color[]   segmentColors;
color[]   divisionColors;
color[]   chromaColors;         // 12-pitch-class palette for note bars
float[]   wavePeaks;
float     waveformWindowDur;   // duration of each wavePeaks sample in seconds
float[]   snapTickTimes;       // sorted 1/32 tick times used for grid snap
boolean   gridSnapEnabled = true;
float     trackDuration;
PGraphics waveformBuffer;

// Bucket label arrays — indices match CSV values.
final String[] PITCH      = {"unpitched", "low", "mid", "high"};
final String[] BRIGHTNESS = {"dark", "mid", "bright"};
final String[] ENERGY     = {"soft", "medium", "loud"};
final String[] DURATION   = {"short", "medium", "long"};
String[]       TIMBRE;
String[]       TRANSIENT_CLUSTER;

String[][]     rowValues;
final String[] rowNames = {""};
final String[] csvCols  = {"transient_cluster"};

color[][] palettes;

// --- Interaction state -------------------------------------------------------

int   hoverEventIdx   = -1;   // updated by mouseMoved(); used for digit-key reassign
int   dragEventIdx    = -1;
int   dragRow         = -1;
int   dragStartBucket = -1;
float dragStartY      = 0;

float playbackRate = 1.0;
float stopAtTime   = -1;   // pause when playhead crosses this (preview feature)

String savedNotice      = "";
int    savedNoticeUntil = 0;

// --- ADSR / MIDI state -------------------------------------------------------

float[]   attackFrac, decayFrac, sustainLevel, releaseFrac;
boolean[] attackExp, decayExp;  // true = exponential curve shape
float[]   ccVal;      // live envelope value per cluster, 0..1 (for meters)
int[]     lastSent;   // last quantized CC value sent (-1 = not yet sent)

MidiOut midiOut;
boolean midiEnabled = true;

int sliderDragCluster = -1;  // -1 = not dragging
int sliderDragParam   = -1;  // 0=A 1=D 2=S 3=R
float[] eventNormRms;        // quantile-normalised RMS per event (indexed by rowIndex)

// --- Data classes ------------------------------------------------------------

class Event {
  float origT;        // detected onset time (ground truth; also saved to CSV)
  float t, dur;       // t may be snapped to a grid tick (visual only)
  float rms;          // raw energy value from CSV, used for quantile normalisation
  int   rowIndex;     // row in eventsTable, needed for save
  int[] bucketIdx;    // current (possibly edited) bucket index per row
  boolean disabled = false;
  Event(int rowIndex, float t, float dur, float rms, int[] bucketIdx) {
    this.rowIndex = rowIndex;
    this.origT = t; this.t = t; this.dur = dur; this.rms = rms; this.bucketIdx = bucketIdx;
  }
}

class Segment {
  float startTime, endTime;
  int   label;
  Segment(float s, float e, int l) { startTime = s; endTime = e; label = l; }
}

class GridTick {
  float t;
  int   division, beat, phase;  // phase 0 = on the beat
  GridTick(float t, int div, int beat, int phase) {
    this.t = t; this.division = div; this.beat = beat; this.phase = phase;
  }
}

class Note {
  float startTime, endTime, confidence;
  int   midi;
  String name;  // e.g. "C4", "F#3" — ASCII only (Processing font has no sharp glyph)
  Note(float s, float e, int midi, String name, float conf) {
    startTime = s; endTime = e; this.midi = midi; this.name = name; confidence = conf;
  }
}

// --- Helpers -----------------------------------------------------------------

int indexOfBucket(String[] arr, String s) {
  for (int i = 0; i < arr.length; i++) if (arr[i].equals(s)) return i;
  return -1;
}

// --- Entry point -------------------------------------------------------------

void setup() {
  size(1920, 1080, P2D);
  frameRate(120);

  TIMBRE = new String[N_TIMBRE_CLUSTERS];
  for (int i = 0; i < N_TIMBRE_CLUSTERS; i++) TIMBRE[i] = str(i);
  TRANSIENT_CLUSTER = new String[N_TRANSIENT_CLUSTERS];
  for (int i = 0; i < N_TRANSIENT_CLUSTERS; i++) TRANSIENT_CLUSTER[i] = str(i);
  rowValues = new String[][]{TRANSIENT_CLUSTER};

  buildPalettes();

  eventsTable = loadTable(CSV_FILE, "header");
  int idx = 0;
  for (TableRow r : eventsTable.rows()) {
    int[] bi = new int[rowValues.length];
    for (int i = 0; i < rowValues.length; i++)
      bi[i] = indexOfBucket(rowValues[i], r.getString(csvCols[i]));
    events.add(new Event(idx, r.getFloat("start_time"), r.getFloat("duration"),
                         r.getFloat("energy"), bi));
    idx++;
  }
  buildQuantileNorms();

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
  trackDuration    = sound.duration();
  waveformWindowDur = (wavePeaks.length > 0) ? trackDuration / wavePeaks.length : 1.0 / 44100;

  buildWaveformBuffer();
  sound.rate(playbackRate);

  initAdsr();
  initMidi();
}
