// Originality check: compare a generated picture against the
// reference picture its prompt came from. A local pixel analysis
// (perceptual hash, layout, edges, palette, tone — the same five
// signals and weights as the reference design) gives an instant
// similarity score; an optional AI art-director review sends both
// pictures to the signed-in Gemini session for a meaning-level
// copy-risk judgement.
//
// References link automatically: when a prompt is generated from a
// picture in Image Search, [ReferenceStore] remembers which picture
// it came from, keyed by the prompt text — a set later generated
// from that prompt finds its reference again.
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'gemini_api.dart';

/// One remembered prompt → reference picture link.
class ReferenceLink {
  final Uint8List bytes;
  final String label;
  const ReferenceLink(this.bytes, this.label);
}

/// Session memory of which reference picture each generated prompt
/// came from (newest last, capped — the bytes can be large).
class ReferenceStore {
  static final Map<String, ReferenceLink> _byPrompt = {};
  static final List<String> _order = [];

  static String _key(String prompt) =>
      prompt.trim().replaceAll(RegExp(r'\s+'), ' ');

  static void remember(String prompt, Uint8List bytes, String label) {
    final k = _key(prompt);
    if (k.isEmpty) return;
    if (!_byPrompt.containsKey(k)) _order.add(k);
    _byPrompt[k] = ReferenceLink(bytes, label);
    while (_order.length > 6) {
      _byPrompt.remove(_order.removeAt(0));
    }
  }

  static ReferenceLink? lookup(String prompt) => _byPrompt[_key(prompt)];

  static List<MapEntry<String, ReferenceLink>> get entries => [
        for (final k in _order.reversed)
          if (_byPrompt[k] != null) MapEntry(k, _byPrompt[k]!),
      ];
}

/// The five pixel signals plus the weighted total, the dominant
/// colours and the dimensions of both pictures.
class OriginalityResult {
  final double structure; // perceptual hash — weight 30%
  final double composition; // layout of light/dark masses — 25%
  final double shapes; // edge map overlap — 20%
  final double palette; // colour distribution — 15%
  final double tone; // brightness distribution — 10%
  final List<int> refColors;
  final List<int> genColors;
  final int refWidth;
  final int refHeight;
  final int genWidth;
  final int genHeight;
  const OriginalityResult({
    required this.structure,
    required this.composition,
    required this.shapes,
    required this.palette,
    required this.tone,
    required this.refColors,
    required this.genColors,
    required this.refWidth,
    required this.refHeight,
    required this.genWidth,
    required this.genHeight,
  });

  double get similarity =>
      structure * 0.30 +
      composition * 0.25 +
      shapes * 0.20 +
      palette * 0.15 +
      tone * 0.10;

  double get creative => 100 - similarity;
}

({String pill, String text, Color color}) verdictFor(double similarity) {
  if (similarity <= 20) {
    return (
      pill: 'Original',
      text: 'Clearly a new picture. Only general feel is shared.',
      color: const Color(0xFF4ADE80),
    );
  }
  if (similarity <= 40) {
    return (
      pill: 'Inspired',
      text: 'A fresh picture that shares the mood and palette.',
      color: const Color(0xFF2DD4BF),
    );
  }
  if (similarity <= 60) {
    return (
      pill: 'Similar',
      text: 'Noticeable overlap with the reference. A lower '
          'similarity target would make it safer.',
      color: const Color(0xFFFBBF24),
    );
  }
  return (
    pill: 'Too close',
    text: 'This reads as a copy of the reference. Regenerate with '
        'a clearly different prompt.',
    color: const Color(0xFFF87171),
  );
}

double _clamp100(double v) => v < 0 ? 0 : (v > 100 ? 100 : v);

List<double> _grayGrid(img.Image image, int w, int h) {
  final g = img.grayscale(img.copyResize(image, width: w, height: h));
  return [
    for (var y = 0; y < h; y++)
      for (var x = 0; x < w; x++) g.getPixel(x, y).r.toDouble(),
  ];
}

