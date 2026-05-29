// Input.pde — mouse handlers, keyboard handlers, playback seek, and CSV save.

// --- Stem label hit-testing and switching ------------------------------------

int findStemLabelAt(float mx, float my) {
  if (my < 61 || my > 83) return -1;
  float lx = gridLeft();
  textSize(13);
  for (int i = 0; i < STEM_LABELS.length; i++) {
    boolean exists = stemFiles != null && i < stemFiles.length
                     && (i == 0 || (stemFiles[i].length() > 0
                         && new File(dataPath(stemFiles[i])).exists()));
    if (!exists) continue;
    float bw = textWidth(STEM_LABELS[i]) + 16;
    if (mx >= lx && mx <= lx + bw) return i;
    lx += bw + 8;
  }
  return -1;
}

void switchToStem(int idx) {
  if (idx == activeStem) return;
  float pos = sound.position();
  boolean wasPlaying = sound.isPlaying();
  sound.pause();
  sound = new SoundFile(this, stemFiles[idx]);
  trackDuration = sound.duration();
  sound.jump(constrain(pos, 0, trackDuration - 0.05));
  sound.rate(playbackRate);
  if (!wasPlaying) sound.pause();
  activeStem = idx;

  // Switch waveform visualization to the selected stem (fall back to mix if absent).
  float[] sw = (allStemWavePeaks != null && idx < allStemWavePeaks.length)
               ? allStemWavePeaks[idx] : null;
  wavePeaks = (sw != null) ? sw : allStemWavePeaks[0];
  waveformWindowDur = (wavePeaks.length > 0) ? trackDuration / wavePeaks.length : 1.0 / 44100;
  buildWaveformBuffer();
  gridBgPage = -1;
}

// --- Waveform thumbnail hit-testing ------------------------------------------

// Returns the track time corresponding to a click in the waveform strip,
// or -1 if the click is outside the strip.
float waveformTimeAt(float mx, float my) {
  float wLeft = 40;
  float wTop  = height - 160;
  float wW    = panelLeft() - 60;
  float wH    = 110;
  if (my < wTop || my > wTop + wH || mx < wLeft || mx > wLeft + wW) return -1;
  return constrain((mx - wLeft) / wW * trackDuration, 0, trackDuration - 0.05);
}

// --- Event hit-testing -------------------------------------------------------

int findEventNear(float mx, float my) {
  float now = sound.position();
  float pageStart = pageStartFor(now);
  float pageEnd   = pageStart + PAGE_DURATION_S;
  float gL = gridLeft(), gR = gridRight();

  if (mx < gL || mx > gR) return -1;
  if (my < gridTop() || my > gridBottom()) return -1;

  // Accept any event whose envelope span [ex, ex+envW] contains mx.
  // Among those, pick the one with the nearest start.
  int best = -1; float bestDx = Float.MAX_VALUE;
  for (int i = 0; i < events.size(); i++) {
    Event e = events.get(i);
    if (e.t < pageStart || e.t >= pageEnd) continue;
    float ex   = eventX(e, pageStart);
    float envW = eventEnvLen(e) / PAGE_DURATION_S * (gR - gL);
    if (mx < ex - 4 || mx > ex + envW + 4) continue;
    float dx = abs(mx - ex);
    if (dx < bestDx) { bestDx = dx; best = i; }
  }
  return best;
}

int rowAt(float my) {
  float cs = cellSize();
  for (int row = 0; row < rowValues.length; row++)
    if (abs(my - rowCenterY(row)) <= cs / 2 + 2) return row;
  return -1;
}

// --- Mouse -------------------------------------------------------------------

void mousePressed() {
  if (mouseX >= panelLeft()) { panelMousePressed(); return; }

  int stemIdx = findStemLabelAt(mouseX, mouseY);
  if (stemIdx >= 0) { switchToStem(stemIdx); return; }

  float waveT = waveformTimeAt(mouseX, mouseY);
  if (waveT >= 0) { seek(waveT); return; }

  int eventIdx = findEventNear(mouseX, mouseY);
  if (eventIdx < 0) { selectedEventIdx = -1; return; }

  if (mouseButton == LEFT) {
    Event e = events.get(eventIdx);
    if (mouseEvent.isShiftDown()) {
      stopAtTime = e.origT + e.dur;
      sound.jump(e.origT);
      sound.rate(playbackRate);
    } else {
      // Record press; decide click vs drag in mouseDragged / mouseReleased.
      timeDragEventIdx    = eventIdx;
      timeDragStartX      = mouseX;
      timeDragStartY      = mouseY;
      timeDragOrigT       = e.origT;
      timeDragStartBucket = e.bucketIdx[csvCols.length - 1];
      timeDragMode        = 0;
      timeDragMoved       = false;
    }
  } else if (mouseButton == RIGHT) {
    int row = rowAt(mouseY);
    if (row < 0) return;
    Event e = events.get(eventIdx);
    if (e.bucketIdx[row] < 0) return;
    dragEventIdx    = eventIdx;
    dragRow         = row;
    dragStartBucket = e.bucketIdx[row];
    dragStartY      = mouseY;
  }
}

