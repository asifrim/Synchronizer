// SynchronizerVis — paginated event grid + waveform thumbnail.
//
// Layout (top to bottom, left column):
//   - HUD line
//   - Event grid: one row of ADSR-shaped envelope curves, one per transient,
//     coloured by holistic cluster and positioned by start_time within the
//     current page window. Curve height scales with the transient's RMS
//     quantile within its cluster; curves brighten on the playhead crossing
//     and fade through the transient's duration.
//   - Melody panel: 3 rows (vocals / bass / other) of per-stem note bars.
//   - Metronome grid: 4 rows (1/4, 1/8, 1/16, 1/32 note ticks), beat-anchored
//     so they follow the detected tempo. Each tick flashes as the playhead
//     crosses it; on-beat ticks (phase 0) are taller/brighter.
//   - Waveform thumbnail: full-track peaks; current page window highlighted;
//     playhead marker shows position in the entire track.
// Right panel (always visible):
//   - k-selector strip at top (k = 2..8).
//   - Per-cluster AD envelope curve preview.
//   - A and D rotary knobs (vertical-drag to change).
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
//   d             delete / restore selected event (toggles disabled; excluded from saved CSV)
//   Esc           deselect event
//   0-9           reassign hovered event's cluster (digits >= activeK ignored)
//   ctrl/cmd+s    save event edits to <basename>_v<N>.csv
//
// Mouse:
//   left-click on an event            select (amber outline); click again or click
//                                     empty space to deselect
//   left-drag horizontally on event   shift event time left/right; Ctrl+S persists
//   left-drag vertically on event     reassign cluster up/down within active k
//   shift+left-click on an event      preview: plays from onset for its duration, then stops
//   right-click + drag on cell        drag up = higher bucket value
//                                     (drag down = lower), per-row bucket ladder
//   right panel: drag A / D knobs     reshape envelope per cluster
//   right panel: click LIN / EXP      toggle attack or decay curve shape
//   right panel: click k-selector     switch the active number of clusters
//   right panel: click "RMS scale"    toggle quantile RMS scaling for MIDI
//
// MIDI output (drives TouchDesigner): as the playhead crosses each transient,
// an AD envelope is emitted as a 7-bit MIDI CC. Each transient_cluster has
// its own AD shape and its own CC. Contract (do not change without updating
// the TD patch): MIDI channel 1; cluster i -> CC (BASE_CC + i); value 0-127,
// sent only when it changes. Envelope total time = the transient's duration
// (floored at MIN_ENV_S). Smooth the 7-bit stepping in TD with a Lag/Filter
// CHOP. Sent to the virtual port whose name contains MIDI_PORT_NAME (loopMIDI
// on Windows); if absent, the sketch runs as a visualizer with MIDI off.
//
// Data files in data/<TRACK>/:
//   track.wav      the audio that plays (WAV/MP3/AIFF/OGG — Processing Sound
//                  does NOT support FLAC)
//   events.csv     events from `synchronizer ... -o data/<TRACK>`
//   waveform.csv   waveform peaks for the thumbnail strip.
//   segments.csv   structural segments (optional).
//   grid.csv       metronome ticks (optional).
//   <stem>_melody.csv  per-stem note events (optional).
//   adsr.csv       per-cluster AD params (written on drag release / toggle).

import processing.sound.*;
import java.io.File;
// MIDI output lives in MidiOut.java (a plain-Java tab) — the Processing
// preprocessor can't parse javax.sound.midi's nested types in this .pde.

// --- Track / file config (change only TRACK to switch tracks) ----------------

final String TRACK = "05_Tilapia";

final String AUDIO_FILE    = TRACK + "/track.wav";
final String CSV_FILE      = TRACK + "/events.csv";
final String WAVE_FILE     = TRACK + "/waveform.csv";
final String SEGMENTS_FILE = TRACK + "/segments.csv";
final String GRID_FILE     = TRACK + "/grid.csv";
// Per-stem melody CSVs — loaded lazily; skip any that are absent.
final String[] MELODY_STEMS = {"vocals", "bass", "other"};
final String[] MELODY_FILES = {
  TRACK + "/vocals_melody.csv",
  TRACK + "/bass_melody.csv",
  TRACK + "/other_melody.csv",
};
// Demucs stem WAVs for playback switching.
final String STEM_DRUMS_FILE  = TRACK + "/drums.wav";
final String STEM_VOCALS_FILE = TRACK + "/vocals.wav";
final String STEM_BASS_FILE   = TRACK + "/bass.wav";
final String STEM_OTHER_FILE  = TRACK + "/other.wav";

// --- Analysis / display config -----------------------------------------------

final int   N_TIMBRE_CLUSTERS    = 6;
final int   N_TRANSIENT_CLUSTERS = 8;  // always 8 panels; activeK controls how many are live
final int   MULTI_K_MIN          = 2;
final int   MULTI_K_MAX_FIXED    = 8;
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
// Metronome clock notes: 4th/8th/16th ticks fire note (BASE_CLOCK_NOTE + di)
// on MIDI_CHANNEL for CLOCK_GATE_S seconds — quarter=36, 8th=37, 16th=38.
final int     BASE_CLOCK_NOTE  = 36;
final float   CLOCK_GATE_S     = 0.020;  // 20 ms gate per tick