int _hashBits(List<double> grid, int w, int h, {required bool diff}) {
  var bits = 0;
  if (diff) {
    // dHash: each bit compares a pixel with its right neighbour.
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w - 1; x++) {
        bits = (bits << 1) |
            (grid[y * w + x] > grid[y * w + x + 1] ? 1 : 0);
      }
    }
  } else {
    // aHash: each bit compares a pixel with the mean.
    final mean = grid.reduce((a, b) => a + b) / grid.length;
    for (final v in grid) {
      bits = (bits << 1) | (v > mean ? 1 : 0);
    }
  }
  return bits;
}

double _hashSimilarity(img.Image a, img.Image b) {
  final da = _grayGrid(a, 9, 8);
  final db = _grayGrid(b, 9, 8);
  final aa = _grayGrid(a, 8, 8);
  final ab = _grayGrid(b, 8, 8);
  int hamming(int x, int y) {
    var v = x ^ y;
    var n = 0;
    // Fixed 64 rounds: a plain while (v != 0) loop never ends when
    // the xor is negative (arithmetic shift keeps the sign bit).
    for (var i = 0; i < 64; i++) {
      n += v & 1;
      v >>= 1;
    }
    return n;
  }

  final dSim =
      (64 - hamming(_hashBits(da, 9, 8, diff: true), _hashBits(db, 9, 8, diff: true))) /
          64 *
          100;
  final aSim =
      (64 - hamming(_hashBits(aa, 8, 8, diff: false), _hashBits(ab, 8, 8, diff: false))) /
          64 *
          100;
  final raw = (dSim + aSim) / 2;
  // Curve: unrelated pictures hash-match ~50% by chance — push the
  // middle down so "different picture" reads low, like it should.
  return _clamp100(raw * raw / 100);
}

double _compositionSimilarity(img.Image a, img.Image b) {
  final ga = _grayGrid(a, 16, 16);
  final gb = _grayGrid(b, 16, 16);
  var mad = 0.0;
  for (var i = 0; i < ga.length; i++) {
    mad += (ga[i] - gb[i]).abs();
  }
  mad /= ga.length * 255;
  return _clamp100(100 * (1 - mad / 0.35));
}

double _edgeSimilarity(img.Image a, img.Image b) {
  List<bool> edges(img.Image image) {
    final g = _grayGrid(image, 96, 96);
    double at(int x, int y) => g[y * 96 + x];
    final out = List<bool>.filled(96 * 96, false);
    for (var y = 1; y < 95; y++) {
      for (var x = 1; x < 95; x++) {
        final mag =
            (at(x + 1, y) - at(x - 1, y)).abs() + (at(x, y + 1) - at(x, y - 1)).abs();
        out[y * 96 + x] = mag > 40;
      }
    }
    return out;
  }

  final ea = edges(a);
  final eb = edges(b);
  var inter = 0, na = 0, nb = 0;
  for (var i = 0; i < ea.length; i++) {
    if (ea[i]) na++;
    if (eb[i]) nb++;
    if (ea[i] && eb[i]) inter++;
  }
  if (na + nb == 0) return 100;
  return _clamp100(2 * inter / (na + nb) * 100);
}

(double, double, double) _hsv(int r, int g, int b) {
  final rf = r / 255, gf = g / 255, bf = b / 255;
  final mx = math.max(rf, math.max(gf, bf));
  final mn = math.min(rf, math.min(gf, bf));
  final d = mx - mn;
  var h = 0.0;
  if (d > 0) {
    if (mx == rf) {
      h = 60 * (((gf - bf) / d) % 6);
    } else if (mx == gf) {
      h = 60 * ((bf - rf) / d + 2);
    } else {
      h = 60 * ((rf - gf) / d + 4);
    }
  }
  if (h < 0) h += 360;
  final s = mx == 0 ? 0.0 : d / mx;
  return (h, s, mx);
}

