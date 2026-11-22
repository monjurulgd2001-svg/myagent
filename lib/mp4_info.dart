// v154 — minimal MP4 sniffing + info, pure Dart (no Flutter imports).
//
// Why: live 2026-11-22 the animation download returned HTTP 200 but
// the saved file was not a playable MP4, so the app said "Animation
// ready ✓" and the in-frame player then failed with ExoPlayer
// "Source error". Nothing anywhere checked the bytes. Two guards:
// [isMp4Bytes] (is this an MP4 at all?) and [readMp4Info] (real fps
// + duration, so the card never again claims a hardcoded 60fps —
// live 2026-11-22 the file was 30fps while the card said 60fps).
//
// Both are defensive by design: any missing box, short read or
// inconsistent size returns false / null instead of throwing, so a
// weird-but-playable file is never rejected on a parser bug.
import 'dart:typed_data';

/// True when [bytes] look like an MP4 file: an 'ftyp' box appears
/// among the first few top-level boxes. HTML / JSON / text answers
/// (a sign-in or error page served with HTTP 200) never match.
bool isMp4Bytes(Uint8List bytes) {
  var off = 0;
  var checked = 0;
  while (off + 8 <= bytes.length && checked < 4) {
    final size = _u32(bytes, off);
    final type = String.fromCharCodes(bytes.sublist(off + 4, off + 8));
    if (type == 'ftyp') return true;
    if (size < 8) return false;
    off += size;
    checked++;
  }
  return false;
}

/// The measurable facts of an MP4 file.
class Mp4Info {
  const Mp4Info({required this.fps, required this.durationSec});

  /// Frames per second, rounded (0 = could not be measured).
  final int fps;

  /// Clip length in seconds, from the movie header (0 = unknown).
  final double durationSec;
}

/// v156 — the video track's codec identity, read from the MP4
/// header (sample entry + avcC/hvcC). Used on the preview error
/// path so the next diagnosis is grounded in what the file really
/// is — live 2026-11-22 the TECNO CAMON 30S hardware decoder
/// rejected a file Chrome plays, and nothing in the app could say
/// which codec/profile it was.
class Mp4VideoCodec {
  const Mp4VideoCodec({
    required this.codec,
    this.detail = '',
    this.width = 0,
    this.height = 0,
  });

  /// 'H.264', 'HEVC', 'VP9', 'AV1', 'MPEG-4', or 'unknown'.
  final String codec;

  /// e.g. 'High @ 5.1', 'Main 10 @ 5.1' — '' when not applicable.
  final String detail;

  /// Frame size from the sample entry (0 = unknown).
  final int width;
  final int height;

  /// One line for the preview error / log, e.g.
  /// 'H.264 High @ 5.1 · 1620x2880' or 'unknown codec'.
  String get label {
    final size = width > 0 && height > 0 ? ' · ${width}x$height' : '';
    final det = detail.isNotEmpty ? ' $detail' : '';
    return '$codec$det$size';
  }
}

