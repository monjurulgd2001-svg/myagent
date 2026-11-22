/// v86 — Charging Animation section UI: the prompt card (model
/// picker with Neon default, Task switch, Generate) on top and the
/// finished-video gallery below, in the same phone/wide split as
/// the Studio screen (v85: one scroll view on phone, 430px panel +
/// gallery side-by-side on wide).
///
/// v87 — each video card gains AI Metadata (generate + view) and
/// Upload to Panel, and the gallery header gains an upload-all
/// button, mirroring the image sets.
///
/// The screen is stateful for the prompt text, the picked model and
/// its own scroll position; the videos, phase and Task choice live
/// in [AnimationEngine] and reach here through rebuilds.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'animation_engine.dart';
import 'animation_models.dart';
import 'meta_card_style.dart';
import 'models.dart';
import 'voice_prompt.dart';

class AnimationSection extends StatefulWidget {
  const AnimationSection({
    super.key,
    required this.engine,
    required this.signedIn,
    required this.wide,
    required this.onGenerate,
    required this.onPlay,
    required this.onDelete,
    required this.onExportZip,
    required this.onMetadata,
    required this.onUploadToPanel,
    required this.onUploadAllToPanel,
    // v154 — manual "60fps-e abar banaw" retry (a regeneration
    // spends quota, so it is the user's tap, never automatic).
    // Null = no retry offered (e.g. tests / old call sites).
    this.onRetry60Fps,
  });

  final AnimationEngine engine;
  final bool signedIn;
  final bool wide;
  final Future<void> Function(String prompt, String modelId) onGenerate;
  final void Function(AnimationVideo video) onPlay;
  final void Function(AnimationVideo video) onDelete;
  final VoidCallback onExportZip;
  final Future<void> Function(AnimationVideo video) onMetadata;
  final Future<void> Function(AnimationVideo video) onUploadToPanel;
  final Future<void> Function() onUploadAllToPanel;
  final Future<void> Function(AnimationVideo video)? onRetry60Fps;

  @override
  State<AnimationSection> createState() => _AnimationSectionState();
}

class _AnimationSectionState extends State<AnimationSection> {
  final _promptCtrl = TextEditingController();
  bool _polishing = false;
  // v153 — Windows-only mic listening state (Android keeps the
  // v143 removal — no mic there).
  bool _listening = false;
  // v133 — Animation gallery grid columns (1..6, default 3 like generate-main).
  int _gridCols = 3;
  // v159 second pass — per-video metadata expand state: the image
  // card's single shared bool cannot be reused across a list (one
  // tap would expand every card). One video id in here = its
  // metadata block is expanded.
  final Set<String> _expandedVideoMeta = {};
  final _scrollCtrl = ScrollController();
  final _galleryKey = GlobalKey();
  int _seenVideoCount = 0;


  /// v93 — the screen's colours come from the app theme (dark
  /// lavender by default, light lavender when the toggle is on),
  /// never hardcoded — so the dark/light switch repaints this
  /// screen too.
  ColorScheme get _cs => Theme.of(context).colorScheme;