double _paletteSimilarity(img.Image a, img.Image b) {
  (List<double>, List<double>, List<double>) hists(img.Image image) {
    final small = img.copyResize(image, width: 64, height: 64);
    final hue = List<double>.filled(24, 0);
    final sat = List<double>.filled(8, 0);
    final val = List<double>.filled(8, 0);
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        final p = small.getPixel(x, y);
        final (h, s, v) = _hsv(p.r.toInt(), p.g.toInt(), p.b.toInt());
        hue[(h / 15).floor().clamp(0, 23)] += s * (0.3 + 0.7 * v);
        sat[(s * 7.99).floor()] += 1;
        val[(v * 7.99).floor()] += 1;
      }
    }
    return (hue, sat, val);
  }

  double cosine(List<double> x, List<double> y) {
    var dot = 0.0, nx = 0.0, ny = 0.0;
    for (var i = 0; i < x.length; i++) {
      dot += x[i] * y[i];
      nx += x[i] * x[i];
      ny += y[i] * y[i];
    }
    if (nx == 0 || ny == 0) return 100;
    return dot / (math.sqrt(nx) * math.sqrt(ny)) * 100;
  }

  double intersect(List<double> x, List<double> y) {
    final sx = x.reduce((a, b) => a + b);
    final sy = y.reduce((a, b) => a + b);
    if (sx == 0 || sy == 0) return 100;
    var s = 0.0;
    for (var i = 0; i < x.length; i++) {
      s += math.min(x[i] / sx, y[i] / sy);
    }
    return s * 100;
  }

  final (ha, sa, va) = hists(a);
  final (hb, sb, vb) = hists(b);
  final hueSim = cosine(ha, hb);
  final svSim = (intersect(sa, sb) + intersect(va, vb)) / 2;
  return _clamp100(0.75 * hueSim + 0.25 * svSim);
}

double _toneSimilarity(img.Image a, img.Image b) {
  List<double> hist(img.Image image) {
    final g = _grayGrid(image, 64, 64);
    final out = List<double>.filled(16, 0);
    for (final v in g) {
      out[(v / 16).floor().clamp(0, 15)] += 1;
    }
    final total = out.reduce((x, y) => x + y);
    return [for (final v in out) v / total];
  }

  final ha = hist(a);
  final hb = hist(b);
  var s = 0.0;
  for (var i = 0; i < 16; i++) {
    s += math.min(ha[i], hb[i]);
  }
  return _clamp100(s * 100);
}

List<int> _dominantColors(img.Image image) {
  final small = img.copyResize(image, width: 96, height: 96);
  final buckets = <int, (int, int, int, int)>{};
  for (var y = 0; y < 96; y++) {
    for (var x = 0; x < 96; x++) {
      final p = small.getPixel(x, y);
      final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();
      final key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
      final cur = buckets[key] ?? (0, 0, 0, 0);
      buckets[key] = (cur.$1 + r, cur.$2 + g, cur.$3 + b, cur.$4 + 1);
    }
  }
  final sorted = buckets.values.toList()
    ..sort((a, b) => b.$4.compareTo(a.$4));
  final picked = <int>[];
  for (final bk in sorted) {
    if (picked.length >= 5) break;
    final r = bk.$1 ~/ bk.$4, g = bk.$2 ~/ bk.$4, b = bk.$3 ~/ bk.$4;
    var close = false;
    for (final c in picked) {
      final dr = ((c >> 16) & 0xFF) - r;
      final dg = ((c >> 8) & 0xFF) - g;
      final db = (c & 0xFF) - b;
      if (dr * dr + dg * dg + db * db < 1600) {
        close = true;
        break;
      }
    }
    if (!close) picked.add(0xFF000000 | (r << 16) | (g << 8) | b);
  }
  return picked;
}

