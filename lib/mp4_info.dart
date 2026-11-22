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
