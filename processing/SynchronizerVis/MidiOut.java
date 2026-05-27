// Plain-Java MIDI output helper, kept in a .java tab so it is compiled directly
// by javac and bypasses the Processing preprocessor — which mis-parses the
// qualified nested type javax.sound.midi.MidiDevice.Info in declaration/for-each
// positions (the "Error on parameter or method declaration" you get if this
// lives in the .pde). Opens a virtual MIDI port by name (loopMIDI on Windows)
// and sends 7-bit Control Change messages.

import javax.sound.midi.InvalidMidiDataException;
import javax.sound.midi.MidiDevice;
import javax.sound.midi.MidiSystem;
import javax.sound.midi.Receiver;
import javax.sound.midi.Sequencer;
import javax.sound.midi.ShortMessage;
import javax.sound.midi.Synthesizer;

public class MidiOut {
  private MidiDevice dev;
  private Receiver rx;
  private String portName = "";

  // Opens the first device whose name contains nameSubstring AND can receive
  // messages (the input/receiver side of the loopback). Skips Java's built-in
  // softsynth/sequencer. Leaves the helper closed (isOpen()==false) if none
  // match — the sketch then runs as a visualizer with MIDI off.
  public MidiOut(String nameSubstring) {
    try {
      MidiDevice.Info[] infos = MidiSystem.getMidiDeviceInfo();
      for (MidiDevice.Info info : infos) {
        if (info.getName().indexOf(nameSubstring) < 0) continue;
        MidiDevice d = MidiSystem.getMidiDevice(info);
        if (d instanceof Sequencer || d instanceof Synthesizer) continue;
        if (d.getMaxReceivers() == 0) continue;  // transmitter side of the loopback
        d.open();
        rx = d.getReceiver();
        dev = d;
        portName = info.getName();
        System.out.println("MIDI -> " + portName);
        return;
      }
      System.out.println("MIDI: no port containing \"" + nameSubstring + "\". Available ports:");
      for (MidiDevice.Info info : infos) System.out.println("  - " + info.getName());
    } catch (Exception ex) {
      System.out.println("MIDI init failed: " + ex.getMessage());
      rx = null;
      dev = null;
    }
  }

  public boolean isOpen()    { return rx != null; }
  public String  portName()  { return portName; }

  public void sendCC(int channel, int cc, int val) {
    if (rx == null) return;
    if (val < 0) val = 0; else if (val > 127) val = 127;
    try {
      ShortMessage msg = new ShortMessage();
      msg.setMessage(ShortMessage.CONTROL_CHANGE, channel, cc, val);
      rx.send(msg, -1);
    } catch (InvalidMidiDataException ex) {
      // ignore a malformed message
    }
  }

  public void close() {
    try { if (rx != null) rx.close(); } catch (Exception ex) {}
    try { if (dev != null && dev.isOpen()) dev.close(); } catch (Exception ex) {}
    rx = null;
    dev = null;
  }
}