String hexOf(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// Full pixel analysis of a reference / generated pair.
OriginalityResult analyzeOriginality(Uint8List refBytes, Uint8List genBytes) {
  final ref = img.decodeImage(refBytes);
  final gen = img.decodeImage(genBytes);
  if (ref == null || gen == null) {
    throw Exception('A picture could not be read (unsupported format).');
  }
  return OriginalityResult(
    structure: _hashSimilarity(ref, gen),
    composition: _compositionSimilarity(ref, gen),
    shapes: _edgeSimilarity(ref, gen),
    palette: _paletteSimilarity(ref, gen),
    tone: _toneSimilarity(ref, gen),
    refColors: _dominantColors(ref),
    genColors: _dominantColors(gen),
    refWidth: ref.width,
    refHeight: ref.height,
    genWidth: gen.width,
    genHeight: gen.height,
  );
}

OriginalityResult _analyzePair((Uint8List, Uint8List) pair) =>
    analyzeOriginality(pair.$1, pair.$2);

/// The Originality check screen: verdict + creative gauge, target
/// comparison, visual A/B compare, the five-signal breakdown, the
/// AI art-director review and the dominant colours of both sides.
class OriginalityCheckScreen extends StatefulWidget {
  final File generatedFile;
  final String generatedLabel;
  final Uint8List? referenceBytes;
  final String? referenceLabel;
  final int targetSimilarity;

  /// Make a NEW prompt from the reference at a lower similarity
  /// target; returns the prompt text. Null hides the button.
  final Future<String> Function(Uint8List refBytes, int target)?
      onLessSimilar;

  const OriginalityCheckScreen({
    super.key,
    required this.generatedFile,
    required this.generatedLabel,
    this.referenceBytes,
    this.referenceLabel,
    required this.targetSimilarity,
    this.onLessSimilar,
  });

  @override
  State<OriginalityCheckScreen> createState() =>
      _OriginalityCheckScreenState();
}

class _OriginalityCheckScreenState extends State<OriginalityCheckScreen> {
  Uint8List? _refBytes;
  String _refLabel = '';
  Uint8List? _genBytes;
  OriginalityResult? _result;
  bool _running = false;
  String? _error;
  int _compareMode = 0;
  double _split = 0.5;
  double _blend = 0.5;
  String? _aiText;
  String? _aiRisk;
  bool _aiRunning = false;
  bool _lessRunning = false;
  final _urlCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refBytes = widget.referenceBytes;
    _refLabel = widget.referenceLabel ?? '';
    _load();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      _genBytes = await widget.generatedFile.readAsBytes();
    } catch (_) {
      _genBytes = null;
    }
    if (mounted) {
      setState(() {});
      _runAnalysis();
    }
  }

  Future<void> _runAnalysis() async {
    final ref = _refBytes;
    final gen = _genBytes;
    if (ref == null || gen == null) return;
    setState(() {
      _running = true;
      _error = null;
      _aiText = null;
      _aiRisk = null;
    });
    try {
      final r = await compute(_analyzePair, (ref, gen));
      if (mounted) {
        setState(() {
          _result = r;
          _running = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _running = false;
        });
      }
    }
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _pickFromDevice() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final f = res?.files.firstOrNull;
    if (f?.bytes != null) {
      setState(() {
        _refBytes = f!.bytes;
        _refLabel = f.name;
        _result = null;
      });
      _runAnalysis();
    }
  }

  Future<void> _useUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    try {
      final resp = await http.get(Uri.parse(url), headers: {
        'User-Agent': GeminiApi.chromeUserAgent,
      });
      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        setState(() {
          _refBytes = resp.bodyBytes;
          _refLabel = url;
          _result = null;
        });
        _runAnalysis();
      } else {
        _snack('Could not download that link (HTTP ${resp.statusCode}).');
      }
    } catch (e) {
      _snack('Could not download that link: $e');
    }
  }

  Future<void> _runAiReview() async {
    final ref = _refBytes;
    final gen = _genBytes;
    if (ref == null || gen == null) return;
    setState(() => _aiRunning = true);
    try {
      final text = await GeminiApi()
          .reviewOriginality(ref, 'reference.jpg', gen, 'generated.jpg');
      var risk = '';
      final m = RegExp(r'RISK[:\s]*(LOW|MEDIUM|HIGH)', caseSensitive: false)
          .firstMatch(text);
      if (m != null) risk = m.group(1)!.toUpperCase();
      if (mounted) {
        setState(() {
          _aiText = text;
          _aiRisk = risk.isEmpty ? null : risk;
          _aiRunning = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _aiRunning = false);
        _snack('AI review failed: $e');
      }
    }
  }

  Future<void> _lessSimilar() async {
    final cb = widget.onLessSimilar;
    final ref = _refBytes;
    if (cb == null || ref == null || _lessRunning) return;
    final reduced = (widget.targetSimilarity - 10).clamp(10, 90);
    setState(() => _lessRunning = true);
    try {
      final prompt = await cb(ref, reduced);
      ReferenceStore.remember(prompt, ref, _refLabel);
      if (!mounted) return;
      setState(() => _lessRunning = false);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Less similar prompt ($reduced%)'),
          content: SingleChildScrollView(child: Text(prompt)),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: prompt));
                _snack('Prompt copied');
              },
              child: const Text('Copy'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _lessRunning = false);
        _snack('Could not make the prompt: $e');
      }
    }
  }

  void _shareSummary() {
    final r = _result;
    if (r == null) return;
    final v = verdictFor(r.similarity);
    Clipboard.setData(ClipboardData(
        text: 'Originality check — ${widget.generatedLabel}\n'
            '${v.pill}: ${r.creative.round()}% creative, '
            '${r.similarity.round()}% similar to the reference '
            '(structure ${r.structure.round()}%, '
            'composition ${r.composition.round()}%, '
            'shapes ${r.shapes.round()}%, palette ${r.palette.round()}%, '
            'tone ${r.tone.round()}%).'));
    _snack('Summary copied');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Originality check'),
        actions: [
          IconButton(
            tooltip: 'Copy summary',
            onPressed: _result == null ? null : _shareSummary,
            icon: const Icon(Icons.share_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_refBytes == null) _referencePicker(),
          if (_refBytes != null) ...[
            if (_running)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_error != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Analysis failed: $_error'),
                ),
              ),
            if (_result != null) ...[
              _verdictCard(_result!),
              const SizedBox(height: 12),
              _compareCard(_result!),
              const SizedBox(height: 12),
              _breakdownCard(_result!),
              const SizedBox(height: 12),
              _aiReviewCard(),
              const SizedBox(height: 12),
              _colorsCard(_result!),
            ],
          ],
        ],
      ),
    );
  }

  Widget _referencePicker() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Reference picture',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              'This generated picture is not linked to a reference '
              'automatically. Pick the picture its prompt came from — '
              'the new picture is compared against it.',
              style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Reference image link',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _useUrl, child: const Text('Use')),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _pickFromDevice,
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: const Text('Pick from device'),
              ),
            ),
            if (ReferenceStore.entries.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Text('Recent references',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in ReferenceStore.entries)
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _refBytes = e.value.bytes;
                          _refLabel = e.value.label;
                          _result = null;
                        });
                        _runAnalysis();
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.memory(e.value.bytes,
                            width: 56, height: 56, fit: BoxFit.cover),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            const Text('New picture',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(widget.generatedFile,
                  height: 180, width: double.infinity, fit: BoxFit.cover),
            ),
          ],
        ),
      ),
    );
  }

  Widget _verdictCard(OriginalityResult r) {
    final v = verdictFor(r.similarity);
    final target = widget.targetSimilarity;
    final measured = r.similarity.round();
    final onTarget = measured <= target;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.center,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: v.color.withValues(alpha: 0.16),
                  border: Border.all(color: v.color),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_outline, size: 14, color: v.color),
                    const SizedBox(width: 5),
                    Text(v.pill,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: v.color)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(v.text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700, height: 1.3)),
            const SizedBox(height: 4),
            Center(
              child: Text(
                'Similarity to reference: ${r.similarity.round()}% '
                '(pixel analysis)',
                style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Gauge(creative: r.creative, color: v.color),
                const SizedBox(width: 14),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: (onTarget
                              ? const Color(0xFF4ADE80)
                              : const Color(0xFFF87171))
                          .withValues(alpha: 0.10),
                      border: Border.all(
                          color: (onTarget
                                  ? const Color(0xFF4ADE80)
                                  : const Color(0xFFF87171))
                              .withValues(alpha: 0.45)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Target $target% · measured $measured% · '
                          '${onTarget ? 'On target' : 'Above target'}',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: onTarget
                                  ? const Color(0xFF4ADE80)
                                  : const Color(0xFFF87171)),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          onTarget
                              ? 'Pixel estimate — the same subject from a '
                                  'new angle reads low. Run the AI review '
                                  'for an accurate target check.'
                              : 'The new picture sits closer to the '
                                  'reference than your target. Run the AI '
                                  'review, or make a less similar prompt.',
                          style: TextStyle(
                              fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (widget.onLessSimilar != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: _lessRunning ? null : _lessSimilar,
                  icon: _lessRunning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_fix_high, size: 18),
                  label: Text(
                      'Less similar (${(target - 10).clamp(10, 90)}%)'),
                ),
              ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() {
                  _refBytes = null;
                  _result = null;
                }),
                child: const Text('Change reference'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _compareCard(OriginalityResult r) {
    final refImg = Image.memory(_refBytes!, fit: BoxFit.cover);
    final genImg = Image.file(widget.generatedFile, fit: BoxFit.cover);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cardTitle(Icons.compare, 'Visual compare',
                'A = reference · B = new image'),
            const SizedBox(height: 10),
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, icon: Icon(Icons.grid_view, size: 18)),
                ButtonSegment(
                    value: 1, icon: Icon(Icons.vertical_split, size: 18)),
                ButtonSegment(
                    value: 2, icon: Icon(Icons.layers_outlined, size: 18)),
              ],
              selected: {_compareMode},
              onSelectionChanged: (s) =>
                  setState(() => _compareMode = s.first),
            ),
            const SizedBox(height: 12),
            if (_compareMode == 0)
              Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                          child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: AspectRatio(
                                  aspectRatio: 0.72, child: refImg))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: AspectRatio(
                                  aspectRatio: 0.72, child: genImg))),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Row(
                    children: [
                      Expanded(
                          child: Text('A  Reference',
                              style: TextStyle(fontSize: 12.5))),
                      SizedBox(width: 10),
                      Expanded(
                          child:
                              Text('B  New', style: TextStyle(fontSize: 12.5))),
                    ],
                  ),
                ],
              ),
            if (_compareMode == 1) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 0.9,
                  child: LayoutBuilder(
                    builder: (ctx, c) => Stack(
                      fit: StackFit.expand,
                      children: [
                        genImg,
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: c.maxWidth * _split,
                          child: ClipRect(
                            child: OverflowBox(
                              alignment: Alignment.centerLeft,
                              maxWidth: c.maxWidth,
                              child: SizedBox(
                                  width: c.maxWidth,
                                  height: c.maxHeight,
                                  child: refImg),
                            ),
                          ),
                        ),
                        Positioned(
                          left: c.maxWidth * _split - 1,
                          top: 0,
                          bottom: 0,
                          child: Container(width: 2, color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Slider(
                value: _split,
                onChanged: (v) => setState(() => _split = v),
              ),
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('A  Reference', style: TextStyle(fontSize: 12.5)),
                  Text('B  New', style: TextStyle(fontSize: 12.5)),
                ],
              ),
            ],
            if (_compareMode == 2) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 0.9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      refImg,
                      Opacity(opacity: _blend, child: genImg),
                    ],
                  ),
                ),
              ),
              Slider(
                value: _blend,
                onChanged: (v) => setState(() => _blend = v),
              ),
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('A  Reference', style: TextStyle(fontSize: 12.5)),
                  Text('B  New', style: TextStyle(fontSize: 12.5)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _breakdownCard(OriginalityResult r) {
    Widget row(String name, double value, String caption, String weight) {
      final color = value <= 20
          ? const Color(0xFF4ADE80)
          : value <= 45
              ? const Color(0xFF2DD4BF)
              : value <= 70
                  ? const Color(0xFFFBBF24)
                  : const Color(0xFFF87171);
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(name,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                ),
                Text('${value.round()}% similar',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: color)),
              ],
            ),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: value / 100,
                minHeight: 5,
                backgroundColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text('$caption · weight $weight',
                style: TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cardTitle(Icons.bar_chart_outlined, 'Similarity breakdown',
                'Measured on the pixels — lower bar = more creative'),
            const SizedBox(height: 12),
            row('Structure fingerprint', r.structure,
                'Perceptual hash of the overall shapes', '30%'),
            row('Composition & layout', r.composition,
                'Where light, dark and masses sit in the frame', '25%'),
            row('Shapes & outlines', r.shapes,
                'Edge map — silhouettes, lines and contours', '20%'),
            row('Colour palette', r.palette,
                'Hue, saturation and value distribution', '15%'),
            row('Tone & exposure', r.tone,
                'Brightness distribution and contrast', '10%'),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 15, color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Pixel analysis cannot see meaning (the same '
                    'character in a new pose). Run the AI review for a '
                    'full professional judgement.',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _aiReviewCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cardTitle(Icons.psychology_outlined, 'AI art-director review',
                'Gemini looks at both pictures and judges the copy risk'),
            const SizedBox(height: 12),
            if (_aiText == null)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _aiRunning ? null : _runAiReview,
                  icon: _aiRunning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('Run AI review'),
                ),
              )
            else ...[
              if (_aiRisk != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: (_aiRisk == 'LOW'
                            ? const Color(0xFF4ADE80)
                            : _aiRisk == 'MEDIUM'
                                ? const Color(0xFFFBBF24)
                                : const Color(0xFFF87171))
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('Copy risk: $_aiRisk',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700)),
                ),
              const SizedBox(height: 8),
              Text(_aiText!, style: const TextStyle(fontSize: 13.5, height: 1.45)),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _aiRunning ? null : _runAiReview,
                  child: const Text('Run again'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _colorsCard(OriginalityResult r) {
    Widget swatchRow(String label, List<int> colors) {
      return Row(
        children: [
          SizedBox(
            width: 74,
            child: Text(label, style: const TextStyle(fontSize: 12.5)),
          ),
          for (final c in colors)
            Expanded(
              child: GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: hexOf(c)));
                  _snack('${hexOf(c)} copied');
                },
                child: Container(
                  height: 26,
                  margin: const EdgeInsets.only(left: 6),
                  decoration: BoxDecoration(
                    color: Color(c),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ),
        ],
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cardTitle(Icons.palette_outlined, 'Dominant colours',
                'Reference ${r.refWidth}x${r.refHeight} · new ${r.genWidth}x${r.genHeight}'),
            const SizedBox(height: 12),
            swatchRow('Reference', r.refColors),
            const SizedBox(height: 10),
            swatchRow('New', r.genColors),
          ],
        ),
      ),
    );
  }

  Widget _cardTitle(IconData icon, String title, String subtitle) {
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E2A),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, size: 18, color: const Color(0xFFC0B4FF)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
              Text(subtitle,
                  style: TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Big circular "creative %" gauge.
class _Gauge extends StatelessWidget {
  final double creative;
  final Color color;
  const _Gauge({required this.creative, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 118,
      height: 118,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size(118, 118),
            painter: _GaugePainter(
              creative / 100,
              color,
              Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.1),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${creative.round()}%',
                  style: const TextStyle(
                      fontSize: 27, fontWeight: FontWeight.w800)),
              Text('creative',
                  style: TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double fraction;
  final Color color;
  final Color trackColor;

  _GaugePainter(this.fraction, this.color, [this.trackColor = Colors.white10]);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 6;
    final bg = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9;
    canvas.drawCircle(center, radius, bg);
    final fg = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * fraction.clamp(0, 1),
      false,
      fg,
    );
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.fraction != fraction || old.color != color;
}
