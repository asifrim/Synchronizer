// Draw.pde — main draw loop and all left-column panel drawing functions.

// Grid event intensity: pre-onset (dim), post-onset base, and the peak boost
// that decays back to base over the event's duration. The falloff exponent
// >1 makes the brightest moments concentrated near the onset.
final float EVENT_PRE_INTENSITY  = 0.30;
final float EVENT_BASE_INTENSITY = 0.55;
final float EVENT_PEAK_BOOST     = 0.45;
final float EVENT_FALLOFF_EXP    = 1.4;

// Metronome tick geometry + flash timing. Flash starts 15 ms before the tick
// (so the visual leads the audio slightly) and decays over the next 140 ms.
final float METRO_BEAT_H_FRAC   = 0.42;
final float METRO_SUB_H_FRAC    = 0.26;
final float METRO_FLASH_LEAD_S  = -0.015;
final float METRO_FLASH_HOLD_S  = 0.14;

void draw() {
  background(15);

  if (stopAtTime >= 0 && sound.position() >= stopAtTime) {
    sound.pause();
    stopAtTime = -1;
  }
  if (loopEnabled && sound.isPlaying() && sound.position() >= loopEnd) {
    sound.jump(loopStart);
    sound.rate(playbackRate);
  }

  float now = sound.position();
  updateMidi(now);
  updateClockMidi(now);

  int   currentPage = (int)(now / PAGE_DURATION_S);
  float pageStart   = currentPage * PAGE_DURATION_S;
  float pageEnd     = pageStart + PAGE_DURATION_S;

  ArrayList<Event> pageEvents = new ArrayList<Event>();
  for (Event e : events)
    if (e.t >= pageStart && e.t < pageEnd) pageEvents.add(e);

  drawGrid(pageEvents, pageStart, pageEnd, now);
  drawDragOverlay(pageStart, pageEnd);
  drawMelody(pageStart, pageEnd, now);
  drawMetro(pageStart, pageEnd, now);
  drawWaveform(now, pageStart, pageEnd);
  drawAdsrPanel(now);
  drawHUD(now, currentPage, pageEvents.size());
  drawStemLabels();
}

// --- Event grid --------------------------------------------------------------

void rebuildGridBgBuffer(float pageStart, float pageEnd) {
  float gL = gridLeft(), gR = gridRight();
  float gT = gridTop(),  gB = gridBottom();
  int bufW = (int)(gR - gL) + 1;
  int bufH = (int)(gB - gT);
  if (gridBgBuffer == null || gridBgBuffer.width != bufW || gridBgBuffer.height != bufH) {
    gridBgBuffer = createGraphics(bufW, bufH, P2D);
  }
  float fullH   = bufH * 0.92;
  float pageDur = pageEnd - pageStart;
  int   n       = wavePeaks.length;

  gridBgBuffer.beginDraw();
  gridBgBuffer.clear();
  gridBgBuffer.stroke(55, 68, 95);
  gridBgBuffer.strokeWeight(1);
  gridBgBuffer.noFill();
  for (int px = 0; px < bufW; px++) {
    float t0 = pageStart + (float) px        / bufW * pageDur;
    float t1 = pageStart + (float)(px + 1.0) / bufW * pageDur;
    if (t0 >= trackDuration) break;
    int i0 = constrain((int)(t0 / waveformWindowDur), 0, n - 1);
    int i1 = constrain((int)(t1 / waveformWindowDur), 0, n - 1);
    if (i1 < i0) i1 = i0;
    float p = 0;
    for (int i = i0; i <= i1; i++) p = max(p, wavePeaks[i]);
    gridBgBuffer.line(px, bufH, px, bufH - p * fullH);
  }
  gridBgBuffer.endDraw();
}

void drawGridWaveformBackground(float pageStart, float pageEnd) {
  int page = (int)(pageStart / PAGE_DURATION_S);
  if (page != gridBgPage || gridBgBuffer == null) {
    rebuildGridBgBuffer(pageStart, pageEnd);
    gridBgPage = page;
  }
  image(gridBgBuffer, gridLeft(), gridTop());
}

