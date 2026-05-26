// SynchronizerVis — paginated event grid + waveform thumbnail.
//
// Layout (top to bottom):
//   - HUD line
//   - Event grid: 5 rows (pitch, brightness, energy, duration, timbre).
//     Each event is a vertical stack of 5 colored cells, positioned by its
//     start_time within the current page window. Cells flash on onset and
//     fade through the transient's duration.
//   - Waveform thumbnail: full-track peaks; current page window highlighted;
//     playhead marker shows position in the entire track.
//
// Keys:
//   space         play / pause
//   ← / →         page back / forward
//   r             jump to start
//   ctrl/cmd+s    save edits to <basename>_v<N>.csv in data/
//
// Mouse:
//   left-click on an event      toggle disabled (excluded from saved CSV)
//   right-click + drag on cell  drag up = higher bucket value
//                               (drag down = lower), per-row bucket ladder
//
// Data files in data/:
//   <AUDIO_FILE>   the audio that plays (WAV/MP3/AIFF/OGG — Processing Sound
//                  does NOT support FLAC)
//   <CSV_FILE>     events from `synchronizer ... -o ...`
//   <WAVE_FILE>    waveform peaks, auto-generated as
//                  <csv_stem>_waveform.csv alongside the events CSV.

import processing.sound.*;
import java.io.File;

final String AUDIO_FILE     = "06 Mdrmx.wav";
final String CSV_FILE       = "06_Mdrmx.csv";
final String WAVE_FILE      = "06_Mdrmx_waveform.csv";
final String SEGMENTS_FILE  = "06_Mdrmx_segments.csv";
final int   N_TIMBRE_CLUSTERS = 6;
final int   N_SEGMENT_LABELS  = 4;
final float PAGE_DURATION_S   = 4.0;
final float DRAG_PIXELS_PER_STEP = 25;

SoundFile sound;
Table eventsTable;
Table waveformTable;

ArrayList<Event> events = new ArrayList<Event>();
ArrayList<Segment> segments = new ArrayList<Segment>();
color[] segmentColors;
float[] wavePeaks;
float   trackDuration;
PGraphics waveformBuffer;

final String[] PITCH      = {"unpitched", "low", "mid", "high"};
final String[] BRIGHTNESS = {"dark", "mid", "bright"};
final String[] ENERGY     = {"soft", "medium", "loud"};
final String[] DURATION   = {"short", "medium", "long"};
String[] TIMBRE;

String[][] rowValues;
final String[] rowNames = {"pitch", "brightness", "energy", "duration", "timbre"};
final String[] csvCols  = {"pitch_bucket", "brightness_bucket", "energy_bucket", "duration_bucket", "timbre_cluster"};

color[][] palettes;

// Drag state for right-click bucket editing.
int   dragEventIdx     = -1;
int   dragRow          = -1;
int   dragStartBucket  = -1;
float dragStartY       = 0;

// Transient save-notice (HUD).
String savedNotice       = "";
int    savedNoticeUntil  = 0;

class Event {
  float t, dur;
  int   rowIndex;       // index into eventsTable, needed for save
  int[] bucketIdx;      // current (possibly edited) bucket index per row
  boolean disabled = false;
  Event(int rowIndex, float t, float dur, int[] bucketIdx) {
    this.rowIndex = rowIndex;
    this.t = t; this.dur = dur; this.bucketIdx = bucketIdx;
  }
}

class Segment {
  float startTime, endTime;
  int   label;
  Segment(float startTime, float endTime, int label) {
    this.startTime = startTime; this.endTime = endTime; this.label = label;
  }
}

int indexOfBucket(String[] arr, String s) {
  for (int i = 0; i < arr.length; i++) if (arr[i].equals(s)) return i;
  return -1;
}

