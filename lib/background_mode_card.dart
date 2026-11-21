// Background generation card (v77, moved to the Login screen in
// v84 on the user's order: it is a settings item, not dashboard
// chrome — it lives where he signs in, under the Gemini web
// session card).
//
// One in-app switch instead of hunting through Settings. ON
// (default) arms the foreground keep-alive for every generation;
// when the phone is not exempt it offers the one-tap Allow screen
// + the Phone Master button right here. OFF means foreground-only
// generation. The switch is the preference; the status line shows
// the real state.
//
// The widget owns its state: it loads the persisted switch
// (SharedPreferences 'bgModeEnabled', default ON), the battery
// exemption, and whether this is a Transsion phone, and it drives
// ForegroundKeepAlive.enabled — the single choke point the
// generation chain checks — so the dashboard never needs to know
// the card's state.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'foreground_keep_alive.dart';

class BackgroundModeCard extends StatefulWidget {
  const BackgroundModeCard({super.key});

  @override
  State<BackgroundModeCard> createState() => _BackgroundModeCardState();
}

class _BackgroundModeCardState extends State<BackgroundModeCard> {
  bool _bgMode = true;
  bool? _bgExempt;
  bool _isTranssion = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final maker = await ForegroundKeepAlive.getManufacturer();
    final exempt = await ForegroundKeepAlive.isBatteryExempt();
    if (!mounted) return;
    setState(() {
      _bgMode = prefs.getBool('bgModeEnabled') ?? true;
      _isTranssion = <String>['tecno', 'infinix', 'itel', 'transsion']
          .any((m) => maker.toLowerCase().contains(m));
      _bgExempt = exempt;
    });
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _setBgMode(bool value) async {
    setState(() => _bgMode = value);
    ForegroundKeepAlive.enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('bgModeEnabled', value);
    if (!value) {
      _snack('Background generation OFF — lock korle generation thambe.');
      return;
    }
    if (_bgExempt == false) await _fixExemption();
  }

  /// One-tap exemption: opens the system Allow screen, then
  /// re-checks. The switch stays ON either way — the status line
  /// above shows the real state.
  Future<void> _fixExemption() async {
    await ForegroundKeepAlive.requestBatteryExemption();
    final nowExempt = await ForegroundKeepAlive.isBatteryExempt();
    if (mounted) setState(() => _bgExempt = nowExempt);
    if (!nowExempt && mounted) {
      _snack('Allow deoa hoy nai — system screen-e "Allow" chapte hobe.');
    }
  }

  Future<void> _openPhoneMaster() async {
    final opened = await ForegroundKeepAlive.openPhoneMaster();
    if (!mounted) return;
    if (!opened) {
      _snack(
          'Phone Master app pai nai — app settings khullam, okhane Battery dekho.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final exempt = _bgExempt == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: exempt
            ? Colors.green.withValues(alpha: 0.12)
            : Colors.amber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    exempt
                        ? Icons.battery_charging_full_outlined
                        : Icons.battery_alert_outlined,
                    size: 18,
                    color: exempt ? Colors.green : Colors.amber,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Background generation',
                      style:
                          TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Switch(
                    key: const ValueKey('bgModeSwitch'),
                    value: _bgMode,
                    onChanged: _setBgMode,
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 26),
                child: Text(
                  !_bgMode
                      ? 'OFF — phone lock korle generation thambe.'
                      : exempt
                          ? 'ON — lock korleo cholbe.'
                          : 'ON, kintu phone-er permission baki — niche Allow koro.',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              if (_bgMode && !exempt) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 26),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: _fixExemption,
                        child: const Text('Allow koro'),
                      ),
                      if (_isTranssion)
                        OutlinedButton(
                          onPressed: _openPhoneMaster,
                          child: const Text('Phone Master kholo'),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
