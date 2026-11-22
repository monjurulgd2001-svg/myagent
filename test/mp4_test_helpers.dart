// v154 — minimal MP4 builder for tests: ftyp + moov (mvhd + one
// video trak with mdhd timescale + stts). Not a playable video (no
// mdat) — enough for the header sniff (isMp4Bytes) and the
// fps/duration parsing (readMp4Info). [fps] drives the stts delta,
// [durationSec] drives the mvhd/mdhd duration.
import 'dart:typed_data';

Uint8List _u32(int v) => Uint8List.fromList(
    [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);

Uint8List _box(String type, List<int> payload) {
  final out = BytesBuilder();
  out.add(_u32(8 + payload.length));
  out.add(type.codeUnits);
  out.add(payload);
  return out.toBytes();
}

Uint8List minimalMp4({
  int timescale = 600,
  int fps = 30,
  double durationSec = 6,
  int sampleCount = 180,
}) {
  final delta = timescale ~/ fps;
  final duration = (durationSec * timescale).round();
  // ftyp: major 'isom', minor 0, brands isom/iso2.
  final ftyp = _box('ftyp', [
    ...'isom'.codeUnits,
    ..._u32(0),
    ...'isom'.codeUnits,
    ...'iso2'.codeUnits,
  ]);
  // mvhd v0: version/flags + creation + modification + timescale +
  // duration + rate(0x00010000) + volume + reserved + matrix +
  // predefined + nextTrackId.
  final mvhdBody = BytesBuilder()
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(timescale))
    ..add(_u32(duration))
    ..add(_u32(0x00010000))
    ..add([0, 0])
    ..add(List.filled(10, 0))
    ..add(List.filled(36, 0))
    ..add(List.filled(24, 0))
    ..add(_u32(2));
  final mvhd = _box('mvhd', mvhdBody.toBytes());
  // mdhd v0: version/flags + creation + modification + timescale +
  // duration + language + preDefined.
  final mdhdBody = BytesBuilder()
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(timescale))
    ..add(_u32(duration))
    ..add([0, 0])
    ..add([0, 0]);
  final mdhd = _box('mdhd', mdhdBody.toBytes());
  // hdlr: version/flags + preDefined + handler 'vide' + reserved
  // + name.
  final hdlrBody = BytesBuilder()
    ..add(_u32(0))
    ..add(_u32(0))
    ..add('vide'.codeUnits)
    ..add(List.filled(12, 0))
    ..add([...'VideoHandler'.codeUnits, 0]);
  final hdlr = _box('hdlr', hdlrBody.toBytes());
  // stts: version/flags + entryCount + one entry (count, delta).
  final sttsBody = BytesBuilder()
    ..add(_u32(0))
    ..add(_u32(1))
    ..add(_u32(sampleCount))
    ..add(_u32(delta));
  final stts = _box('stts', sttsBody.toBytes());
  final stbl = _box('stbl', stts);
  final minf = _box('minf', stbl);
  final mdia = _box('mdia', [...mdhd, ...hdlr, ...minf]);
  final trak = _box('trak', mdia);
  final moov = _box('moov', [...mvhd, ...trak]);
  return Uint8List.fromList([...ftyp, ...moov]);
}