void setup() {
  size(1920, 1080, P2D);
  frameRate(60);

  TIMBRE = new String[N_TIMBRE_CLUSTERS];
  for (int i = 0; i < N_TIMBRE_CLUSTERS; i++) TIMBRE[i] = str(i);
  rowValues = new String[][]{PITCH, BRIGHTNESS, ENERGY, DURATION, TIMBRE};

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

  sound = new SoundFile(this, AUDIO_FILE);
  trackDuration = sound.duration();

  buildWaveformBuffer();

  sound.play();
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
  int n = wavePeaks.length;
  float mid = wH / 2.0;
  for (int i = 0; i < n; i++) {
    float x = (float) i / n * wW;
    float h = wavePeaks[i] * (wH / 2) * 0.95;
    waveformBuffer.line(x, mid - h, x, mid + h);
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
  palettes[3] = new color[]{ color(235, 110, 80), color(220, 200, 80), color(90, 200, 220) };
  palettes[4] = new color[N_TIMBRE_CLUSTERS];
  colorMode(HSB, 360, 100, 100);
  for (int i = 0; i < N_TIMBRE_CLUSTERS; i++) {
    palettes[4][i] = color(i * 360.0 / N_TIMBRE_CLUSTERS, 70, 95);
  }
  colorMode(RGB, 255);
}

// --- Layout constants — kept consistent between draw and hit-test. -----------

float gridLeft()   { return 140; }
float gridRight()  { return width - 40; }
float gridTop()    { return 90; }
float gridBottom() { return height - 220; }
float rowHeight()  { return (gridBottom() - gridTop()) / rowValues.length; }
float cellSize()   { return min(rowHeight() * 0.7, 48); }

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

  float now = sound.position();
  int   currentPage = (int) (now / PAGE_DURATION_S);
  float pageStart   = currentPage * PAGE_DURATION_S;
  float pageEnd     = pageStart + PAGE_DURATION_S;

  ArrayList<Event> pageEvents = new ArrayList<Event>();
  for (Event e : events) {
    if (e.t >= pageStart && e.t < pageEnd) pageEvents.add(e);
  }

  drawGrid(pageEvents, pageStart, pageEnd, now);
  drawDragOverlay(pageStart, pageEnd);
  drawWaveform(now, pageStart, pageEnd);
  drawHUD(now, currentPage, pageEvents.size());
}

void drawGrid(ArrayList<Event> pageEvents, float pageStart, float pageEnd, float now) {
  float gL = gridLeft(), gR = gridRight(), gT = gridTop(), gB = gridBottom();
  float rowH = rowHeight();
  float cs   = cellSize();
  int   nRows = rowValues.length;

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
  String state = sound.isPlaying() ? "" : "  [PAUSED]";

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
  text("space  play/pause     ← →  page seek     r  to start     ctrl/cmd+s  save", width - 24, 24);

  if (dragEventIdx >= 0) {
    Event e = events.get(dragEventIdx);
    int bi = e.bucketIdx[dragRow];
    String name = rowNames[dragRow];
    String fromVal = rowValues[dragRow][dragStartBucket];
    String toVal   = (bi >= 0 ? rowValues[dragRow][bi] : "?");
    fill(255, 230, 80);
    textAlign(LEFT, TOP);
    text("editing event " + dragEventIdx + " — " + name + ": " + fromVal + " → " + toVal, 24, 50);
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
  int eventIdx = findEventNear(mouseX, mouseY);
  if (eventIdx < 0) return;
  if (mouseButton == LEFT) {
    Event e = events.get(eventIdx);
    e.disabled = !e.disabled;
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
  if (dragEventIdx < 0) return;
  float deltaY = dragStartY - mouseY;  // drag up = positive
  int steps = (int) (deltaY / DRAG_PIXELS_PER_STEP);
  int nBuckets = rowValues[dragRow].length;
  int newIdx = constrain(dragStartBucket + steps, 0, nBuckets - 1);
  events.get(dragEventIdx).bucketIdx[dragRow] = newIdx;
}

void mouseReleased() {
  dragEventIdx = -1;
  dragRow      = -1;
}

// --- Keys --------------------------------------------------------------------

void keyPressed() {
  // ctrl/cmd + s — save
  if ((keyEvent.isControlDown() || keyEvent.isMetaDown())
      && (key == 's' || key == 'S' || key == '')) {
    saveEdits();
    return;
  }
  if (key == ' ') {
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
}

void seek(float target) {
  target = constrain(target, 0, max(0, trackDuration - 0.05));
  boolean wasPlaying = sound.isPlaying();
  sound.jump(target);
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
