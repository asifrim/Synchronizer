// AdsrPanel.pde — ADSR envelope model, right-panel drawing, and slider interaction.

// --- Envelope model ----------------------------------------------------------

void initAdsr() {
  int n = N_TRANSIENT_CLUSTERS;
  attackFrac   = new float[n];
  decayFrac    = new float[n];
  sustainLevel = new float[n];
  releaseFrac  = new float[n];
  attackExp    = new boolean[n];
  decayExp     = new boolean[n];
  ccVal        = new float[n];
  lastSent     = new int[n];
  for (int i = 0; i < n; i++) {
    // Defaults vary by cluster so clusters start audibly distinct.
    attackFrac[i]   = 0.04 + 0.04 * (i % 3);
    decayFrac[i]    = 0.18;
    sustainLevel[i] = 0.65 - 0.10 * (i % 3);
    releaseFrac[i]  = 0.25 + 0.05 * (i % 3);
    attackExp[i]    = false;
    decayExp[i]     = false;
    clampAdsr(i);
    ccVal[i]    = 0;
    lastSent[i] = -1;  // force first send
  }
  loadAdsr();
}

void clampAdsr(int c) {
  attackFrac[c]   = constrain(attackFrac[c],   0, 1);
  decayFrac[c]    = constrain(decayFrac[c],    0, 1 - attackFrac[c]);
  releaseFrac[c]  = constrain(releaseFrac[c],  0, 1 - attackFrac[c] - decayFrac[c]);
  sustainLevel[c] = constrain(sustainLevel[c], 0, 1);
}

String adsrFileName() {
  return CSV_FILE.replaceAll("\\.csv$", "") + "_adsr.csv";
}

