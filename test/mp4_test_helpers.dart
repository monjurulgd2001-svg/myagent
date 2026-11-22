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

Uint8List _u16(int v) =>
    Uint8List.fromList([(v >> 8) & 0xff, v & 0xff]);

/// One VisualSampleEntry + codec config box, as the video track's
/// stsd first entry. [codec]: 'avc1' (H.264 + avcC), 'hev1' (HEVC +
/// hvcC), 'vp09' (VP9, no config box), anything else = the same
/// entry type with no config box (unknown codec path).
Uint8List _sampleEntry({
  required String codec,
  int width = 1620,
  int height = 2880,
  int avcProfile = 100,
  int avcLevel = 51,
  int hevcProfile = 2,
  int hevcLevel = 150,
}) {
  // VisualSampleEntry body (78 bytes): 6 reserved + data ref (1) +
  // 2 pre-defined + 2 reserved + 12 pre-defined + width + height +
  // horiz/vert resolution (72dpi) + 4 reserved + frame count (1) +
  // 32 compressor name + depth (0x18) + pre-defined (-1).
  final body = BytesBuilder()
    ..add(List.filled(6, 0))
    ..add(_u16(1))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(List.filled(12, 0))
    ..add(_u16(width))
    ..add(_u16(height))
    ..add(_u32(0x00480000))
    ..add(_u32(0x00480000))
    ..add(_u32(0))
    ..add(_u16(1))
    ..add(List.filled(32, 0))
    ..add(_u16(0x18))
    ..add(_u16(0xffff));
  // Codec config box after the sample entry.
  if (codec == 'avc1' || codec == 'avc3') {
    body.add(_box('avcC', [
      1, // configurationVersion
      avcProfile, 0, avcLevel,
      0xFF, 0xE0, 0, 0,
    ]));
  } else if (codec == 'hev1' || codec == 'hvc1') {
    // hvcC: version + profile byte (tier bit + profile idc) +
    // 4 compat + 6 constraint + level_idc.
    body.add(_box('hvcC', [
      1,
      (hevcProfile & 0x1f),
      0, 0, 0, 0,
      0, 0, 0, 0, 0, 0,
      hevcLevel,
    ]));
  }
  return _box(codec, body.toBytes());
}

Uint8List minimalMp4({
  int timescale = 600,
  int fps = 30,
  double durationSec = 6,
  int sampleCount = 180,
  // v156 — video track codec ('avc1' default, 'hev1', 'vp09', or
  // 'none' for no stsd at all). Drives readMp4VideoCodec tests.
  String codec = 'avc1',
  int width = 1620,
  int height = 2880,
  int avcProfile = 100,
  int avcLevel = 51,
  int hevcProfile = 2,
  int hevcLevel = 150,
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
  // stsd: version/flags + entry_count + one sample entry (the
  // video track's codec + size). 'none' = no stsd (unknown codec).
  final stsd = codec == 'none'
      ? null
      : _box(
          'stsd',
          Uint8List.fromList([
            ..._u32(0),
            ..._u32(1),
            ..._sampleEntry(
              codec: codec,
              width: width,
              height: height,
              avcProfile: avcProfile,
              avcLevel: avcLevel,
              hevcProfile: hevcProfile,
              hevcLevel: hevcLevel,
            ),
          ]),
        );
  final stbl = _box('stbl', [
    if (stsd != null) ...stsd,
    ...stts,
  ]);
  final minf = _box('minf', stbl);
  final mdia = _box('mdia', [...mdhd, ...hdlr, ...minf]);
  final trak = _box('trak', mdia);
  final moov = _box('moov', [...mvhd, ...trak]);
  return Uint8List.fromList([...ftyp, ...moov]);
}