void drawGrid(ArrayList<Event> pageEvents, float pageStart, float pageEnd, float now) {
  float gL = gridLeft(), gR = gridRight(), gT = gridTop(), gB = gridBottom();
  float cs = cellSize();
  int   nRows = rowValues.length;

  drawGridWaveformBackground(pageStart, pageEnd);

  // Baseline rule at the bottom of the grid.
  stroke(35); strokeWeight(1);
  line(gL, gB, gR, gB);
  noStroke();

  int   clusterRow = csvCols.length - 1;
  float maxEnvH    = (gB - gT) * 0.90;

  for (Event e : pageEvents) {
    int   cluster  = max(0, e.bucketIdx[clusterRow]);
    float offsetS  = clusterOffsetMs[cluster] / 1000.0;
    float ex  = gridLeft() + (e.t + offsetS - pageStart) / PAGE_DURATION_S * (gridRight() - gridLeft());
    float age = now - (e.t + offsetS);
    float intensity;
    if (e.disabled)       intensity = 0.0;
    else if (age < 0)     intensity = EVENT_PRE_INTENSITY;
    else if (age > e.dur) intensity = EVENT_BASE_INTENSITY;
    else                  intensity = EVENT_BASE_INTENSITY + EVENT_PEAK_BOOST * pow(1 - age / e.dur, EVENT_FALLOFF_EXP);
    float normRms  = (eventNormRms != null) ? eventNormRms[e.rowIndex] : 1.0;
    float envLen   = eventEnvLen(e);
    float envW     = envLen / PAGE_DURATION_S * (gR - gL);
    float[] curve  = envCurveCache[cluster];

    boolean clusterOff = !clusterEnabled[cluster];
    for (int row = 0; row < nRows; row++) {
      int b = e.bucketIdx[row];
      if (b < 0 || e.disabled) continue;
      float maxH = maxEnvH * normRms;

      noStroke();
      if (clusterOff) {
        fill(50, 52, 58, 90);
      } else {
        color c = palettes[row][b];
        fill(red(c) * intensity, green(c) * intensity, blue(c) * intensity, 200);
      }
      beginShape();
      vertex(ex, gB);
      for (int s = 0; s <= N_ENV_SAMPLES; s++) {
        float p = (float)s / N_ENV_SAMPLES;
        vertex(ex + p * envW, gB - curve[s] * maxH);
      }
      vertex(ex + envW, gB);
      endShape(CLOSE);
    }

    if (e.disabled) {
      stroke(120, 80, 80); strokeWeight(1);
      line(ex - cs / 2, gT + 6, ex + cs / 2, gB - 6);
    }
  }

  // Playhead
  if (now >= pageStart && now < pageEnd) {
    float playX = pagePlayheadX(now, pageStart);
    stroke(255, 200, 50, 200); strokeWeight(2);
    line(playX, gT - 12, playX, gB + 12);
    noStroke();
  }

  // Selection highlight — solid amber outline, drawn before hover so hover sits on top.
  if (selectedEventIdx >= 0 && selectedEventIdx < events.size()) {
    Event se = events.get(selectedEventIdx);
    if (se.t >= pageStart && se.t < pageEnd) {
      float sx    = eventX(se, pageStart);
      float sEnvW = eventEnvLen(se) / PAGE_DURATION_S * (gR - gL);
      float sNormR = (eventNormRms != null) ? eventNormRms[se.rowIndex] : 1.0;
      float sMaxH  = maxEnvH * sNormR;
      noFill();
      stroke(255, 200, 50, 230); strokeWeight(2);
      rect(sx - 5, gB - sMaxH - 5, sEnvW + 10, sMaxH + 10, 5);
      noStroke();
    }
  }

  // Hover highlight spanning the full envelope width on the cluster row.
  if (hoverEventIdx >= 0 && hoverEventIdx < events.size()) {
    Event he = events.get(hoverEventIdx);
    if (he.t >= pageStart && he.t < pageEnd) {
      float hx      = eventX(he, pageStart);
      float hEnvW   = eventEnvLen(he) / PAGE_DURATION_S * (gR - gL);
      float hNormR  = (eventNormRms != null) ? eventNormRms[he.rowIndex] : 1.0;
      float hMaxH   = maxEnvH * hNormR;
      noFill();
      stroke(255, 255, 255, 200); strokeWeight(2);
      rect(hx - 4, gB - hMaxH - 4, hEnvW + 8, hMaxH + 8, 5);
      noStroke();
    }
  }
}

// --- Stem playback labels ----------------------------------------------------

void drawStemLabels() {
  float lx = gridLeft();
  float ly = 72;
  textSize(13);
  textAlign(LEFT, CENTER);
  for (int i = 0; i < STEM_LABELS.length; i++) {
    boolean active = (i == activeStem);
    boolean exists = stemFiles != null && i < stemFiles.length
                     && (i == 0 || (stemFiles[i].length() > 0
                         && new File(dataPath(stemFiles[i])).exists()));
    if (!exists) continue;
    float bw = textWidth(STEM_LABELS[i]) + 16;
    noStroke();
    fill(active ? color(150, 150, 210, 230) : color(55, 55, 70, 200));
    rect(lx, ly - 11, bw, 22, 5);
    fill(active ? color(240) : color(155));
    text(STEM_LABELS[i], lx + 8, ly);
    lx += bw + 8;
  }
}

// --- Melody panel ------------------------------------------------------------

