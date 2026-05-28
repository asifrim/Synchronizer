// AdsrPanel.pde — AD envelope model, right-panel drawing, and knob interaction.
//
// Each cluster has an Attack-Decay envelope (no Sustain or Release).
// Controls per cluster:
//   LEFT:   envelope curve preview (full cluster height)
//   RIGHT:  row 1 — A and D rotary knobs
//           row 2 — LIN/EXP shape toggles for A and D
//   BOTTOM: CC level meter (full width)

// --- Envelope model ----------------------------------------------------------

void initAdsr() {
  int n = N_TRANSIENT_CLUSTERS;
  attackFrac     = new float[n];
  decayFrac      = new float[n];
  attackExp      = new boolean[n];
  decayExp       = new boolean[n];
  ccVal          = new float[n];
  lastSent       = new int[n];
  envCurveCache  = new float[n][N_ENV_SAMPLES + 1];
  for (int i = 0; i < n; i++) {
    attackFrac[i] = 0.08 + 0.04 * (i % 4);
    decayFrac[i]  = 0.70 - 0.05 * (i % 4);
    attackExp[i]  = false;
    decayExp[i]   = false;
    clampAdsr(i);
    ccVal[i]    = 0;
    lastSent[i] = -1;
  }
  loadAdsr();
  for (int i = 0; i < n; i++) rebuildEnvCache(i);
}

// Sample envValue at N_ENV_SAMPLES+1 points; called whenever a cluster's
// A/D/exp parameters change.
void rebuildEnvCache(int c) {
  for (int s = 0; s <= N_ENV_SAMPLES; s++) {
    float p = (float)s / N_ENV_SAMPLES;
    envCurveCache[c][s] = envValue(c, p);
  }
}

void clampAdsr(int c) {
  attackFrac[c] = constrain(attackFrac[c], 0.01, 0.99);
  decayFrac[c]  = constrain(decayFrac[c],  0.01, 1.0 - attackFrac[c]);
}

String adsrFileName() {
  return TRACK + "/adsr.csv";
}