/// Reads the video track's codec + size from the stsd sample entry.
/// Returns null when the boxes are missing — the caller then says
/// 'unknown codec' instead of inventing one. Never throws.
Mp4VideoCodec? readMp4VideoCodec(Uint8List bytes) {
  final moov = _findBox(bytes, 0, bytes.length, 'moov');
  if (moov == null) return null;
  var off = moov.start;
  while (true) {
    final trak = _nextBox(bytes, off, moov.end, 'trak');
    if (trak == null) break;
    off = trak.end;
    final mdia = _findBox(bytes, trak.start, trak.end, 'mdia');
    if (mdia == null) continue;
    final hdlr = _findBox(bytes, mdia.start, mdia.end, 'hdlr');
    if (hdlr != null) {
      final h = _boxBody(bytes, hdlr);
      if (h == null || h.length < 12) continue;
      if (String.fromCharCodes(h.sublist(8, 12)) != 'vide') continue;
    }
    final minf = _findBox(bytes, mdia.start, mdia.end, 'minf');
    final stbl =
        minf != null ? _findBox(bytes, minf.start, minf.end, 'stbl') : null;
    if (stbl == null) continue;
    final stsd = _findBox(bytes, stbl.start, stbl.end, 'stsd');
    if (stsd == null) continue;
    final body = _boxBody(bytes, stsd);
    // stsd: version/flags (4) + entry_count (4) + first entry.
    if (body == null || body.length < 8) continue;
    final entryCount = _u32(body, 4);
    if (entryCount <= 0 || body.length < 16) continue;
    final entrySize = _u32(body, 8);
    if (entrySize < 86 || body.length < 8 + entrySize) continue;
    final type = String.fromCharCodes(body.sublist(12, 16));
    // VisualSampleEntry: 24 bytes before width/height (6 reserved
    // + data ref + pre-defined + reserved + 12 pre-defined), then
    // width u16, height u16. Entry starts at body offset 8.
    final width = _u16(body, 8 + 8 + 24);
    final height = _u16(body, 8 + 8 + 26);
    // Child boxes (avcC / hvcC) follow the 78-byte sample entry.
    const childStart = 8 + 8 + 78;
    final childEnd = 8 + entrySize;
    switch (type) {
      case 'avc1':
      case 'avc3':
        final avcC = _findBox(body, childStart, childEnd, 'avcC');
        final avcBody = avcC != null ? _boxBody(body, avcC) : null;
        return Mp4VideoCodec(
          codec: 'H.264',
          detail: avcBody != null && avcBody.length >= 4
              ? '${_avcProfileName(avcBody[1])} @ ${_avcLevel(avcBody[3])}'
              : '',
          width: width,
          height: height,
        );
      case 'hev1':
      case 'hvc1':
        final hvcC = _findBox(body, childStart, childEnd, 'hvcC');
        final hvcBody = hvcC != null ? _boxBody(body, hvcC) : null;
        return Mp4VideoCodec(
          codec: 'HEVC',
          detail: hvcBody != null && hvcBody.length >= 13
              ? '${_hevcProfileName(hvcBody[1] & 0x1f)}'
                  '${((hvcBody[1] >> 5) & 1) == 1 ? ' High Tier' : ''}'
                  ' @ ${_hevcLevel(hvcBody[12])}'
              : '',
          width: width,
          height: height,
        );
      case 'vp09':
        return Mp4VideoCodec(
            codec: 'VP9', width: width, height: height);
      case 'av01':
        return Mp4VideoCodec(
            codec: 'AV1', width: width, height: height);
      case 'mp4v':
        return Mp4VideoCodec(
            codec: 'MPEG-4', width: width, height: height);
      default:
        return Mp4VideoCodec(
            codec: 'unknown',
            detail: '($type)',
            width: width,
            height: height);
    }
  }
  return null;
}

int _u16(Uint8List b, int off) => (b[off] << 8) | b[off + 1];

String _avcProfileName(int id) => switch (id) {
      66 => 'Baseline',
      77 => 'Main',
      88 => 'Extended',
      100 => 'High',
      110 => 'High 10',
      122 => 'High 4:2:2',
      144 => 'High 4:4:4',
      _ => 'Profile $id',
    };

/// AVC level_idc is level x10 (51 -> 5.1).
String _avcLevel(int levelIdc) =>
    '${levelIdc ~/ 10}.${levelIdc % 10}';

String _hevcProfileName(int id) => switch (id) {
      1 => 'Main',
      2 => 'Main 10',
      3 => 'Main Still Picture',
      _ => 'Profile $id',
    };

/// HEVC level_idc is level x30 (150 -> 5.0, 153 -> 5.1).
String _hevcLevel(int levelIdc) =>
    '${levelIdc ~/ 30}.${(levelIdc % 30) ~/ 3}';

/// Reads fps + duration from the moov box (mvhd duration/timescale,
/// video trak mdhd timescale + stts sample deltas). Returns null
/// when the boxes are missing or inconsistent — the caller then
/// keeps the event's values instead of inventing numbers.
Mp4Info? readMp4Info(Uint8List bytes) {
  final moov = _findBox(bytes, 0, bytes.length, 'moov');
  if (moov == null) return null;
  double durationSec = 0;
  final mvhd = _findBox(bytes, moov.start, moov.end, 'mvhd');
  if (mvhd != null) {
    final d = _mvhdDuration(bytes, mvhd);
    if (d != null) durationSec = d;
  }
  // Walk the tracks; the video track is the one whose hdlr says
  // 'vide' (an audio track's stts would give a nonsense fps).
  var off = moov.start;
  while (true) {
    final trak = _nextBox(bytes, off, moov.end, 'trak');
    if (trak == null) break;
    off = trak.end;
    final mdia = _findBox(bytes, trak.start, trak.end, 'mdia');
    if (mdia == null) continue;
    final hdlr = _findBox(bytes, mdia.start, mdia.end, 'hdlr');
    if (hdlr != null) {
      final h = _boxBody(bytes, hdlr);
      if (h == null || h.length < 12) continue;
      if (String.fromCharCodes(h.sublist(8, 12)) != 'vide') continue;
    }
    final mdhd = _findBox(bytes, mdia.start, mdia.end, 'mdhd');
    final minf = _findBox(bytes, mdia.start, mdia.end, 'minf');
    final stbl =
        minf != null ? _findBox(bytes, minf.start, minf.end, 'stbl') : null;
    if (mdhd == null || stbl == null) continue;
    final timescale = _mdhdTimescale(bytes, mdhd);
    final stts = _findBox(bytes, stbl.start, stbl.end, 'stts');
    if (timescale == null || timescale <= 0 || stts == null) continue;
    final fps = _sttsFps(bytes, stts, timescale);
    if (fps == null || fps <= 0) continue;
    if (durationSec <= 0) {
      final md = _mdhdDuration(bytes, mdhd, timescale);
      if (md != null && md > 0) durationSec = md;
    }
    return Mp4Info(fps: fps, durationSec: durationSec);
  }
  return null;
}