void loadAdsr() {
  File f = new File(dataPath(adsrFileName()));
  if (!f.exists()) return;
  Table t = loadTable(adsrFileName(), "header");
  // Gracefully handle files written before the attackExp/decayExp columns existed.
  boolean hasExp = false;
  for (int i = 0; i < t.getColumnCount(); i++)
    if (t.getColumnTitle(i).equals("attack_exp")) { hasExp = true; break; }
  for (TableRow r : t.rows()) {
    int c = r.getInt("cluster");
    if (c < 0 || c >= N_TRANSIENT_CLUSTERS) continue;
    attackFrac[c]   = r.getFloat("attack");
    decayFrac[c]    = r.getFloat("decay");
    sustainLevel[c] = r.getFloat("sustain");
    releaseFrac[c]  = r.getFloat("release");
    if (hasExp) {
      attackExp[c] = r.getInt("attack_exp") != 0;
      decayExp[c]  = r.getInt("decay_exp")  != 0;
    }
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
  out.addColumn("attack_exp");
  out.addColumn("decay_exp");
  for (int c = 0; c < N_TRANSIENT_CLUSTERS; c++) {
    TableRow row = out.addRow();
    row.setInt("cluster",    c);
    row.setFloat("attack",   attackFrac[c]);
    row.setFloat("decay",    decayFrac[c]);
    row.setFloat("sustain",  sustainLevel[c]);
    row.setFloat("release",  releaseFrac[c]);
    row.setInt("attack_exp", attackExp[c] ? 1 : 0);
    row.setInt("decay_exp",  decayExp[c]  ? 1 : 0);
  }
  saveTable(out, dataPath(adsrFileName()));
  savedNotice      = "saved " + adsrFileName();
  savedNoticeUntil = millis() + 2000;
  println(savedNotice);
}

// Envelope value at normalised phase p ∈ [0, 1).
//
// Attack  linear  → straight ramp 0 → 1
// Attack  exp     → t² (slow start, snappy peak — typical for percussive hits)
//
// Decay   linear  → straight ramp 1 → S
// Decay   exp     → (1-t)² (fast initial drop, slow approach to sustain —
//                  natural capacitor-discharge feel)
//
// Release is always linear (S → 0).
float envValue(int c, float p) {
  if (p < 0 || p >= 1) return 0;
  float aF = attackFrac[c], dF = decayFrac[c], rF = releaseFrac[c], S = sustainLevel[c];
  float relStart = 1 - rF;
  if (p < aF) {
    float t = aF > 0 ? p / aF : 1.0;
    return attackExp[c] ? t * t : t;
  } else if (p < aF + dF) {
    float t = dF > 0 ? (p - aF) / dF : 1.0;
    if (decayExp[c]) { float inv = 1.0 - t; return S + (1.0 - S) * inv * inv; }
    return 1.0 - (1.0 - S) * t;
  } else if (p < relStart) {
    return S;
  } else {
    float t = rF > 0 ? (p - relStart) / rF : 1.0;
    return S * (1.0 - t);
  }
}

// --- Right-panel drawing -----------------------------------------------------

void drawKSelector() {
  float pL   = panelLeft();
  float pW   = panelW();
  float ky   = panelKSelectorY();
  int   nk   = MULTI_K_MAX_FIXED - MULTI_K_MIN + 1;
  float btnW = (pW - 20.0) / nk;

  for (int k = MULTI_K_MIN; k <= MULTI_K_MAX_FIXED; k++) {
    float x      = pL + 10 + (k - MULTI_K_MIN) * btnW;
    boolean act  = (k == activeK);
    noStroke();
    if (act) {
      color col = palettes[0][constrain(k - MULTI_K_MIN, 0, N_TRANSIENT_CLUSTERS - 1)];
      fill(red(col) * 0.45, green(col) * 0.45, blue(col) * 0.45);
    } else {
      fill(30);
    }
    rect(x, ky - 9, btnW - 3, 18, 3);
    textAlign(CENTER, CENTER); textSize(11);
    fill(act ? color(230) : color(75));
    text(str(k), x + (btnW - 3) * 0.5, ky);
  }
}

void drawAdsrPanel(float now) {
  float pL = panelLeft();
  float pW = panelW();

  noStroke(); fill(14, 16, 24);
  rect(pL, 0, pW, height);
  stroke(42); strokeWeight(1);
  line(pL, 0, pL, height);
  noStroke();

  fill(80); textAlign(LEFT, TOP); textSize(10);
  text("k =", pL + 8, 8);
  drawKSelector();

  for (int c = 0; c < N_TRANSIENT_CLUSTERS; c++) {
    drawPanelCluster(c, now);
    if (c < N_TRANSIENT_CLUSTERS - 1) {
      stroke(30); strokeWeight(1);
      line(pL + 6, panelClusterY(c + 1) - 3, pL + pW - 6, panelClusterY(c + 1) - 3);
      noStroke();
    }
  }
}

void drawPanelCluster(int c, float now) {
  boolean inactive = (c >= activeK);
  float pL  = panelLeft();
  float cy  = panelClusterY(c);
  color col = inactive ? color(45) : palettes[0][c];

  // Cluster header strip.
  noStroke();
  fill(inactive ? 20 : red(col) * 0.20, inactive ? 20 : green(col) * 0.20, inactive ? 20 : blue(col) * 0.20);
  rect(pL + 4, cy + 2, panelW() - 8, 17, 3);
  fill(inactive ? 55 : col);
  textAlign(LEFT, CENTER); textSize(10);
  text("cluster " + c + "  CC " + (BASE_CC + c), pL + 10, cy + 10);

  drawPanelEnvCurve(c, now);
  drawPanelSlider(c, 0, "A", attackFrac[c]);
  drawPanelSlider(c, 1, "D", decayFrac[c]);
  drawPanelSlider(c, 2, "S", sustainLevel[c]);
  drawPanelSlider(c, 3, "R", releaseFrac[c]);
  drawPanelMeter(c);

  // Grey-out overlay for clusters outside the active k range.
  if (inactive) {
    noStroke();
    fill(14, 16, 24, 170);
    rect(pL + 2, cy + 1, panelW() - 4, panelClusterH() - 2, 2);
  }
}

void drawPanelEnvCurve(int c, float now) {
  float pL  = panelLeft();
  float cL  = pL + 6;
  float cR  = pL + panelW() - 6;
  float cT  = panelCurveT(c);
  float cB  = panelCurveB(c);
  color col = palettes[0][c];

  noStroke(); fill(9, 11, 18);
  rect(cL, cT, cR - cL, cB - cT, 3);

  // Midline and sustain-level gridlines.
  stroke(28); strokeWeight(1);
  line(cL + 2, (cT + cB) * 0.5, cR - 2, (cT + cB) * 0.5);
  stroke(38);
  float sY = map(sustainLevel[c], 0, 1, cB, cT);
  line(cL + 2, sY, cR - 2, sY);

  // Phase boundary markers.
  float xA = map(attackFrac[c],                0, 1, cL, cR);
  float xD = map(attackFrac[c] + decayFrac[c], 0, 1, cL, cR);
  float xR = map(1 - releaseFrac[c],           0, 1, cL, cR);
  stroke(35); strokeWeight(1);
  line(xA, cT + 2, xA, cB - 2);
  line(xD, cT + 2, xD, cB - 2);
  line(xR, cT + 2, xR, cB - 2);

  // Fill under curve.
  noStroke();
  fill(red(col) * 0.15, green(col) * 0.15, blue(col) * 0.15);
  beginShape();
  vertex(cL, cB);
  for (int i = 0; i <= 200; i++) {
    float p = (i / 200.0) * 0.9999;
    vertex(map(p, 0, 1, cL, cR), map(envValue(c, p), 0, 1, cB, cT));
  }
  vertex(cR, cB);
  endShape(CLOSE);

  // Curve line.
  stroke(red(col), green(col), blue(col), 220); strokeWeight(2); noFill();
  beginShape();
  for (int i = 0; i <= 200; i++) {
    float p = (i / 200.0) * 0.9999;
    vertex(map(p, 0, 1, cL, cR), map(envValue(c, p), 0, 1, cB, cT));
  }
  endShape();

  // Live playhead dot — loudest active transient for this cluster.
  int clusterRow = csvCols.length - 1;
  float maxPhase = -1;
  for (Event e : events) {
    if (e.disabled || e.bucketIdx[clusterRow] != c) continue;
    float envLen = max(e.dur, MIN_ENV_S);
    float p = (now - e.origT) / envLen;
    if (p >= 0 && p < 1 && p > maxPhase) maxPhase = p;
  }
  if (maxPhase >= 0) {
    float px = map(maxPhase, 0, 1, cL, cR);
    float py = map(envValue(c, maxPhase), 0, 1, cB, cT);
    stroke(255, 255, 180, 60); strokeWeight(1);
    line(px, cT + 2, px, cB - 2);
    noStroke(); fill(255, 255, 200, 210);
    ellipse(px, py, 7, 7);
  }

  // Frame.
  noFill(); stroke(46); strokeWeight(1);
  rect(cL, cT, cR - cL, cB - cT, 3);

  // Phase labels above the curve.
  fill(80); textSize(10); textAlign(CENTER, BOTTOM);
  text("A", (cL + xA) * 0.5, cT - 1);
  text("D", (xA + xD) * 0.5, cT - 1);
  if (xR - xD > 12) text("S", (xD + xR) * 0.5, cT - 1);
  text("R", (xR + cR) * 0.5, cT - 1);
  noStroke();
}

void drawPanelSlider(int c, int param, String label, float value) {
  float trackY = panelSliderY(c, param);
  float tL = slTrackL(), tR = slTrackR();
  float hX = slValX(value);
  float tH = 4, hR = 7;
  color col = palettes[0][c];

  fill(160); textAlign(RIGHT, CENTER); textSize(11);
  text(label + " " + nf(value, 1, 2), panelLeft() + 58, trackY);

  noStroke(); fill(32);
  rect(tL, trackY - tH * 0.5, tR - tL, tH, 2);

  fill(red(col) * 0.55, green(col) * 0.55, blue(col) * 0.55);
  rect(tL, trackY - tH * 0.5, max(0, hX - tL), tH, 2);

  boolean active = (sliderDragCluster == c && sliderDragParam == param);
  noStroke();
  fill(active ? color(255) : color(195, 205, 225));
  ellipse(hX, trackY, hR * 2, hR * 2);
  fill(active ? color(60) : color(40));
  ellipse(hX, trackY, hR * 0.8, hR * 0.8);
}


void drawPanelMeter(int c) {
  float pL  = panelLeft();
  float my  = panelMeterY(c);
  float mH  = 18;
  float mL  = pL + 8;
  float mW  = panelW() - 16;
  color col = palettes[0][c];
  float v   = constrain(ccVal[c], 0, 1);

  noStroke(); fill(18);
  rect(mL, my - mH * 0.5, mW, mH, 3);
  fill(red(col) * 0.5, green(col) * 0.5, blue(col) * 0.5, midiEnabled ? 200 : 70);
  rect(mL, my - mH * 0.5, mW * v, mH, 3);
  noFill(); stroke(46); strokeWeight(1);
  rect(mL, my - mH * 0.5, mW, mH, 3);

  int q = constrain(round(v * 127), 0, 127);
  fill(midiEnabled ? color(200) : color(110));
  textAlign(LEFT, CENTER); textSize(10);
  text("CC " + (BASE_CC + c) + "  " + q, mL + 6, my);
  noStroke();
}

// --- Panel mouse interaction -------------------------------------------------

void panelMousePressed() {
  float mx = mouseX, my = mouseY;

  // K-selector: hit zone ±10px from strip centre Y.
  float ky = panelKSelectorY();
  if (abs(my - ky) <= 10) {
    float pL   = panelLeft();
    float pW   = panelW();
    int   nk   = MULTI_K_MAX_FIXED - MULTI_K_MIN + 1;
    float btnW = (pW - 20.0) / nk;
    for (int k = MULTI_K_MIN; k <= MULTI_K_MAX_FIXED; k++) {
      float x = pL + 10 + (k - MULTI_K_MIN) * btnW;
      if (mx >= x && mx < x + btnW - 3) { switchK(k); return; }
    }
  }

  // Sliders: hit zone ±8px from centre Y.
  for (int c = 0; c < N_TRANSIENT_CLUSTERS; c++) {
    for (int p = 0; p < 4; p++) {
      float sy = panelSliderY(c, p);
      if (abs(my - sy) <= 8 && mx >= slTrackL() - 10 && mx <= slTrackR() + 10) {
        sliderDragCluster = c;
        sliderDragParam   = p;
        applySliderDrag(c, p, mx);
        return;
      }
    }
  }
}

void panelMouseDragged() {
  applySliderDrag(sliderDragCluster, sliderDragParam, mouseX);
}

void applySliderDrag(int c, int p, float mx) {
  float v = slXtoVal(mx);
  if      (p == 0) attackFrac[c]   = v;
  else if (p == 1) decayFrac[c]    = v;
  else if (p == 2) sustainLevel[c] = v;
  else             releaseFrac[c]  = v;
  clampAdsr(c);
  // Invalidate lastSent so the new envelope shape is pushed to MIDI immediately.
  for (int i = 0; i < N_TRANSIENT_CLUSTERS; i++) lastSent[i] = -1;
}
