// Midi.pde — MIDI output via javax.sound.midi (MidiOut helper in MidiOut.java).
// Sends per-cluster ADSR envelopes as 7-bit CC values on every draw frame.

void initMidi() {
  clockNoteOn = new boolean[DIVISIONS.length];
  midiOut = new MidiOut(MIDI_PORT_NAME);
}

void sendCC(int cc, int val) {
  if (midiOut != null) midiOut.sendCC(MIDI_CHANNEL, cc, val);
}

void sendNoteOn(int note, int vel) {
  if (midiOut != null) midiOut.sendNoteOn(MIDI_CHANNEL, note, vel);
}

void sendNoteOff(int note) {
  if (midiOut != null) midiOut.sendNoteOff(MIDI_CHANNEL, note);
}

void releaseClockNotes() {
  if (clockNoteOn == null) return;
  for (int di = 0; di < DIVISIONS.length; di++) {
    if (clockNoteOn[di]) {
      sendNoteOff(BASE_CLOCK_NOTE + di);
      clockNoteOn[di] = false;
    }
  }
}

// Emit note-on/off pulses as the playhead crosses metronome ticks.
// Stateless gate: note is "on" while now is within CLOCK_GATE_S of a tick.
// Handles pause (playing=false → gated=false → note-offs) and seek automatically.
void updateClockMidi(float now) {
  if (gridTicks.isEmpty() || clockNoteOn == null) return;
  boolean playing = midiEnabled && sound.isPlaying();

  for (int di = 0; di < DIVISIONS.length; di++) {
    int div  = DIVISIONS[di];
    if (div > 16) continue;  // no clock for 32nd notes and finer
    int note = BASE_CLOCK_NOTE + di;
    boolean gated = false;
    if (playing) {
      for (GridTick g : gridTicks) {
        if (g.division != div) continue;
        float dt = now - g.t;
        if (dt >= 0 && dt < CLOCK_GATE_S) { gated = true; break; }
      }
    }
    if (gated && !clockNoteOn[di]) {
      sendNoteOn(note, 127);
      clockNoteOn[di] = true;
    } else if (!gated && clockNoteOn[di]) {
      sendNoteOff(note);
      clockNoteOn[di] = false;
    }
  }
}

void closeMidi() {
  if (midiOut != null) { midiOut.close(); midiOut = null; }
}

// Called by Processing when the sketch closes.
void dispose() {
  if (midiOut != null && midiOut.isOpen()) {
    for (int c = 0; c < N_TRANSIENT_CLUSTERS; c++) sendCC(BASE_CC + c, 0);
    releaseClockNotes();
  }
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
      int c = e.bucketIdx[clusterRow];
      if (c < 0 || c >= nc || c >= activeK) continue;
      if (!clusterEnabled[c]) continue;
      // Shift the transient's trigger time by the cluster's timing offset.
      // The envelope shape and duration are unchanged; it just fires earlier/later.
      float triggerT = e.origT + clusterOffsetMs[c] / 1000.0;
      float envLen   = eventEnvLen(e);
      float p        = (now - triggerT) / envLen;
      if (p < 0 || p >= 1) continue;
      float v = envValue(c, p) * (midiEnergyScale ? eventNormRms[e.rowIndex] : 1.0);
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
