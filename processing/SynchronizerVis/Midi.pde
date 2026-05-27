// Midi.pde — MIDI output via javax.sound.midi (MidiOut helper in MidiOut.java).
// Sends per-cluster ADSR envelopes as 7-bit CC values on every draw frame.

void initMidi() {
  midiOut = new MidiOut(MIDI_PORT_NAME);
}

void sendCC(int cc, int val) {
  if (midiOut != null) midiOut.sendCC(MIDI_CHANNEL, cc, val);
}

void closeMidi() {
  if (midiOut != null) { midiOut.close(); midiOut = null; }
}

// Called by Processing when the sketch closes.
void dispose() {
  if (midiOut != null && midiOut.isOpen())
    for (int c = 0; c < N_TRANSIENT_CLUSTERS; c++) sendCC(BASE_CC + c, 0);
  closeMidi();
  super.dispose();
}

// Stateless per-frame envelope → CC send. Deriving purely from `now` means
// pause (frozen time → values hold), seek, and rate changes are all handled
// automatically without extra state. Polyphony across same-cluster events is
// resolved by taking the max envelope value. Dedup: only transmit on change.
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
      if (c < 0 || c >= nc || c >= activeK) continue;
      float v = envValue(c, p) * eventNormRms[e.rowIndex];
      if (v > ccVal[c]) ccVal[c] = v;
    }
  }

  for (int c = 0; c < nc; c++) {
    int q = (midiEnabled && c < activeK) ? constrain(round(ccVal[c] * 127), 0, 127) : 0;
    if (q != lastSent[c]) {
      sendCC(BASE_CC + c, q);
      lastSent[c] = q;
    }
  }
}