void mouseDragged() {
  if (knobDragCluster >= 0) { panelMouseDragged(); return; }

  if (timeDragEventIdx >= 0) {
    float deltaX = mouseX - timeDragStartX;
    float deltaY = mouseY - timeDragStartY;
    // Lock direction on first move past threshold.
    if (timeDragMode == 0 && (abs(deltaX) > 3 || abs(deltaY) > 3)) {
      timeDragMode  = (abs(deltaY) > abs(deltaX)) ? 2 : 1;
      timeDragMoved = true;
    }
    if (timeDragMode == 1) {
      float deltaT = deltaX / (gridRight() - gridLeft()) * PAGE_DURATION_S;
      float newT   = constrain(timeDragOrigT + deltaT, 0, trackDuration - 0.01);
      Event e = events.get(timeDragEventIdx);
      e.t     = newT;
      e.origT = newT;
    } else if (timeDragMode == 2) {
      int clusterRow = csvCols.length - 1;
      int steps      = (int)((timeDragStartY - mouseY) / DRAG_PIXELS_PER_STEP);
      events.get(timeDragEventIdx).bucketIdx[clusterRow] =
        constrain(timeDragStartBucket + steps, 0, activeK - 1);
    }
    return;
  }

  if (dragEventIdx < 0) return;
  float deltaY = dragStartY - mouseY;
  int steps    = (int)(deltaY / DRAG_PIXELS_PER_STEP);
  int nBuckets = rowValues[dragRow].length;
  events.get(dragEventIdx).bucketIdx[dragRow] = constrain(dragStartBucket + steps, 0, nBuckets - 1);
}

void mouseReleased() {
  if (knobDragCluster >= 0) {
    knobDragCluster = -1;
    knobDragParam   = -1;
    saveAdsr();
    return;
  }

  if (timeDragEventIdx >= 0) {
    if (!timeDragMoved) {
      // Pure click — select (or deselect if already selected).
      selectedEventIdx = (selectedEventIdx == timeDragEventIdx) ? -1 : timeDragEventIdx;
    } else {
      // Committed drag — write new start_time back to eventsTable so Ctrl+S persists it.
      Event e = events.get(timeDragEventIdx);
      eventsTable.getRow(e.rowIndex).setString("start_time", nf(e.t, 0, 6));
      if (legatoEnabled) buildLegatoDurs();
    }
    timeDragEventIdx = -1;
    timeDragMoved    = false;
    return;
  }

  dragEventIdx = -1;
  dragRow      = -1;
}

void mouseMoved() {
  if (mouseX >= panelLeft()) { hoverEventIdx = -1; return; }
  hoverEventIdx = findEventNear(mouseX, mouseY);
}

// --- Keyboard ----------------------------------------------------------------

void keyPressed() {
  if ((keyEvent.isControlDown() || keyEvent.isMetaDown()) && (key == 's' || key == 'S')) {
    saveEdits();
    return;
  }
  if (key == ' ') {
    stopAtTime = -1;
    if (sound.isPlaying()) {
      sound.pause();
      for (int c = 0; c < N_TRANSIENT_CLUSTERS; c++) {
        if (lastSent[c] != 0) { sendCC(BASE_CC + c, 0); lastSent[c] = 0; }
      }
      if (midiOut != null) { midiOut.sendNoteOn(15, 24, 127); pausePulseOffAt = millis() + 20; }
    } else {
      sound.play();
    }
    return;
  }
  if (key == 'r' || key == 'R') { seek(0); return; }
  if (keyCode == LEFT)  seek(sound.position() - PAGE_DURATION_S);
  if (keyCode == RIGHT) seek(sound.position() + PAGE_DURATION_S);
  if (key == 'q' || key == 'Q') { gridSnapEnabled = !gridSnapEnabled; applyGridSnap(); }
  if (key == '-' || key == '_') { playbackRate = max(0.25, playbackRate - 0.25); sound.rate(playbackRate); }
  if (key == '=' || key == '+') { playbackRate = min(2.0,  playbackRate + 0.25); sound.rate(playbackRate); }
  if (key == 'l' || key == 'L') {
    loopEnabled = !loopEnabled;
    if (loopEnabled) {
      loopStart = pageStartFor(sound.position());
      loopEnd   = loopStart + PAGE_DURATION_S;
    }
  }
  if (key == 'm' || key == 'M') midiEnabled = !midiEnabled;
  if (key == ESC) {
    // Intercept Escape so Processing doesn't close the sketch.
    key = 0;
    selectedEventIdx = -1;
  }
  if ((key == 'd' || key == 'D') && selectedEventIdx >= 0) {
    Event e = events.get(selectedEventIdx);
    e.disabled = !e.disabled;
    disabledCount += e.disabled ? 1 : -1;
    selectedEventIdx = -1;
    if (legatoEnabled) buildLegatoDurs();
  }
  // Digit keys: reassign hovered event's transient_cluster. Only digits
  // within the active k make sense — clusters >= activeK are inert.
  if (key >= '0' && key <= '9' && hoverEventIdx >= 0) {
    int digit      = key - '0';
    int clusterRow = csvCols.length - 1;
    if (digit < activeK)
      events.get(hoverEventIdx).bucketIdx[clusterRow] = digit;
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

// --- Save edits to versioned CSV ---------------------------------------------

void saveEdits() {
  String baseStem = CSV_FILE.replaceAll("\\.csv$", "");
  String saveName = baseStem + "_v" + findNextVersion(baseStem) + ".csv";

  Table out = new Table();
  for (int col = 0; col < eventsTable.getColumnCount(); col++)
    out.addColumn(eventsTable.getColumnTitle(col));

  int written = 0, disabled = 0;
  for (Event e : events) {
    if (e.disabled) { disabled++; continue; }
    TableRow src = eventsTable.getRow(e.rowIndex);
    TableRow dst = out.addRow();
    for (int col = 0; col < eventsTable.getColumnCount(); col++)
      dst.setString(col, src.getString(col));
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
          try {
            int v = Integer.parseInt(name.substring(prefix.length(), name.length() - 4));
            if (v > maxV) maxV = v;
          } catch (NumberFormatException nfe) {}
        }
      }
    }
  }
  return maxV + 1;
}
