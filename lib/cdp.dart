import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One Chrome DevTools Protocol event.
class CdpEvent {
  final String method;
  final Map<String, dynamic> params;
  final String? sessionId;
  const CdpEvent(this.method, this.params, this.sessionId);
}

class CdpException implements Exception {
  final String message;
  CdpException(this.message);
  @override
  String toString() => message;
}

/// Minimal CDP client over the browser-level DevTools WebSocket, using
/// "flat" sessions (every page session is multiplexed on one socket).
class CdpConnection {
  CdpConnection._(this._ws) {
    _sub = _ws.listen(_onData,
        onDone: _onClosed, onError: (_) => _onClosed(), cancelOnError: true);
  }

  final WebSocket _ws;
  late final StreamSubscription _sub;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final _events = StreamController<CdpEvent>.broadcast();
  final _closed = Completer<void>();

  Stream<CdpEvent> get events => _events.stream;
  Future<void> get done => _closed.future;
  bool get isOpen => !_closed.isCompleted;

  static Future<CdpConnection> connect(String wsUrl,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final ws = await WebSocket.connect(wsUrl).timeout(timeout);
    ws.pingInterval = const Duration(seconds: 20);
    return CdpConnection._(ws);
  }

  /// Sends [method] and waits for its result. [sessionId] targets a page
  /// session obtained from `Target.attachToTarget(flatten: true)`.
  Future<Map<String, dynamic>> send(String method,
      {Map<String, dynamic>? params,
      String? sessionId,
      Duration timeout = const Duration(seconds: 30)}) {
    if (!isOpen) {
      return Future.error(CdpException('Browser connection is closed.'));
    }
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _ws.add(jsonEncode({
      'id': id,
      'method': method,
      if (params != null) 'params': params,
      if (sessionId != null) 'sessionId': sessionId,
    }));
    return c.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw CdpException('$method timed out.');
    });
  }

  void _onData(dynamic data) {
    if (data is! String) return;
    Map<String, dynamic> msg;
    try {
      msg = (jsonDecode(data) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final id = msg['id'];
    if (id is int) {
      final c = _pending.remove(id);
      if (c == null || c.isCompleted) return;
      final err = msg['error'];
      if (err is Map) {
        c.completeError(CdpException('${err['message'] ?? err}'));
      } else {
        c.complete(((msg['result'] as Map?) ?? const {}).cast<String, dynamic>());
      }
      return;
    }
    final method = msg['method'];
    if (method is String) {
      _events.add(CdpEvent(
          method,
          ((msg['params'] as Map?) ?? const {}).cast<String, dynamic>(),
          msg['sessionId'] as String?));
    }
  }

  void _onClosed() {
    if (_closed.isCompleted) return;
    _closed.complete();
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(CdpException('Browser connection closed.'));
      }
    }
    _pending.clear();
    _events.close();
  }

  Future<void> close() async {
    try {
      await _sub.cancel();
      await _ws.close();
    } catch (_) {}
    _onClosed();
  }
}
