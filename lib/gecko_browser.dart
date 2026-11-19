import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// One picture reference from the in-page overlay.
class GeckoImageRef {
  final String src;
  final String hi;
  final String alt;
  final String kind;
  final Map<String, dynamic> meta;
  const GeckoImageRef({
    required this.src,
    this.hi = '',
    this.alt = '',
    this.kind = '',
    this.meta = const {},
  });

  static GeckoImageRef? fromJson(Object? j) {
    if (j is! Map) return null;
    final src = (j['src'] ?? '').toString();
    if (src.isEmpty) return null;
    return GeckoImageRef(
      src: src,
      hi: (j['hi'] ?? '').toString(),
      alt: (j['alt'] ?? '').toString(),
      kind: (j['kind'] ?? '').toString(),
      meta: j['meta'] is Map
          ? (j['meta'] as Map).cast<String, dynamic>()
          : const {},
    );
  }
}

/// One request batch entry from the overlay: an [action]
/// ('select' | 'unselect' | 'clear_basket' | 'generate_basket' |
/// 'single' | 'capture') with its picture references. Shared by
/// both overlay transports (Android Gecko + Windows Chromium);
/// [sessionId] is the Chromium tab's CDP session ('' on Android).
class GeckoBrowserRequest {
  final String action;
  final List<GeckoImageRef> images;
  final String page;
  final String title;
  final String sessionId;
  /// Extra payload for non-picture events (v86: the Gemini video
  /// driver sends `video_progress` / `video_ready` / `video_error`
  /// with their data here; empty for picture requests).
  final Map<String, dynamic> data;
  const GeckoBrowserRequest(this.action, this.images, this.page,
      this.title,
      {this.sessionId = '', this.data = const {}});
}

/// Android: the Image Search browser — the built-in Firefox engine
/// (GeckoView) with the picture-selection overlay, sharing the
/// runtime + extension of the Gecko sign-in (see gecko_signin.dart).
/// Requests and status travel over the same `com.geminihd.studio/
/// gecko` channel as the sign-in; this client is the channel's only
/// incoming-call handler, registered when the singleton is created.
///
/// Pattern adapted from the AI Image Studio source the user
/// provided (its GeckoPromptBrowser + overlay protocol).
class GeckoBrowser {
  GeckoBrowser._() {
    _ch.setMethodCallHandler(_onCall);
  }

  static GeckoBrowser? _instance;
  static GeckoBrowser get instance => _instance ??= GeckoBrowser._();

  static const _ch = MethodChannel('com.geminihd.studio/gecko');

  final _requests = StreamController<GeckoBrowserRequest>.broadcast();
  final _changes = StreamController<void>.broadcast();
  Stream<GeckoBrowserRequest> get requests => _requests.stream;
  Stream<void> get changes => _changes.stream;

  bool isOpen = false;
  bool visible = false;
  int _basketVersion = 0;

  Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'browserRequest':
        for (final r in parseRequests(call.arguments as String)) {
          _requests.add(r);
        }
        return null;
      case 'browserState':
        try {
          final o = jsonDecode(call.arguments as String) as Map;
          isOpen = o['open'] == true;
          visible = o['visible'] == true;
        } catch (_) {}
        _changes.add(null);
        return null;
    }
    return null;
  }

  /// Pure: parses one native `browserRequest` payload — the
  /// extension's `{type:'q', q:[<json string>, ...], page, title}`
  /// wrapper — into individual requests. Malformed entries are
  /// skipped, never thrown.
  static List<GeckoBrowserRequest> parseRequests(String json) {
    Map m;
    try {
      m = jsonDecode(json) as Map;
    } catch (_) {
      return const [];
    }
    final out = <GeckoBrowserRequest>[];
    for (final raw in (m['q'] as List? ?? const [])) {
      try {
        final r = jsonDecode(raw.toString()) as Map;
        final imgs = <GeckoImageRef>[
          for (final i in (r['images'] as List? ?? const []))
            if (GeckoImageRef.fromJson(i) case final ref?) ref,
        ];
        out.add(GeckoBrowserRequest(
          (r['action'] ?? 'single').toString(),
          imgs,
          (r['page'] ?? m['page'] ?? '').toString(),
          (r['title'] ?? m['title'] ?? '').toString(),
          data: r['data'] is Map
              ? (r['data'] as Map).cast<String, dynamic>()
              : const {},
        ));
      } catch (_) {}
    }
    return out;
  }

  /// Opens the browser screen (loading [url] when given), or brings
  /// the existing one back to the front.
  Future<void> open([String? url]) async {
    await _ch.invokeMethod('browserOpen', {'url': url});
    isOpen = true;
    _changes.add(null);
  }

  Future<void> close() async {
    try {
      await _ch.invokeMethod('browserClose');
    } catch (_) {}
    isOpen = false;
    visible = false;
    _changes.add(null);
  }

  /// Re-reads whether the browser tab exists (native is the truth).
  Future<void> refreshIsOpen() async {
    try {
      isOpen = await _ch.invokeMethod<bool>('browserIsOpen') ?? isOpen;
      _changes.add(null);
    } catch (_) {}
  }

  /// Pushes the app-side selection ("basket") into every open page;
  /// the overlay mirrors it as ticked pictures.
  void setBasket(List<String> srcs, int pages) {
    _basketVersion++;
    _ch
        .invokeMethod(
            'browserBasket',
            jsonEncode({
              'srcs': srcs,
              'v': _basketVersion,
              'pages': pages,
            }))
        .catchError((_) => null);
  }

  /// Per-picture status shown on the page ('queued' | 'running' |
  /// 'done' | 'error'), with an optional short message.
  Future<void> notifyStatus(String src, String state,
      [String message = '']) async {
    try {
      await _ch.invokeMethod('browserStatus',
          jsonEncode({'src': src, 'state': state, 'message': message}));
    } catch (_) {}
  }

  Future<void> toast(String msg) async {
    try {
      await _ch.invokeMethod('browserToast', msg);
    } catch (_) {}
  }

  /// v86: hands a video job to the in-page Gemini driver (the
  /// extension's content script on gemini.google.com): pick [model],
  /// open "Create video", send [prompt], and report the finished
  /// MP4 back as `video_*` browserRequests. Fire-and-forget — the
  /// driver answers through the requests stream, not this call.
  Future<void> startVideo(
      String prompt, String modelId, String jobId) async {
    await _ch.invokeMethod(
        'browserVideo',
        jsonEncode({
          'prompt': prompt,
          'model': modelId,
          'jobId': jobId,
        }));
  }

  /// Downloads a picture through the engine (hot-link / CORS
  /// fallback); returns a data: URL or null.
  Future<String?> fetchDataUrl(String src) async {
    try {
      return await _ch.invokeMethod<String>('browserFetch', src);
    } catch (_) {
      return null;
    }
  }

  /// Screenshots an area of the visible page; [frac] is
  /// {x, y, w, h} as shares of the viewport (0..1). PNG bytes or
  /// null.
  Future<Uint8List?> captureRegion(Map<String, dynamic> frac) async {
    try {
      final b64 =
          await _ch.invokeMethod<String>('browserCapture', jsonEncode(frac));
      if (b64 == null || b64.isEmpty) return null;
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }
}