void drawMelody(float pageStart, float pageEnd, float now) {
  if (melodyNotes == null || melodyNotes.isEmpty()) return;
  float gL = gridLeft(), gR = gridRight();
  float rowH = melodyRowH();

  textAlign(LEFT, CENTER); textSize(14);
  for (int i = 0; i < MELODY_STEMS.length; i++) {
    ArrayList<Note> list = melodyNotes.get(i);
    if (list == null || list.size() < 20) continue;
    float y = melodyRowY(i);
    fill(150); text(MELODY_STEMS[i], 24, y);
    stroke(35); strokeWeight(1); line(gL, y, gR, y);
  }

  for (int i = 0; i < melodyNotes.size(); i++) {
    ArrayList<Note> list = melodyNotes.get(i);
    if (list == null || list.size() < 20) continue;
    int loMidi = stemPitchLo(i);
    int hiMidi = stemPitchHi(i);
    float yCenter = melodyRowY(i);
    float yMin = yCenter - rowH * 0.40;
    float yMax = yCenter + rowH * 0.40;

    for (Note n : list) {
      if (n.endTime < pageStart || n.startTime >= pageEnd) continue;
      float t0 = max(n.startTime, pageStart);
      float t1 = min(n.endTime,   pageEnd);
      float x0 = gL + (t0 - pageStart) / PAGE_DURATION_S * (gR - gL);
      float x1 = gL + (t1 - pageStart) / PAGE_DURATION_S * (gR - gL);
      float w  = max(2, x1 - x0);

      float pitchNorm = constrain((float)(n.midi - loMidi) / max(1, hiMidi - loMidi), 0, 1);
      float yBar = lerp(yMax, yMin, pitchNorm);
      float barH = max(4, rowH * 0.15);

      color c = colorForMidi(n.midi);
      boolean playing = (now >= n.startTime && now < n.endTime);
      float intensity = playing ? 1.0 : 0.55;
      float alphaMul  = 0.45 + 0.55 * constrain(n.confidence, 0, 1);

      noStroke();
      fill(red(c) * intensity, green(c) * intensity, blue(c) * intensity, 255 * alphaMul);
      rect(x0, yBar - barH / 2, w, barH, 2);

      if (playing) {
        noFill();
        stroke(red(c), green(c), blue(c), 220); strokeWeight(1.5);
        rect(x0 - 2, yBar - barH / 2 - 2, w + 4, barH + 4, 3);
        if (w > 28) {
          noStroke(); fill(20, 20, 28, 220);
          textAlign(CENTER, CENTER); textSize(11);
          text(n.name, x0 + w / 2, yBar);
          textAlign(LEFT, CENTER);
        }
      }
    }
  }
  noStroke();

  if (now >= pageStart && now < pageEnd) {
    float playX = pagePlayheadX(now, pageStart);
    stroke(255, 200, 50, 160); strokeWeight(2);
    line(playX, melodyTop() - 4, playX, melodyBottom() + 4);
    noStroke();
  }
}

// --- Metronome grid panel ----------------------------------------------------