// --- Stem playback -----------------------------------------------------------

final String[] STEM_LABELS = {"Mix", "Percussion", "Vocals", "Bass", "Other"};
String[] stemFiles;          // parallel to STEM_LABELS; set in setup()
String[] stemWaveFiles;      // waveform CSV paths parallel to STEM_LABELS; set in setup()
float[][] allStemWavePeaks;  // per-stem waveform peaks; null entries if CSV absent
int      activeStem = 0;

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
PGraphics gridBgBuffer;        // cached grid waveform background; rebuilt on page change
int       gridBgPage = -1;

// Bucket label arrays — indices match CSV values. Only TRANSIENT_CLUSTER is
// used by the grid; TIMBRE survives as a label source for the (legacy) palette
// builder if a later panel needs it.
String[]       TIMBRE;
String[]       TRANSIENT_CLUSTER;

String[][]     rowValues;
final String[] rowNames = {""};
final String[] csvCols  = {"transient_cluster"};

color[][] palettes;

// --- Interaction state -------------------------------------------------------

int   hoverEventIdx    = -1;   // updated by mouseMoved(); used for digit-key reassign
int   selectedEventIdx = -1;   // left-click selects; 'd' deletes; Esc clears
int   dragEventIdx    = -1;
int   dragRow         = -1;
int   dragStartBucket = -1;
float dragStartY      = 0;
int   timeDragEventIdx   = -1;  // left-drag state (time-shift or cluster-change)
float timeDragStartX     = 0;
float timeDragStartY     = 0;
float timeDragOrigT      = 0;
int   timeDragStartBucket = -1;
int   timeDragMode       = 0;   // 0=undecided, 1=horizontal/time, 2=vertical/cluster
boolean timeDragMoved    = false;
int   disabledCount   = 0;    // maintained on toggle; read by HUD
int   cachedSegmentIdx = -1;  // current-segment cache; reused while playhead stays in range

float playbackRate = 1.0;
float stopAtTime   = -1;   // pause when playhead crosses this (preview feature)
boolean loopEnabled = false;
float   loopStart   = 0;
float   loopEnd     = 0;

String savedNotice      = "";
int    savedNoticeUntil = 0;

// --- AD / MIDI state ---------------------------------------------------------

float[]   attackFrac, decayFrac;
boolean[] attackExp, decayExp;   // true = exponential curve shape
float[]   clusterOffsetMs;       // per-cluster trigger-time offset, -100..+100 ms
boolean[] clusterEnabled;        // per-cluster on/off; false = no MIDI, greyed in grid
float[]   ccVal;                 // live envelope value per cluster, 0..1
int[]     lastSent;              // last quantized CC value sent (-1 = not yet sent)
// Envelope shape only changes when a knob/toggle moves, but it's sampled
// many times per frame for the grid + panel preview. Cache the sampled
// curve and rebuild it on edit; consumers read from envCurveCache.
final int N_ENV_SAMPLES = 48;
float[][] envCurveCache;         // [N_TRANSIENT_CLUSTERS][N_ENV_SAMPLES+1]

MidiOut midiOut;
boolean midiEnabled = true;
boolean[] clockNoteOn;  // per-division gate state; true while note-on has been sent

int   knobDragCluster    = -1;   // -1 = not dragging
int   knobDragParam      = -1;   // 0=A  1=D
float knobDragStartY     = 0;
float knobDragStartValue = 0;
float[] eventNormRms;        // quantile-normalised RMS per event (indexed by rowIndex)

int     activeK    = 2;      // which k is active for display/MIDI (MULTI_K_MIN..MULTI_K_MAX_FIXED)
int[][] kClusters;           // kClusters[k-MULTI_K_MIN][eventIdx]
boolean midiEnergyScale = true;  // scale CC output by quantile-normalised RMS

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
    events.add(new Event(idx, r.getFloat("start_time"), r.getFloat("duration"),
                         r.getFloat("energy"), bi));
    idx++;
  }
  loadKClusters();       // populates kClusters and sets bucketIdx[0] from activeK
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

  stemFiles = new String[]{AUDIO_FILE, STEM_DRUMS_FILE, STEM_VOCALS_FILE, STEM_BASS_FILE, STEM_OTHER_FILE};
  stemWaveFiles = new String[]{
    WAVE_FILE,
    TRACK + "/drums_waveform.csv",
    TRACK + "/vocals_waveform.csv",
    TRACK + "/bass_waveform.csv",
    TRACK + "/other_waveform.csv",
  };

  sound = new SoundFile(this, AUDIO_FILE);
  trackDuration    = sound.duration();
  waveformWindowDur = (wavePeaks.length > 0) ? trackDuration / wavePeaks.length : 1.0 / 44100;

  buildWaveformBuffer();
  loadStemWavePeaks();
  sound.rate(playbackRate);

  initAdsr();
  initMidi();
}