/// One box: [start]/[end] bound its payload (after the header).
class _Box {
  const _Box(this.start, this.end);
  final int start;
  final int end;
}

int _u32(Uint8List b, int off) =>
    (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];

int _u64(Uint8List b, int off) {
  var v = 0;
  for (var i = 0; i < 8; i++) {
    v = (v << 8) | b[off + i];
  }
  return v;
}

/// The next top-level box of [type] at or after [off] within [end],
/// or null. Handles 32-bit sizes, 64-bit largesize (size == 1) and
/// size == 0 (box runs to the end of its parent).
_Box? _nextBox(Uint8List b, int off, int end, String type) {
  var p = off;
  while (p + 8 <= end && p + 8 <= b.length) {
    var size = _u32(b, p);
    var header = 8;
    if (size == 1) {
      if (p + 16 > b.length) return null;
      size = _u64(b, p + 8);
      header = 16;
    } else if (size == 0) {
      size = end - p;
    }
    if (size < header) return null;
    final boxEnd = p + size;
    if (boxEnd > b.length) return null;
    if (String.fromCharCodes(b.sublist(p + 4, p + 8)) == type) {
      return _Box(p + header, boxEnd > end ? end : boxEnd);
    }
    p = boxEnd;
    if (p > end) return null;
  }
  return null;
}

_Box? _findBox(Uint8List b, int start, int end, String type) =>
    _nextBox(b, start, end, type);

/// The payload bytes of [box], or null when out of range.
Uint8List? _boxBody(Uint8List b, _Box box) {
  if (box.start < 0 || box.end > b.length || box.start > box.end) {
    return null;
  }
  return b.sublist(box.start, box.end);
}

/// mvhd duration in seconds (timescale + duration fields).
/// Version 0: timescale @12, duration @16 (u32). Version 1:
// timescale @20, duration @24 (u64).
double? _mvhdDuration(Uint8List b, _Box mvhd) {
  final body = _boxBody(b, mvhd);
  if (body == null || body.isEmpty) return null;
  final version = body[0];
  if (version == 1) {
    if (body.length < 32) return null;
    final timescale = _u32(body, 20);
    final duration = _u64(body, 24);
    if (timescale <= 0) return null;
    return duration / timescale;
  }
  if (body.length < 20) return null;
  final timescale = _u32(body, 12);
  final duration = _u32(body, 16);
  if (timescale <= 0) return null;
  return duration / timescale;
}

/// mdhd timescale. Version 0: @12. Version 1: @20.
int? _mdhdTimescale(Uint8List b, _Box mdhd) {
  final body = _boxBody(b, mdhd);
  if (body == null || body.isEmpty) return null;
  if (body[0] == 1) {
    if (body.length < 24) return null;
    return _u32(body, 20);
  }
  if (body.length < 16) return null;
  return _u32(body, 12);
}

/// mdhd duration in seconds.
double? _mdhdDuration(Uint8List b, _Box mdhd, int timescale) {
  final body = _boxBody(b, mdhd);
  if (body == null || body.isEmpty) return null;
  if (body[0] == 1) {
    if (body.length < 32) return null;
    return _u64(body, 24) / timescale;
  }
  if (body.length < 20) return null;
  return _u32(body, 16) / timescale;
}

/// fps from an stts box: timescale / weighted-average sample delta.
int? _sttsFps(Uint8List b, _Box stts, int timescale) {
  final body = _boxBody(b, stts);
  if (body == null || body.length < 8) return null;
  final count = _u32(body, 4);
  if (count <= 0 || body.length < 8 + count * 8) return null;
  var samples = 0;
  var totalDelta = 0;
  for (var i = 0; i < count; i++) {
    final n = _u32(body, 8 + i * 8);
    final delta = _u32(body, 12 + i * 8);
    if (n <= 0 || delta <= 0) return null;
    samples += n;
    totalDelta += n * delta;
  }
  if (samples <= 0 || totalDelta <= 0) return null;
  final avgDelta = totalDelta / samples;
  return (timescale / avgDelta).round();
}
