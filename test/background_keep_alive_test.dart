// Background keep-alive (v33) + v72 exemption fix.
//
// The channel is mocked; debugForceAndroid makes the Android-only
// paths run on the host. Test order matters: the exemption
// backstop fires on the FIRST acquire of the process, so that
// test is declared first.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/foreground_keep_alive.dart';

void main() {
  // The mock channel needs the test binding up before setUp runs.
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.geminihd.studio/foreground');
  final calls = <String>[];

  setUpAll(() {
    ForegroundKeepAlive.debugForceAndroid = true;
  });

  Future<dynamic> handler(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'isBatteryExempt':
        return false;
      case 'requestBatteryExemption':
      case 'openAppSettings':
      case 'openPhoneMaster':
        return true;
      case 'getManufacturer':
        return 'TECNO';
      default:
        return null;
    }
  }

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('first acquire checks exemption and asks when not exempt', () async {
    await ForegroundKeepAlive.acquire('test');
    // The exemption check is fire-and-forget off acquire — let it land.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(calls, contains('start'));
    expect(calls, contains('isBatteryExempt'));
    expect(calls, contains('requestBatteryExemption'));
    await ForegroundKeepAlive.release();
    expect(calls, contains('stop'));
  });

  test('nested acquire shares one service period', () async {
    await ForegroundKeepAlive.acquire('outer');
    await ForegroundKeepAlive.acquire('inner');
    // Every acquire re-delivers the start intent (label update);
    // the service itself stops only when the last holder releases.
    expect(calls.where((c) => c == 'start').length, 2);
    await ForegroundKeepAlive.release();
    expect(calls, isNot(contains('stop')));
    await ForegroundKeepAlive.release();
    expect(calls.where((c) => c == 'stop').length, 1);
  });

  test('release without acquire never stops the service', () async {
    await ForegroundKeepAlive.release();
    expect(calls, isNot(contains('stop')));
  });

  test('isBatteryExempt returns the channel value', () async {
    expect(await ForegroundKeepAlive.isBatteryExempt(), isFalse);
  });

  test('getManufacturer returns the maker', () async {
    expect(await ForegroundKeepAlive.getManufacturer(), 'TECNO');
  });

  test('openAppSettings invokes the channel', () async {
    expect(await ForegroundKeepAlive.openAppSettings(), isTrue);
    expect(calls, contains('openAppSettings'));
  });

  test('openPhoneMaster invokes the channel', () async {
    expect(await ForegroundKeepAlive.openPhoneMaster(), isTrue);
    expect(calls, contains('openPhoneMaster'));
  });

  test('acquire is a no-op while background mode is off (v77)', () async {
    ForegroundKeepAlive.enabled = false;
    try {
      await ForegroundKeepAlive.acquire('should-not-start');
      expect(calls, isNot(contains('start')));
      await ForegroundKeepAlive.release();
      expect(calls, isNot(contains('stop')));
    } finally {
      ForegroundKeepAlive.enabled = true;
    }
    await ForegroundKeepAlive.acquire('back-on');
    expect(calls, contains('start'));
    await ForegroundKeepAlive.release();
  });

  test('notifyDone posts the completion call', () async {
    await ForegroundKeepAlive.notifyDone('title', 'body');
    expect(calls, contains('notifyDone'));
  });
}