  @override
  void initState() {
    super.initState();
    _promptCtrl.addListener(() => setState(() {}));
    _seenVideoCount = widget.engine.videos.length;
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// After a video lands, scroll the phone screen down to the
  /// gallery so the new animation shows without hunting for it
  /// (same idea as the Studio auto-scroll in v85).
  void _maybeScrollToGallery() {
    final count = widget.engine.videos.length;
    if (count <= _seenVideoCount) return;
    _seenVideoCount = count;
    if (widget.wide) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _galleryKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOut);
      }
    });
  }

  void _scrollToTop() {
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(0,
          duration: const Duration(milliseconds: 400), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    _maybeScrollToGallery();
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    if (widget.wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 430,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _promptCard(isAndroid),
                  const SizedBox(height: 12),
                  _settingsCard(),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _galleryPanel()),
        ],
      );
    }
    return SingleChildScrollView(
      controller: _scrollCtrl,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _promptCard(isAndroid),
          const SizedBox(height: 12),
          _settingsCard(),
          const SizedBox(height: 12),
          _galleryInline(),
        ],
      ),
    );
  }

  /// v88 — Polish: rewrites the prompt via the Gemini session
  /// (same flow as the image Prompt Polish), then puts the
  /// polished text back in the field.
  Future<void> _onPolishTap() async {
    final text = _promptCtrl.text.trim();
    if (text.isEmpty || _polishing) return;
    setState(() => _polishing = true);
    final polished = await widget.engine.polishPrompt(text);
    if (!mounted) return;
    setState(() => _polishing = false);
    if (polished != null && polished.isNotEmpty) {
      _promptCtrl.text = polished;
      _promptCtrl.selection =
          TextSelection.collapsed(offset: polished.length);
    }
  }

  /// v153 — Windows-only voice prompt: listens once and appends
  /// what was heard to the animation prompt field. A failed /
  /// silent listen leaves the field untouched.
  Future<void> _listenToPrompt() async {
    if (_listening || widget.engine.busy) return;
    setState(() => _listening = true);
    final heard = await VoicePrompt().listenOnce();
    if (!mounted) return;
    setState(() => _listening = false);
    if (heard == null || heard.isEmpty) return;
    final cur = _promptCtrl.text;
    final sep = cur.isEmpty || cur.endsWith(' ') ? '' : ' ';
    _promptCtrl.text = '$cur$sep$heard';
    _promptCtrl.selection =
        TextSelection.collapsed(offset: _promptCtrl.text.length);
  }

  Widget _promptCard(bool isAndroid) {
    final engine = widget.engine;
    final prompt = _promptCtrl.text.trim();
    // v88 — Generate stays off while a copyright-risk term is in
    // the prompt (the engine also blocks it at start()).
    final safetyFlags = checkAnimationPromptSafety(prompt);
    final canGenerate = prompt.isNotEmpty &&
        safetyFlags.isEmpty &&
        !engine.busy &&
        widget.signedIn;
    return Card(
      shape: RoundedRectangleBorder(
        // v109 — reference layout: same 20px radius as the global
        // card theme (was 16).
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: _cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _cs.primary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.movie_outlined,
                      color: _cs.primary, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Charging Animation',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: _cs.onSurface)),
                      Text('Gemini diye video banaw — Zedge live wallpaper',
                          style: TextStyle(
                              fontSize: 11, color: _cs.onSurface.withValues(alpha: 0.6))),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('animPromptField'),
              controller: _promptCtrl,
              minLines: 3,
              maxLines: 5,
              style: TextStyle(color: _cs.onSurface, fontSize: 14),
              decoration: InputDecoration(
                hintText:
                    'e.g. Neon blue liquid energy charging smartphone…',
                hintStyle: TextStyle(color: _cs.onSurface.withValues(alpha: 0.38)),
                filled: true,
                fillColor: _cs.surfaceContainer,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: _cs.outlineVariant),
                ),
                // v120 — Polish wand lives inside the field next to
                // the clear X (Studio v115 pattern): the Polish row
                // + helper line below the field are gone. Both icons
                // are compact 36px targets; the wand spins while
                // polishing. Same key, same tap handler.
                suffixIconConstraints:
                    const BoxConstraints(minWidth: 0, minHeight: 0),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // v153 — Windows-only mic (speech_to_text's
                    // Windows implementation is already in the
                    // tree). Android keeps the v143 removal.
                    if (VoicePrompt.isSupportedOn(defaultTargetPlatform))
                      _listening
                          ? const SizedBox(
                              width: 36,
                              height: 36,
                              child: Center(
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                ),
                              ),
                            )
                          : IconButton(
                              key: const ValueKey('animMicButton'),
                              icon: const Icon(Icons.mic, size: 18),
                              tooltip: 'Voice prompt',
                              color: _cs.primary,
                              onPressed: widget.engine.busy
                                  ? null
                                  : _listenToPrompt,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                  width: 36, height: 36),
                            ),
                    if (_polishing)
                      const SizedBox(
                        width: 36,
                        height: 36,
                        child: Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    else
                      IconButton(
                        key: const ValueKey('animPolishButton'),
                        icon: const Icon(Icons.auto_fix_high, size: 18),
                        tooltip: 'Polish prompt',
                        color: _cs.primary,
                        onPressed: (prompt.isEmpty || engine.busy)
                            ? null
                            : _onPolishTap,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                            width: 36, height: 36),
                      ),
                    if (_promptCtrl.text.isNotEmpty)
                      IconButton(
                        key: const ValueKey('animPromptClear'),
                        icon: Icon(Icons.clear,
                            size: 18,
                            color: _cs.onSurface.withValues(alpha: 0.54)),
                        tooltip: 'Clear',
                        onPressed: () => _promptCtrl.clear(),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                            width: 36, height: 36),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // v109 — reference layout: live character count under
            // the prompt field.
            Align(
              alignment: Alignment.centerRight,
              child: ListenableBuilder(
                listenable: _promptCtrl,
                builder: (context, _) => Text(
                  '${_promptCtrl.text.length}/16384',
                  style: TextStyle(
                      fontSize: 11,
                      color: _cs.onSurface.withValues(alpha: 0.54)),
                ),
              ),
            ),
            // v88 — copyright guard: the warning shows live while a
            // blocked term is in the prompt — a copy gets his Zedge
            // account struck, so Generate stays off until it is
            // reworded. (Polish moved into the field in v120.)
            if (safetyFlags.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                key: const ValueKey('animSafetyWarning'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 16, color: Color(0xFFFFB020)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Copyright risk: "${safetyFlags.join(', ')}" — eta '
                      'brand/character thakle Zedge account-e strike '
                      'khete pare. Onno word diye lekho.',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFFFFB020)),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('animGenerateButton'),
              onPressed: canGenerate
                  ? () => widget.onGenerate(prompt, engine.selectedModelId)
                  : null,
              icon: const Icon(Icons.movie_creation_outlined, size: 18),
              label: const Text('Generate animation'),
              // v109 — reference layout: big solid call-to-action,
              // 56px tall like the Studio Generate button.
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                textStyle: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
            ),
            if (engine.status.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  if (engine.busy)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  if (engine.busy) const SizedBox(width: 8),
                  Expanded(
                    child: Text(engine.status,
                        style: TextStyle(
                            fontSize: 12,
                            color: engine.phase == AnimationPhase.error
                                ? const Color(0xFFF87171)
                                : _cs.onSurface.withValues(alpha: 0.7))),
                  ),
                  // v151 — stop a running job (frees Generate at once
                  // and drops the job on the driver side).
                  if (engine.busy)
                    TextButton(
                      key: const ValueKey('animCancelButton'),
                      onPressed: () => engine.cancelJob(),
                      child: const Text('Cancel'),
                    ),
                ],
              ),
            ],
            // v140 — error log: the last backend failures, so he can
            // see WHAT went wrong and report it. Only when non-empty.
            if (engine.errorLog.isNotEmpty) ...[
              const SizedBox(height: 10),
              _errorLogCard(),
            ],
            if (!widget.signedIn) ...[
              const SizedBox(height: 8),
              const Text(
                  'Age Login tab theke Gemini-te sign in koro — tarpor animation banbe.',
                  style: TextStyle(fontSize: 12, color: Color(0xFFFBBF24))),
            ],
            // v153 — video generation runs on Android (headless
            // Gecko driver) and Windows (headless Chrome driver).
            // Only platforms with no driver at all still see this.
            if (!isAndroid &&
                defaultTargetPlatform != TargetPlatform.windows) ...[
              const SizedBox(height: 8),
              Text(
                  'Video generation ekhon Android / Windows app-e.',
                  style: TextStyle(fontSize: 12, color: _cs.onSurface.withValues(alpha: 0.54))),
            ],
          ],
        ),
      ),
    );
  }

  // v140 — error log card: the last backend failures (time + step
  // + detail), newest last, max 20. Shown only when the log is
  // non-empty; Clear empties it.
  Widget _errorLogCard() {
    final engine = widget.engine;
    return Container(
      key: const ValueKey('animErrorLog'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: const Color(0xFFF87171).withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bug_report_outlined,
                  size: 16, color: Color(0xFFF87171)),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('Error log',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              ),
              InkWell(
                key: const ValueKey('animErrorLogClear'),
                onTap: () => engine.clearErrorLog(),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Text('Clear',
                      style: TextStyle(
                          fontSize: 12, color: Color(0xFFF87171))),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final line in engine.errorLog)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(line,
                  style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: _cs.onSurface.withValues(alpha: 0.75))),
            ),
        ],
      ),
    );
  }

  /// v120 — Settings live in their own card (Studio-clean: one
  /// job per card), so the prompt card is just the prompt +
  /// Generate. Same controls, same keys, tighter gaps.
  Widget _settingsCard() {
    final engine = widget.engine;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: _cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: _cs.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(Icons.tune_outlined,
                      color: _cs.primary, size: 17),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Settings',
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: _cs.onSurface)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Model picker (his Gemini app's picker: Auto / Everyday
            // help — Hydrogen / Deeper analysis — Neon / Code &
            // complex work — Carbon, locked). Neon is the default.
            Row(
              children: [
                SizedBox(
                  width: 60,
                  child: Text('Model',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: _cs.onSurfaceVariant)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: _cs.surfaceContainer,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _cs.outlineVariant),
                    ),
                    child: DropdownButton<AnimationModel>(
                      key: const ValueKey('animModelPicker'),
                      value: animationModelById(engine.selectedModelId),
                      isExpanded: true,
                      isDense: true,
                      underline: const SizedBox.shrink(),
                      dropdownColor: _cs.surfaceContainer,
                      icon: Icon(Icons.keyboard_arrow_down,
                          color: _cs.onSurface.withValues(alpha: 0.54)),
                      items: [
                        for (final m in kAnimationModels)
                          DropdownMenuItem<AnimationModel>(
                            value: m,
                            enabled: !m.locked,
                            // One line per item ("Deeper analysis — 4
                            // Neon"): the two-line label+subtitle
                            // column overflowed the 48px menu item.
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${m.label} — ${m.subtitle}',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: m.locked
                                            ? _cs.onSurface.withValues(alpha: 0.38)
                                            : _cs.onSurface),
                                  ),
                                ),
                                if (m.locked)
                                  Icon(Icons.lock_outline,
                                      size: 16, color: _cs.onSurface.withValues(alpha: 0.38)),
                              ],
                            ),
                          ),
                      ],
                      onChanged: (m) {
                        if (m == null) return;
                        engine.setModelId(m.id);
                      },
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // v88 — Style / mood picker: the mood phrase the prompt
            // builder appends (Cinematic default — his MH Motion
            // house standard).
            Row(
              children: [
                SizedBox(
                  width: 60,
                  child: Text('Style',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: _cs.onSurfaceVariant)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: _cs.surfaceContainer,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _cs.outlineVariant),
                    ),
                    child: DropdownButton<AnimationMood>(
                      key: const ValueKey('animStylePicker'),
                      value: animationMoodById(engine.selectedStyleId),
                      isExpanded: true,
                      isDense: true,
                      underline: const SizedBox.shrink(),
                      dropdownColor: _cs.surfaceContainer,
                      icon: Icon(Icons.keyboard_arrow_down,
                          color: _cs.onSurface.withValues(alpha: 0.54)),
                      items: [
                        for (final s in kAnimationMoods)
                          DropdownMenuItem<AnimationMood>(
                            value: s,
                            child: Text(
                              s.label,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: _cs.onSurface),
                            ),
                          ),
                      ],
                      onChanged: (s) {
                        if (s == null) return;
                        engine.setStyleId(s.id);
                      },
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // v88 — Clip length. Honest limit: the video tool
            // decides the real length (his Neon clips came out
            // ~6s); the choice is the request written into the
            // prompt, and his 10s standard is the default.
            // Wrap, not Row: the Ahem test font makes the three
            // chips ~44px too wide for a Row — Wrap drops one to
            // a second line instead of erroring, while real
            // Roboto phones keep one row.
            Row(
              children: [
                SizedBox(
                  width: 60,
                  child: Text('Duration',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: _cs.onSurfaceVariant)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final seconds in kAnimationDurations)
                        ChoiceChip(
                          key: ValueKey('animDuration-$seconds'),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          label: Text('${seconds}s'),
                          selected: engine.selectedDurationSec == seconds,
                          onSelected: (_) => engine.setDurationSec(seconds),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // v88 — Seamless loop: ON = the clip loops without a
            // cut (today's behaviour); OFF = the loop phrase is
            // left out of the prompt.
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Seamless loop',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: _cs.onSurface.withValues(alpha: 0.7))),
                      Text('Loop-e cholbe, kono cut thakbe na',
                          style: TextStyle(
                              fontSize: 11, color: _cs.onSurface.withValues(alpha: 0.54))),
                    ],
                  ),
                ),
                Switch(
                  key: const ValueKey('animSeamlessSwitch'),
                  value: engine.seamlessMode,
                  onChanged: (v) => engine.setSeamless(v),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Task mode (his pick from the Gemini app's Chat/Task
            // toggle): ON = the video is made in the background and
            // he is told when it is ready.
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Task mode',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: _cs.onSurface.withValues(alpha: 0.7))),
                      Text('Background-e banbe, sesh hole janabe',
                          style: TextStyle(
                              fontSize: 11, color: _cs.onSurface.withValues(alpha: 0.54))),
                    ],
                  ),
                ),
                Switch(
                  key: const ValueKey('animTaskSwitch'),
                  value: engine.taskMode,
                  onChanged: (v) => engine.setTaskMode(v),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _galleryHeader() {
    final engine = widget.engine;
    return Row(
      children: [
        Icon(Icons.video_library_outlined,
            color: _cs.primary, size: 22),
        const SizedBox(width: 8),
        // The title flexes (ellipsis) so the header never overflows
        // a narrow phone — the count chip + export button keep
        // their size.
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text('Animations',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: _cs.onSurface)),
              ),
              const SizedBox(width: 8),
              // v140 — the pill flexes too: in the test font it is
              // 120px wide and overflowed the 100px inner Row by
              // 28px (v86 tests); on a narrow phone it now shrinks
              // to '… videos' instead of breaking the header.
              Flexible(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _cs.outlineVariant),
                  ),
                  child: Text('${engine.videos.length} videos',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 12, color: _cs.onSurface.withValues(alpha: 0.7))),
                ),
              ),
            ],
          ),
        ),
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _cs.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Fewer columns (larger cards)',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                icon: const Icon(Icons.remove_outlined, size: 17),
                onPressed: _gridCols > 1
                    ? () => setState(() => _gridCols--)
                    : null,
              ),
              SizedBox(
                width: 20,
                child: Center(
                  child: Text(
                    '$_gridCols',
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: _cs.onSurface),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'More columns (smaller cards)',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                icon: const Icon(Icons.add_outlined, size: 17),
                onPressed: _gridCols < 6
                    ? () => setState(() => _gridCols++)
                    : null,
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          key: const ValueKey('animUploadAll'),
          icon: Icon(Icons.cloud_upload_outlined,
              color: _cs.onSurface.withValues(alpha: 0.7)),
          tooltip: 'Upload all to Panel',
          onPressed:
              engine.videos.isEmpty ? null : widget.onUploadAllToPanel,
        ),
        IconButton(
          key: const ValueKey('animExportZip'),
          icon: Icon(Icons.archive_outlined, color: _cs.onSurface.withValues(alpha: 0.7)),
          tooltip: 'Export ZIP',
          onPressed:
              engine.videos.isEmpty ? null : widget.onExportZip,
        ),
      ],
    );
  }

  Widget _processingVideoCard() {
    final engine = widget.engine;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: _cs.primary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: _cs.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Processing animation…',
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: _cs.onSurface),
                      ),
                      Text(
                        engine.status.isEmpty
                            ? 'Video banacche…'
                            : engine.status,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: _cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (engine.currentPrompt.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                engine.currentPrompt,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: _cs.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: const LinearProgressIndicator(minHeight: 4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _compactVideoTile(AnimationVideo v) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // v140 — same play key as the list card, so tap-to-play is
        // reachable (and testable) in grid mode too.
        key: ValueKey('animPlay-${v.id}'),
        onTap: () => widget.onPlay(v),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _cs.primary.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.play_arrow_rounded,
                    color: _cs.primary, size: 28),
              ),
              const SizedBox(height: 8),
              Text(
                v.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: _cs.onSurface),
              ),
              const SizedBox(height: 4),
              // v140 — the tile's spec line matches the list card:
              // spec + style + model, plus the queued account when
              // uploaded (the v87 test reads 'Queued on <account>'
              // off it). v154 — the style was never shown before.
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: v.cardLine),
                    if (v.isUploaded)
                      TextSpan(
                        text: ' · Queued on ${v.uploadedAccount}',
                        style: TextStyle(color: _cs.primary),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: _cs.onSurfaceVariant),
              ),
              // v157 — the panel section this video will upload
              // to (its own choice, Charging Animation by
              // default). Read-only here — change it on the list
              // card (1 column). One line, so the tile never grows.
              Text(
                'Panel: ${videoPanelTypeLabel(v.panelType)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: _cs.onSurfaceVariant),
              ),
              // v154 — honest fps note: the clip came back under
              // 60fps, say so on the card (the cardLine already
              // shows the real fps number).
              if (v.fpsNote.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  v.fpsNote,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 10, color: Color(0xFFFFB020)),
                ),
              ],
              // v159 second pass — over-target file: Gemini gave a
              // bigger file than the 10 MB asked for — say so on
              // the card instead of silently accepting it. The
              // video itself stays usable.
              if (v.sizeNote.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  v.sizeNote,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 10, color: Color(0xFFFFB020)),
                ),
              ],
              // v156 — metadata attached to the tile too (compact):
              // the grid is the default view, so a video's metadata
              // must be visible there as well, not only on the
              // list card.
              if (v.hasMetadata) ...[
                const SizedBox(height: 4),
                _videoMetaBlock(v, compact: true),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _galleryBody() {
    final engine = widget.engine;
    if (engine.videos.isEmpty && !engine.busy) {
      return Column(
        children: [
          const SizedBox(height: 32),
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: _cs.primary.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(Icons.movie_outlined,
                color: _cs.primary, size: 40),
          ),
          const SizedBox(height: 16),
          Text('No animations yet',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: _cs.onSurface)),
          const SizedBox(height: 6),
          Text('Gemini-te prompt dao, video banaw.',
              style: TextStyle(fontSize: 13, color: _cs.onSurface.withValues(alpha: 0.54)),
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('animCreateFirst'),
            onPressed: _scrollToTop,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Create your first animation'),
          ),
          const SizedBox(height: 32),
        ],
      );
    }
    if (_gridCols == 1) {
      return Column(
        children: [
          if (engine.busy) _processingVideoCard(),
          for (final v in engine.videos) _videoCard(v),
        ],
      );
    }
    final total = engine.videos.length + (engine.busy ? 1 : 0);
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final count = _gridCols.clamp(1, 6);
        final cellW = (constraints.maxWidth - (count - 1) * 10) / count;
        // v156 — the compact tile carries the metadata block now
        // (description up to 2 lines + tag row, ~60px), so the
        // tile must grow by that much when any video has metadata —
        // otherwise the fixed imgH overflows by ~13px on a phone.
        // The column centres the content, so tiles without metadata
        // just get a little breathing room.
        final hasMeta = engine.videos.any((v) => v.hasMetadata);
        final imgH = cellW / 0.60 + (hasMeta ? 64 : 0);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: count,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: cellW / (imgH + 42),
          ),
          itemCount: total,
          itemBuilder: (ctx, i) {
            if (engine.busy && i == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: cellW,
                    height: imgH,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _cs.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: _cs.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    engine.status.isEmpty ? 'Processing…' : engine.status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: _cs.onSurface),
                  ),
                ],
              );
            }
            final v = engine.videos[engine.busy ? i - 1 : i];
            final busy = widget.engine.busyVideoId == v.id;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: cellW,
                  height: imgH,
                  child: _compactVideoTile(v),
                ),
                const SizedBox(height: 6),
                // v140 — the tile already shows the title, so the
                // caption below it was a duplicate (v87 tests found
                // the title twice). The row below the tile is now
                // the per-video actions: in grid mode Metadata +
                // Upload were unreachable (their keys lived only in
                // the list card). Same keys + handlers as _videoCard.
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _animIconAction(
                      key: ValueKey('animMeta-${v.id}'),
                      size: 32,
                      icon: v.hasMetadata
                          ? Icons.auto_awesome
                          : Icons.auto_awesome_outlined,
                      tooltip:
                          v.hasMetadata ? 'Metadata' : 'AI Metadata',
                      color: v.hasMetadata
                          ? _cs.primary
                          : _cs.onSurface.withValues(alpha: 0.7),
                      onPressed:
                          busy ? null : () => _onMetadataTap(v),
                    ),
                    _animIconAction(
                      key: ValueKey('animUpload-${v.id}'),
                      size: 32,
                      icon: v.isUploaded
                          ? Icons.cloud_done_outlined
                          : Icons.cloud_upload_outlined,
                      tooltip: v.isUploaded ? 'Queued' : 'Upload',
                      color: v.isUploaded
                          ? _cs.primary
                          : _cs.onSurface.withValues(alpha: 0.7),
                      onPressed: busy
                          ? null
                          : () => widget.onUploadToPanel(v),
                    ),
                    // v154 — retry at 60fps, only for a clip whose
                    // measured fps came back under 60 (quota: the
                    // tap asks first — see _confirmRetry60Fps).
                    if (_needsRetry60Fps(v))
                      _animIconAction(
                        key: ValueKey('animRetry60-${v.id}'),
                        size: 32,
                        icon: Icons.sixty_fps,
                        tooltip: 'Retry 60fps',
                        color: const Color(0xFFFFB020),
                        onPressed:
                            busy ? null : () => _confirmRetry60Fps(v),
                      ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// v154 — "60fps-e abar banaw": only for a clip whose MEASURED
  /// fps came back under 60. A regeneration spends video quota, so
  /// the tap asks first instead of silently spending it.
  bool get _canRetry60Fps => widget.onRetry60Fps != null;

  bool _needsRetry60Fps(AnimationVideo v) =>
      _canRetry60Fps && v.fps > 0 && v.fps < 60;

  Future<void> _confirmRetry60Fps(AnimationVideo v) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('60fps-e abar banabe?'),
        content: Text(
          'Ei video-ta ${v.fps}fps-e esheche. Abar banale prompt-e '
          '60fps jore kore bola hobe — kintu Gemini 60fps dibei, '
          'eta guarantee na. Eta ekta notun generation, video quota khabe.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Na, thak'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Banaw'),
          ),
        ],
      ),
    );
    if (go == true) await widget.onRetry60Fps!(v);
  }

  /// v87 — Metadata tap: when the video already has AI metadata,
  /// show it; otherwise generate it first, then show the dialog
  /// with the fresh metadata.
  Future<void> _onMetadataTap(AnimationVideo v) async {
    if (v.hasMetadata) {
      _showMetadataDialog(v);
      return;
    }
    await widget.onMetadata(v);
    if (!mounted) return;
    AnimationVideo? fresh;
    for (final x in widget.engine.videos) {
      if (x.id == v.id) fresh = x;
    }
    if (fresh != null && fresh.hasMetadata) _showMetadataDialog(fresh);
  }

  void _showMetadataDialog(AnimationVideo v) {
    final meta = v.metadata!;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cs.surface,
        title: Text(meta.title.isEmpty ? v.title : meta.title,
            style: TextStyle(color: _cs.onSurface, fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (meta.category.isNotEmpty)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _cs.primary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(meta.category,
                      style: TextStyle(
                          fontSize: 12, color: _cs.primary)),
                ),
              if (meta.description.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(meta.description,
                    style: TextStyle(
                        fontSize: 13, color: _cs.onSurface.withValues(alpha: 0.7))),
              ],
              if (meta.tags.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in meta.tags)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: _cs.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(12),
                          border:
                              Border.all(color: _cs.outlineVariant),
                        ),
                        child: Text(t,
                            style: TextStyle(
                                fontSize: 12, color: _cs.onSurface.withValues(alpha: 0.7))),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Close',
                style: TextStyle(color: _cs.primary)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await widget.onMetadata(v);
            },
            child: Text('Regenerate',
                style: TextStyle(color: _cs.primary)),
          ),
        ],
      ),
    );
  }

  Widget _videoCard(AnimationVideo v) {
    // v120 — one compact row (~64px, was ~120px): the play tile
    // taps to play, title + spec share one column, and Metadata /
    // Upload / Delete are icon-only with tooltips. Labeled buttons
    // did not fit beside the title (v87); 36px icons do.
    final busy = widget.engine.busyVideoId == v.id;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: _cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
            InkWell(
              key: ValueKey('animPlay-${v.id}'),
              onTap: () => widget.onPlay(v),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _cs.primary.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.play_circle_outline,
                    color: _cs.primary, size: 22),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(v.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: _cs.onSurface)),
                  const SizedBox(height: 2),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: v.cardLine),
                        if (v.isUploaded)
                          TextSpan(
                            text: ' · Queued on ${v.uploadedAccount}',
                            style: TextStyle(color: _cs.primary),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: _cs.onSurface.withValues(alpha: 0.54)),
                  ),
                  // v154 — honest fps note under the spec line.
                  if (v.fpsNote.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      v.fpsNote,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFFFFB020)),
                    ),
                  ],
                  // v159 second pass — over-target file: Gemini gave
                  // a bigger file than the 10 MB asked for — say so
                  // on the card instead of silently accepting it.
                  // The video itself stays usable.
                  if (v.sizeNote.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      v.sizeNote,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFFFFB020)),
                    ),
                  ],
                ],
              ),
            ),
            _animIconAction(
              key: ValueKey('animMeta-${v.id}'),
              icon: v.hasMetadata
                  ? Icons.auto_awesome
                  : Icons.auto_awesome_outlined,
              tooltip: v.hasMetadata ? 'Metadata' : 'AI Metadata',
              color: v.hasMetadata
                  ? _cs.primary
                  : _cs.onSurface.withValues(alpha: 0.7),
              onPressed: busy ? null : () => _onMetadataTap(v),
            ),
            _animIconAction(
              key: ValueKey('animUpload-${v.id}'),
              icon: v.isUploaded
                  ? Icons.cloud_done_outlined
                  : Icons.cloud_upload_outlined,
              tooltip: v.isUploaded ? 'Queued' : 'Upload',
              color: v.isUploaded
                  ? _cs.primary
                  : _cs.onSurface.withValues(alpha: 0.7),
              onPressed: busy ? null : () => widget.onUploadToPanel(v),
            ),
            // v154 — retry at 60fps (see _confirmRetry60Fps).
            if (_needsRetry60Fps(v))
              _animIconAction(
                key: ValueKey('animRetry60-${v.id}'),
                icon: Icons.sixty_fps,
                tooltip: 'Retry 60fps',
                color: const Color(0xFFFFB020),
                onPressed: busy ? null : () => _confirmRetry60Fps(v),
              ),
            _animIconAction(
              key: ValueKey('animDelete-${v.id}'),
              icon: Icons.delete_outline,
              tooltip: 'Delete',
              color: _cs.onSurface.withValues(alpha: 0.54),
              onPressed: () => widget.onDelete(v),
            ),
              ],
            ),
            // v157 — per-video panel section (user decision
            // 2026-11-22): the panel files by the record's
            // contentType, so the card picks it before upload —
            // Charging Animation by default. Locked once the
            // video is queued (changing it after upload would
            // not re-file the record already in Firebase).
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('Panel:',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _cs.onSurface.withValues(alpha: 0.7))),
                  _panelTypeChip(v, kVideoPanelTypeCharging, busy),
                  _panelTypeChip(v, kVideoPanelTypeLive, busy),
                ],
              ),
            ),
            // v156 — the video's AI metadata attached to its card
            // (see _videoMetaBlock): image cards show metadata with
            // the image, video cards only hid it behind the
            // sparkle-icon dialog. The card stays compact when no
            // metadata was generated yet.
            if (v.hasMetadata) _videoMetaBlock(v),
          ],
        ),
      ),
    );
  }

  /// v157 — one panel-type chip on the video card. Tapping
  /// persists the choice on the video (engine.setVideoPanelType)
  /// so the next upload — single or Upload-all — sends it as the
  /// record's contentType, which is the section the panel files
  /// it under. Disabled once the video is queued or busy.
  Widget _panelTypeChip(AnimationVideo v, String type, bool busy) {
    final selected = v.panelType == type;
    final locked = busy || v.isUploaded;
    return ChoiceChip(
      key: ValueKey(
          'animPanelType-${type == kVideoPanelTypeLive ? 'live' : 'charging'}-${v.id}'),
      label: Text(videoPanelTypeLabel(type),
          style: const TextStyle(fontSize: 11)),
      selected: selected,
      onSelected: locked
          ? null
          : (_) => widget.engine.setVideoPanelType(v, type),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6),
    );
  }

  /// v156 — the video's AI metadata attached to its card, the same
  /// way image cards show metadata with the image: category pill +
  /// description + tag chips. [compact] is the grid tile (centred,
  /// smaller, tags in one scrollable row); the list card gets the
  /// full mirrored block (see [_videoMetaCard]). Only called when
  /// [v.hasMetadata] is true.
  Widget _videoMetaBlock(AnimationVideo v, {bool compact = false}) {
    final meta = v.metadata!;
    if (!compact) return _videoMetaCard(v, meta);
    final descStyle = TextStyle(
        fontSize: compact ? 10 : 12,
        color: _cs.onSurface.withValues(alpha: 0.7));
    final tagStyle = TextStyle(
        fontSize: compact ? 9 : 11,
        color: _cs.onSurface.withValues(alpha: 0.7));
    Widget tagChip(String t) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: _cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _cs.outlineVariant),
          ),
          child: Text(t, style: tagStyle),
        );
    final tags = meta.tags.isEmpty
        ? const SizedBox.shrink()
        : compact
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < meta.tags.length; i++) ...[
                      if (i > 0) const SizedBox(width: 6),
                      tagChip(meta.tags[i]),
                    ],
                  ],
                ),
              )
            : Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final t in meta.tags) tagChip(t)],
              );
    return Container(
      key: ValueKey('animMetaBlock-${v.id}'),
      width: double.infinity,
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment:
            compact ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (meta.category.isNotEmpty && !compact)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _cs.primary.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(meta.category,
                  style: TextStyle(fontSize: 12, color: _cs.primary)),
            ),
          if (meta.description.isNotEmpty) ...[
            if (meta.category.isNotEmpty && !compact)
              const SizedBox(height: 6),
            Text(
              meta.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: compact ? TextAlign.center : TextAlign.start,
              style: descStyle,
            ),
          ],
          if (meta.tags.isNotEmpty) ...[
            const SizedBox(height: 6),
            tags,
          ],
        ],
      ),
    );
  }

  /// v159 second pass — the LIST-card metadata block mirrors the
  /// IMAGE card (`_metaCard` in main.dart) exactly: same container,
  /// title row (the video's AI title + the same filled purple
  /// uppercase pill + sparkle button), same source line, same
  /// description sizing/behaviour, same tags behaviour, same
  /// 'Aro dekho' toggle with the same show rule. Styling values
  /// come from lib/meta_card_style.dart (shared with `_metaCard`)
  /// so the two cards cannot drift apart again. Expanded state is
  /// PER-VIDEO (`_expandedVideoMeta`) — the image card's single
  /// shared bool cannot be reused across a list. The sparkle
  /// regenerates the video's metadata via [_onMetadataTap] (the
  /// injected `widget.onMetadata`); videos also come from the
  /// signed-in Gemini web session, so the source line is the same
  /// hardcoded 'gemini-web (cookie)' (SetMetadata has no source
  /// field). The compact grid-tile variant stays compact (see
  /// [_videoMetaBlock]).
  Widget _videoMetaCard(AnimationVideo v, SetMetadata meta) {
    final expanded = _expandedVideoMeta.contains(v.id);
    final showToggle = metaShowsExpandToggle(
        description: meta.description, tagCount: meta.tags.length);
    return Container(
      key: ValueKey('animMetaBlock-${v.id}'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: _cs.surfaceContainer,
        borderRadius: BorderRadius.circular(kMetaCardRadius),
      ),
      padding: kMetaCardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(meta.title,
                    style: const TextStyle(
                        fontSize: 19, fontWeight: FontWeight.w700)),
              ),
              if (meta.category.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: kMetaCategoryPillColor,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(meta.category.toUpperCase(),
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: Colors.white)),
                ),
              ],
              IconButton(
                tooltip: 'Rewrite with AI',
                visualDensity: VisualDensity.compact,
                onPressed: () => _onMetadataTap(v),
                icon: Icon(Icons.auto_awesome,
                    size: 20, color: _cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('gemini-web (cookie)',
              style: TextStyle(
                  fontSize: 13.5, color: _cs.onSurfaceVariant)),
          if (meta.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(meta.description,
                maxLines: expanded ? null : 2,
                overflow:
                    expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 15,
                    height: 1.35,
                    color: _cs.onSurface)),
          ],
          if (meta.tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            if (expanded)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final tag in meta.tags) metaTagChip(tag)],
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < meta.tags.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      metaTagChip(meta.tags[i]),
                    ],
                  ],
                ),
              ),
          ],
          if (showToggle) ...[
            const SizedBox(height: 8),
            GestureDetector(
              key: ValueKey('animMetaExpandToggle-${v.id}'),
              onTap: () => setState(() {
                if (expanded) {
                  _expandedVideoMeta.remove(v.id);
                } else {
                  _expandedVideoMeta.add(v.id);
                }
              }),
              behavior: HitTestBehavior.opaque,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(expanded ? 'Kom dekho' : 'Aro dekho',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _cs.primary)),
                  const SizedBox(width: 2),
                  Icon(
                      expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 16,
                      color: _cs.primary),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// One compact 36px icon action for the video card (v120):
  /// IconButton's 48px minimum would not fit three of them beside
  /// the title, so the tap target is an explicit 36px box.
  /// v154 — [size] is the tap box (default 36). The grid row passes
  /// 32: at 3 columns on a 360dp phone a cell is ~105px wide and
  /// three 36px actions (108px) overflow it by ~3px — live layout
  /// bug the v154 retry button exposed (it is the 3rd action).
  Widget _animIconAction({
    required Key key,
    required IconData icon,
    required String tooltip,
    required Color color,
    required VoidCallback? onPressed,
    double size = 36,
  }) {
    return SizedBox(
      width: size,
      height: size,
      child: IconButton(
        key: key,
        icon: Icon(icon, size: 18, color: color),
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tightFor(width: size, height: size),
      ),
    );
  }

  Widget _galleryPanel() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _galleryHeader(),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(child: _galleryBody()),
          ),
        ],
      ),
    );
  }

  Widget _galleryInline() {
    return Column(
      key: _galleryKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _galleryHeader(),
        const SizedBox(height: 8),
        _galleryBody(),
      ],
    );
  }
}