void loadAdsr() {
  File f = new File(dataPath(adsrFileName()));
  if (!f.exists()) return;
  Table t = loadTable(adsrFileName(), "header");
  boolean hasDecay = false, hasExp = false;
  for (int i = 0; i < t.getColumnCount(); i++) {
    String col = t.getColumnTitle(i);
    if (col.equals("decay"))      hasDecay = true;
    if (col.equals("attack_exp")) hasExp   = true;
  }
  for (TableRow r : t.rows()) {
    int c = r.getInt("cluster");
    if (c < 0 || c >= N_TRANSIENT_CLUSTERS) continue;
    attackFrac[c] = r.getFloat("attack");
    if (hasDecay) decayFrac[c] = r.getFloat("decay");
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
  out.addColumn("attack_exp");
  out.addColumn("decay_exp");
  for (int c = 0; c < N_TRANSIENT_CLUSTERS; c++) {
    TableRow row = out.addRow();
    row.setInt("cluster",    c);
    row.setFloat("attack",   attackFrac[c]);
    row.setFloat("decay",    decayFrac[c]);
    row.setInt("attack_exp", attackExp[c] ? 1 : 0);
    row.setInt("decay_exp",  decayExp[c]  ? 1 : 0);
  }
  saveTable(out, dataPath(adsrFileName()));
  savedNotice      = "saved " + adsrFileName();
  savedNoticeUntil = millis() + 2000;
  println(savedNotice);
}

// AD envelope value at normalised phase p ∈ [0, 1).
//
// Attack ramp  linear → 0→1 straight
//              exp    → t²  (slow start, snappy peak)
// Decay ramp   linear → 1→0 straight
//              exp    → (1-t)²  (fast initial drop, slow tail)
// Silence for any remaining fraction after A+D.
float envValue(int c, float p) {
  if (p < 0 || p >= 1) return 0;
  float aF = attackFrac[c];
  float dF = decayFrac[c];
  if (p < aF) {
    float t = aF > 0 ? p / aF : 1.0;
    return attackExp[c] ? t * t : t;
  } else if (p < aF + dF) {
    float t = dF > 0 ? (p - aF) / dF : 1.0;
    float inv = 1.0 - t;
    return decayExp[c] ? inv * inv : inv;
  }
  return 0;
}

// --- Right-panel drawing -----------------------------------------------------

void drawKSelector() {
  float pL   = panelLeft();
  float pW   = panelW();
  float ky   = panelKSelectorY();
  int   nk   = MULTI_K_MAX_FIXED - MULTI_K_MIN + 1;
  float btnW = (pW - 20.0) / nk;

  for (int k = MULTI_K_MIN; k <= MULTI_K_MAX_FIXED; k++) {
    float x     = pL + 10 + (k - MULTI_K_MIN) * btnW;
    boolean act = (k == activeK);
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

  // RMS-scale toggle — top-right corner of the panel header.
  float bx = pL + pW - 58; float by = 8; float bW = 52; float bH = 16;
  noStroke();
  fill(midiEnergyScale ? color(55, 80, 55) : 30);
  rect(bx, by - bH * 0.5, bW, bH, 3);
  textAlign(CENTER, CENTER); textSize(10);
  fill(midiEnergyScale ? color(160, 230, 160) : color(75));
  text("RMS scale", bx + bW * 0.5, by);

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

  // Header strip.
  noStroke();
  fill(inactive ? 20 : red(col) * 0.20, inactive ? 20 : green(col) * 0.20, inactive ? 20 : blue(col) * 0.20);
  rect(pL + 4, cy + 2, panelW() - 8, 17, 3);
  fill(inactive ? 55 : col);
  textAlign(LEFT, CENTER); textSize(10);
  text("cluster " + c + "  CC " + (BASE_CC + c), pL + 10, cy + 10);

  drawPanelEnvCurve(c, now);
  drawKnob(c, 0, "A", attackFrac[c]);
  drawKnob(c, 1, "D", decayFrac[c]);
  drawShapeToggle(c, 0, attackExp[c]);
  drawShapeToggle(c, 1, decayExp[c]);
  drawPanelMeter(c);

  // Grey-out overlay for clusters outside the active k range.
  if (inactive) {
    noStroke();
    fill(14, 16, 24, 170);
    rect(pL + 2, cy + 1, panelW() - 4, panelClusterH() - 2, 2);
  }
}

void drawPanelEnvCurve(int c, float now) {
  float cL  = panelCurveL();
  float cR  = panelCurveR();
  float cT  = panelCurveT(c);
  float cB  = panelCurveB(c);
  color col = palettes[0][c];

  noStroke(); fill(9, 11, 18);
  rect(cL, cT, cR - cL, cB - cT, 3);

  // A/D phase boundary.
  float xA = map(attackFrac[c], 0, 1, cL, cR);
  stroke(35); strokeWeight(1);
  line(xA, cT + 2, xA, cB - 2);

  // Fill under curve.
  noStroke();
  fill(red(col) * 0.15, green(col) * 0.15, blue(col) * 0.15);
  beginShape();
  vertex(cL, cB);
  for (int i = 0; i <= N_ENV_SAMPLES; i++) {
    float p = (float)i / N_ENV_SAMPLES;
    vertex(map(p, 0, 1, cL, cR), map(envCurveCache[c][i], 0, 1, cB, cT));
  }
  vertex(cR, cB);
  endShape(CLOSE);

  // Curve line.
  stroke(red(col), green(col), blue(col), 220); strokeWeight(1.5); noFill();
  beginShape();
  for (int i = 0; i <= N_ENV_SAMPLES; i++) {
    float p = (float)i / N_ENV_SAMPLES;
    vertex(map(p, 0, 1, cL, cR), map(envCurveCache[c][i], 0, 1, cB, cT));
  }
  endShape();

  // Phase labels.
  fill(65); textSize(9); textAlign(CENTER, BOTTOM); noStroke();
  text("A", (cL + xA) * 0.5, cT);
  text("D", (xA + cR) * 0.5, cT);

  // Live playhead dot.
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
    stroke(255, 255, 180, 55); strokeWeight(1);
    line(px, cT + 2, px, cB - 2);
    noStroke(); fill(255, 255, 200, 210);
    ellipse(px, py, 6, 6);
  }

  // Frame.
  noFill(); stroke(46); strokeWeight(1);
  rect(cL, cT, cR - cL, cB - cT, 3);
}

// Draw a rotary knob. param: 0=A 1=D. Vertical drag to change value.
void drawKnob(int c, int param, String label, float value) {
  float cx  = panelKnobCX(param);
  float cy  = panelKnobCY(c);
  float r   = KNOB_RADIUS;
  color col = palettes[0][c];
  boolean active = (knobDragCluster == c && knobDragParam == param);

  // Arc sweep: 135° (7 o'clock) clockwise 270° to 45° (5 o'clock)
  float arcStart = radians(135);
  float arcSweep = radians(270);

  // Background track.
  noFill(); stroke(38); strokeWeight(2.5);
  arc(cx, cy, r * 2, r * 2, arcStart, arcStart + arcSweep, OPEN);

  // Value arc.
  if (value > 0.005) {
    stroke(active ? color(255) : col); strokeWeight(2.5);
    arc(cx, cy, r * 2, r * 2, arcStart, arcStart + value * arcSweep, OPEN);
  }

  // Indicator dot at current value position.
  float angle = arcStart + value * arcSweep;
  float dx = cos(angle) * (r - 4);
  float dy = sin(angle) * (r - 4);
  noStroke();
  fill(active ? color(255) : color(220, 225, 240));
  ellipse(cx + dx, cy + dy, 5, 5);

  // Centre cap.
  fill(22); ellipse(cx, cy, r * 0.7, r * 0.7);

  // Label + value below.
  fill(active ? color(210) : color(100));
  textAlign(CENTER, TOP); textSize(9);
  text(label + " " + nf(value, 1, 2), cx, cy + r + 3);
}

// Draw a single LIN/EXP shape toggle below the knob. Click to cycle.
void drawShapeToggle(int c, int param, boolean isExp) {
  float cx  = panelKnobCX(param);
  float cy  = panelToggleCY(c);
  color col = palettes[0][c];
  float bW  = 38, bH = 13;

  noStroke();
  fill(isExp ? color(red(col)*0.45, green(col)*0.45, blue(col)*0.45) : 32);
  rect(cx - bW * 0.5, cy - bH * 0.5, bW, bH, 3);
  textAlign(CENTER, CENTER); textSize(9);
  fill(isExp ? col : color(80));
  text(isExp ? "EXP" : "LIN", cx, cy);
}

void drawPanelMeter(int c) {
  float pL  = panelLeft();
  float my  = panelMeterY(c);
  float mH  = 8;
  float mL  = pL + 8;
  float mW  = panelW() - 16;
  color col = palettes[0][c];
  float v   = constrain(ccVal[c], 0, 1);

  noStroke(); fill(18);
  rect(mL, my - mH * 0.5, mW, mH, 2);
  fill(red(col) * 0.5, green(col) * 0.5, blue(col) * 0.5, midiEnabled ? 200 : 70);
  rect(mL, my - mH * 0.5, mW * v, mH, 2);
  noFill(); stroke(38); strokeWeight(1);
  rect(mL, my - mH * 0.5, mW, mH, 2);
  noStroke();
}

// --- Panel mouse interaction -------------------------------------------------

void panelMousePressed() {
  float mx = mouseX, my = mouseY;

  // RMS-scale toggle.
  float bx = panelLeft() + panelW() - 58; float by = 8; float bW = 52; float bH = 16;
  if (abs(my - by) <= bH * 0.5 + 2 && mx >= bx && mx <= bx + bW) {
    midiEnergyScale = !midiEnergyScale;
    return;
  }

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

  // Knobs and toggles per cluster.
  for (int c = 0; c < N_TRANSIENT_CLUSTERS; c++) {
    float kcy = panelKnobCY(c);
    float tcy = panelToggleCY(c);

    // Rotary knobs — hit zone: circle of radius KNOB_RADIUS + 6.
    for (int param = 0; param < 2; param++) {
      float kcx = panelKnobCX(param);
      if (dist(mx, my, kcx, kcy) <= KNOB_RADIUS + 6) {
        knobDragCluster    = c;
        knobDragParam      = param;
        knobDragStartY     = my;
        knobDragStartValue = (param == 0) ? attackFrac[c] : decayFrac[c];
        return;
      }
    }

    // Shape toggles — hit zone: ±10px vertically, ±22px horizontally.
    for (int param = 0; param < 2; param++) {
      float tcx = panelKnobCX(param);
      if (abs(my - tcy) <= 10 && abs(mx - tcx) <= 22) {
        if (param == 0) attackExp[c] = !attackExp[c];
        else            decayExp[c]  = !decayExp[c];
        rebuildEnvCache(c);
        for (int i = 0; i < N_TRANSIENT_CLUSTERS; i++) lastSent[i] = -1;
        saveAdsr();
        return;
      }
    }
  }
}

void panelMouseDragged() {
  if (knobDragCluster < 0) return;
  // Drag up = increase, down = decrease. 180px = full 0→1 range.
  float delta = (knobDragStartY - mouseY) / 180.0;
  float v = knobDragStartValue + delta;
  if (knobDragParam == 0) attackFrac[knobDragCluster] = v;
  else                    decayFrac[knobDragCluster]  = v;
  clampAdsr(knobDragCluster);
  rebuildEnvCache(knobDragCluster);
  for (int i = 0; i < N_TRANSIENT_CLUSTERS; i++) lastSent[i] = -1;
}