void drawMetro(float pageStart, float pageEnd, float now) {
  float gL = gridLeft(), gR = gridRight();
  float rowH = metroRowH();

  textAlign(LEFT, CENTER); textSize(14);
  for (int i = 0; i < DIVISIONS.length; i++) {
    float y = metroRowY(i);
    fill(150); text("1/" + DIVISIONS[i], 24, y);
    stroke(35); strokeWeight(1); line(gL, y, gR, y);
  }

  for (GridTick g : gridTicks) {
    if (g.t < pageStart || g.t >= pageEnd) continue;
    int row = divisionRow(g.division);
    float x = gL + (g.t - pageStart) / PAGE_DURATION_S * (gR - gL);
    float y = metroRowY(row);
    color c = divisionColors[row];
    boolean onBeat = (g.phase == 0);
    float baseH = rowH * (onBeat ? METRO_BEAT_H_FRAC : METRO_SUB_H_FRAC);

    float age   = now - g.t;
    float flash = (age >= METRO_FLASH_LEAD_S && age < METRO_FLASH_HOLD_S)
                  ? constrain(1 - age / METRO_FLASH_HOLD_S, 0, 1) : 0;

    stroke(red(c) * 0.55, green(c) * 0.55, blue(c) * 0.55, onBeat ? 200 : 110);
    strokeWeight(onBeat ? 2 : 1);
    line(x, y - baseH, x, y + baseH);

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

  if (now >= pageStart && now < pageEnd) {
    float playX = pagePlayheadX(now, pageStart);
    stroke(255, 200, 50, 160); strokeWeight(2);
    line(playX, metroTop() - 6, playX, metroBottom() + 6);
    noStroke();
  }
}

// --- Drag overlay ------------------------------------------------------------

void drawDragOverlay(float pageStart, float pageEnd) {
  if (dragEventIdx < 0) return;
  Event e = events.get(dragEventIdx);
  if (e.t < pageStart || e.t >= pageEnd) return;
  float gB   = gridBottom();
  float gT   = gridTop();
  float gL   = gridLeft(), gR = gridRight();
  float ex   = eventX(e, pageStart);
  float envW = eventEnvLen(e) / PAGE_DURATION_S * (gR - gL);
  float normR = (eventNormRms != null) ? eventNormRms[e.rowIndex] : 1.0;
  float maxH  = (gB - gT) * 0.90 * normR;
  noFill();
  stroke(255, 230, 80); strokeWeight(2);
  rect(ex - 4, gB - maxH - 4, envW + 8, maxH + 8, 7);
  noStroke();
}

// --- Waveform thumbnail ------------------------------------------------------

void drawWaveform(float now, float pageStart, float pageEnd) {
  float wLeft   = 40;
  float wTop    = height - 160;
  float wW      = panelLeft() - 60;   // buffer was built to this exact width
  float wH      = 110;
  float wBottom = wTop + wH;

  image(waveformBuffer, wLeft, wTop);

  noStroke();
  float pageX0 = wLeft + constrain(pageStart, 0, trackDuration) / trackDuration * wW;
  float pageX1 = wLeft + constrain(pageEnd,   0, trackDuration) / trackDuration * wW;
  fill(255, 200, 50, 55);
  rect(pageX0, wTop, max(2, pageX1 - pageX0), wH);

  float playX = wLeft + constrain(now, 0, trackDuration) / trackDuration * wW;
  stroke(255, 200, 50); strokeWeight(2);
  line(playX, wTop - 6, playX, wBottom + 6);
  noStroke();
}

// --- HUD ---------------------------------------------------------------------

void drawHUD(float now, int page, int eventsThisPage) {
  fill(200);
  textAlign(LEFT, TOP); textSize(14);
  String rateStr = (playbackRate != 1.0) ? "  [" + nf(playbackRate, 1, 2) + "x]" : "";
  String state   = (sound.isPlaying() ? "" : "  [PAUSED]") + rateStr + (loopEnabled ? "  [LOOP]" : "");

  int segIdx = currentSegmentIndex(now);
  String segLabel = "";
  if (segIdx >= 0) {
    Segment s = segments.get(segIdx);
    color c = segmentColors[constrain(s.label, 0, N_SEGMENT_LABELS - 1)];
    fill(red(c), green(c), blue(c));
    segLabel = "   segment " + (segIdx + 1) + "/" + segments.size() +
               " (label " + s.label + ")";
  }
  text(
    nf(now, 1, 2) + "s / " + nf(trackDuration, 1, 2) + "s   " +
    "page " + page + "   events on page: " + eventsThisPage + "   " +
    "disabled: " + disabledCount + segLabel + state,
    24, 24
  );
  fill(200);

  float hintR = panelLeft() - 20;
  textAlign(RIGHT, TOP);
  String snapHint = gridSnapEnabled ? "snap:on" : "snap:off";
  text("space play/pause   ← → page   r start   q " + snapHint +
       "   -/= speed   l loop   m midi   ctrl/cmd+s save", hintR, 24);

  boolean midiOk = (midiOut != null && midiOut.isOpen());
  String midiStatus = midiOk
    ? ("MIDI → " + midiOut.portName() + (midiEnabled ? "" : "  (muted)"))
    : "MIDI: off (port not found)";
  fill(midiOk && midiEnabled ? color(120, 220, 140) : color(210, 160, 80));
  text(midiStatus, hintR, 44);
  fill(200);

  if (dragEventIdx >= 0) {
    Event e = events.get(dragEventIdx);
    int bi = e.bucketIdx[dragRow];
    String fromVal = rowValues[dragRow][dragStartBucket];
    String toVal   = (bi >= 0 ? rowValues[dragRow][bi] : "?");
    fill(255, 230, 80); textAlign(LEFT, TOP);
    text("editing event " + dragEventIdx + " — " + rowNames[dragRow] +
         ": " + fromVal + " → " + toVal, 24, 50);
  } else if (hoverEventIdx >= 0 && hoverEventIdx < events.size()) {
    Event e = events.get(hoverEventIdx);
    int clusterRow = csvCols.length - 1;
    int cur = e.bucketIdx[clusterRow];
    String curLabel = (cur >= 0 && cur < rowValues[clusterRow].length)
      ? rowValues[clusterRow][cur] : "?";
    fill(200, 200, 255); textAlign(LEFT, TOP);
    text("event " + hoverEventIdx + "   cluster: " + curLabel +
         "   press 0-" + (activeK - 1) + " to reassign", 24, 50);
  }

  if (savedNoticeUntil > millis()) {
    fill(120, 220, 140); textAlign(LEFT, TOP);
    text(savedNotice, 24, 50);
  }

  textAlign(LEFT, CENTER);
}
