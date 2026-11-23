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
import 'package:image/image.dart' as img;

import 'animation_engine.dart';
import 'animation_models.dart';
import 'meta_card_style.dart';
import 'models.dart';
import 'video_cover.dart';
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
    this.onBulkGenerate,
  });

  final AnimationEngine engine;
  final bool signedIn;
  final bool wide;
  final Future<void> Function(String prompt, String modelId) onGenerate;
  // v163 — bulk: when the prompt box holds several lines, Generate
  // runs one animation per line (AnimationEngine.startBulk). Null
  // = run on the engine directly (tests / old call sites).
  final Future<void> Function(List<String> prompts, String modelId)?
      onBulkGenerate;
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
  // v166 — manual cover-frame picker: one video id in here = its
  // picker row is open. Candidates are captured on demand (never
  // per card) and downscaled for display once, so opening the
  // picker never re-captures or re-decodes.
  final Set<String> _coverPickerOpen = {};
  final Map<String, List<_CoverThumb>> _coverThumbs = {};
  final Map<String, bool> _coverLoading = {};
  final Map<String, String?> _coverError = {};
  // v167 — all-dark note under the picker header: the frames
  // are still shown (and still pickable), but the row says why
  // they are all dark, with the per-path diagnostic.
  final Map<String, String?> _coverNote = {};
  // v169 — the card's own preview: right after a video is
  // generated (before any panel upload gives it a thumbUrl) the
  // preview pane shows the video's real 3-4s frame, captured
  // from the local file once per video and kept here. Captures
  // run one at a time so a batch of new videos never decodes in
  // parallel.
  final Map<String, Uint8List> _localPreview = {};
  final Set<String> _localPreviewRequested = {};
  Future<void> _localPreviewQueue = Future<void>.value();


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

  /// v163 — Generate from the SAME prompt box: one line = one
  /// animation through the existing [onGenerate] (exactly as
  /// today); several lines = one animation per line through
  /// [onBulkGenerate] (or the engine directly when no callback
  /// was passed). The box text is NOT cleared here — it stays
  /// until the user taps Clear, so a failed line can be re-run.
  Future<void> _onGenerateTap() async {
    final lines = parseBulkAnimationPrompts(_promptCtrl.text);
    if (lines.isEmpty) return;
    if (lines.length == 1) {
      await widget.onGenerate(lines.first, widget.engine.selectedModelId);
      return;
    }
    final cb = widget.onBulkGenerate;
    if (cb != null) {
      await cb(lines, widget.engine.selectedModelId);
    } else {
      await widget.engine.startBulk(
        prompts: lines,
        modelId: widget.engine.selectedModelId,
        signedIn: widget.signedIn,
      );
    }
  }

  /// v163 — the bulk run's per-line list: status icon + prompt +
  /// failure/skip reason, with a Stop button while the queue runs.
  Widget _bulkItemList() {
    final engine = widget.engine;
    return Container(
      key: const ValueKey('animBulkList'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.queue_outlined, size: 16, color: _cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Bulk — ${engine.bulkItems.length} line',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _cs.onSurface),
                ),
              ),
              if (engine.bulkRunning)
                InkWell(
                  key: const ValueKey('animBulkStopButton'),
                  onTap: () => engine.cancelBulk(),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Text('Stop',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFF87171))),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          for (final item in engine.bulkItems)
            Padding(
              key: ValueKey('animBulkItem-${item.id}'),
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _bulkStatusIcon(item.status),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.prompt,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: _cs.onSurface),
                        ),
                        if (item.note.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              item.note,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: item.status ==
                                          BulkAnimationStatus.failed
                                      ? const Color(0xFFF87171)
                                      : const Color(0xFFFFB020)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _bulkStatusIcon(BulkAnimationStatus status) {
    switch (status) {
      case BulkAnimationStatus.queued:
        return Icon(Icons.schedule_outlined,
            size: 16, color: _cs.onSurface.withValues(alpha: 0.54));
      case BulkAnimationStatus.running:
        return SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: _cs.primary),
        );
      case BulkAnimationStatus.done:
        return const Icon(Icons.check_circle_outline,
            size: 16, color: Colors.green);
      case BulkAnimationStatus.failed:
        return const Icon(Icons.error_outline,
            size: 16, color: Color(0xFFF87171));
      case BulkAnimationStatus.skipped:
        return const Icon(Icons.block_outlined,
            size: 16, color: Color(0xFFFFB020));
    }
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
    // v163 — BULK in the SAME box (user correction 2026-11-22:
    // "আলাদা করে পোস্ট বক্স বানানোর দরকার নাই — ওই আগের যে বক্স
    // আছে ওটাতেই রাখি সিস্টেম"): when the box holds several lines,
    // each non-empty line is one prompt and Generate runs one
    // animation per line, in order (see startBulk). One line = one
    // animation, exactly as today. A copyright-risk line does NOT
    // disable Generate for the rest — it is skipped with a note
    // and the clean lines still run; Generate stays off only when
    // NO line is runnable.
    final bulkLines = parseBulkAnimationPrompts(_promptCtrl.text);
    final runnableLines = bulkLines
        .where((l) => checkAnimationPromptSafety(l).isEmpty)
        .toList();
    final safetyFlags = <String>{
      for (final l in bulkLines) ...checkAnimationPromptSafety(l),
    }.toList();
    final canGenerate = runnableLines.isNotEmpty &&
        !engine.busy &&
        !engine.bulkRunning &&
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
                        // v163 — Clear empties the box AND the bulk
                        // run's per-line list (fresh start); the
                        // box text itself is kept after Generate
                        // until this tap, so a failed line can be
                        // re-run by generating again.
                        onPressed: () {
                          _promptCtrl.clear();
                          widget.engine.clearBulkItems();
                        },
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
            Row(
              children: [
                // v163 — multi-line hint: when the box holds several
                // prompts, say so — each line becomes one animation.
                if (bulkLines.length > 1)
                  Expanded(
                    child: Text(
                      '${bulkLines.length} line — prottek line ekta '
                      'animation banabe, ekta sesh hole porer-ta.',
                      style: TextStyle(
                          fontSize: 11,
                          color: _cs.primary),
                    ),
                  )
                else
                  const Spacer(),
                ListenableBuilder(
                  listenable: _promptCtrl,
                  builder: (context, _) => Text(
                    '${_promptCtrl.text.length}/16384',
                    style: TextStyle(
                        fontSize: 11,
                        color: _cs.onSurface.withValues(alpha: 0.54)),
                  ),
                ),
              ],
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
              onPressed: canGenerate ? _onGenerateTap : null,
              icon: const Icon(Icons.movie_creation_outlined, size: 18),
              // v163 — the button says how many animations the box
              // will make: one line = "Generate animation" as
              // before, several lines = "Generate N animations".
              label: Text(bulkLines.length > 1
                  ? 'Generate ${bulkLines.length} animations'
                  : 'Generate animation'),
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
            // v163 — bulk per-line status (only while a bulk run's
            // lines exist): each line shows queued → running →
            // done/failed/skipped with its reason, so he can see
            // which line is generating and which one failed.
            if (engine.bulkItems.isNotEmpty) ...[
              const SizedBox(height: 10),
              _bulkItemList(),
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
    // v161 — TWO-PART card (user order 2026-11-22: the old card
    // "কেমন বিচ্ছিরি হয়ে গেছে"): left = ONLY the video preview
    // (small 9:16 pane, tap opens the device preview — no text,
    // no note overlaid on the frame, per the v159 rule), right =
    // the metadata, neatly arranged in the image-card-style block
    // (AI title + pill + source + description + tags) or, when
    // there is none yet, the prompt title + spec + metadata state.
    // Below the split: the spec line (when metadata is shown),
    // the Panel chips (v157) and the action icons — nothing
    // dropped, only rearranged. The grid tile is unchanged (a
    // 3-column tile is too narrow for a split).
    final busy = widget.engine.busyVideoId == v.id;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: _cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _videoPreviewPane(v),
                const SizedBox(width: 12),
                Expanded(
                  child: v.hasMetadata
                      ? _videoMetaBlock(v)
                      : _videoNoMetaColumn(v, busy),
                ),
              ],
            ),
            // v166 — manual cover picker (user order 2026-11-23):
            // choose the cover frame instead of trusting the auto
            // capture (which kept returning black frames).
            if (_coverPickerOpen.contains(v.id)) _coverPickerRow(v),
            // The image-card block carries no spec line, so the
            // real spec (duration · size · fps · style · model)
            // sits under the split instead of inside the metadata.
            if (v.hasMetadata) ...[
              const SizedBox(height: 10),
              _videoSpecBlock(v),
            ],
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
            // Actions moved under the split (they sat beside the
            // title before): Metadata / Upload / Retry 60fps /
            // Delete, same keys + handlers as before.
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // v166 — manual cover frame picker (user order
                  // 2026-11-23): the auto capture kept returning
                  // black frames, so the user picks the frame
                  // himself. Primary colour when a pick exists.
                  _animIconAction(
                    key: ValueKey('animCover-${v.id}'),
                    icon: v.pickedCoverTimeMs >= 0
                        ? Icons.image
                        : Icons.image_outlined,
                    tooltip: 'Cover frame',
                    color: v.pickedCoverTimeMs >= 0
                        ? _cs.primary
                        : _cs.onSurface.withValues(alpha: 0.7),
                    onPressed: busy ? null : () => _onCoverTap(v),
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
                    onPressed: busy
                        ? null
                        : () => widget.onUploadToPanel(v),
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
            ),
          ],
        ),
      ),
    );
  }

  /// v166 — Cover icon: toggles the picker row on the card.
  /// Candidates are captured on first open only (cached per
  /// video id until the app restarts).
  Future<void> _onCoverTap(AnimationVideo v) async {
    if (_coverPickerOpen.contains(v.id)) {
      setState(() => _coverPickerOpen.remove(v.id));
      return;
    }
    setState(() => _coverPickerOpen.add(v.id));
    if (!_coverThumbs.containsKey(v.id)) await _loadCoverCandidates(v);
  }

  /// v166 — captures the candidate frames for one video (panel
  /// percentage points of its duration) and downscales them for
  /// display. The full-res bytes are re-captured at upload time
  /// from the picked timestamp, so the picker never holds five
  /// 1620x2880 JPEGs in memory.
  Future<void> _loadCoverCandidates(AnimationVideo v) async {
    if (!mounted) return;
    setState(() {
      _coverLoading[v.id] = true;
      _coverError[v.id] = null;
      _coverNote[v.id] = null;
    });
    try {
      final result = await widget.engine.coverCandidates(v);
      if (!mounted) return;
      final cands = result.frames;
      if (cands.isEmpty) {
        setState(() {
          _coverLoading[v.id] = false;
          _coverError[v.id] = result.diagnostic.isEmpty
              ? 'Cover frame pelam na — video file-ta khule dekha jacche na.'
              : 'Cover frame pelam na — ${result.diagnostic}';
        });
        return;
      }
      final thumbs = <_CoverThumb>[];
      for (final c in cands) {
        thumbs.add(_CoverThumb(
            timeMs: c.timeMs,
            bytes: _coverDisplayBytes(c.bytes),
            luma: c.luma));
      }
      setState(() {
        _coverThumbs[v.id] = thumbs;
        _coverLoading[v.id] = false;
        _coverError[v.id] = null;
        // v167 — every candidate dark: the frames are still
        // shown (and still pickable — a genuinely dark video
        // can still want its brightest frame), but the row says
        // why, with the per-path diagnostic.
        _coverNote[v.id] = result.allDark
            ? 'Sob frame-i ondhokar — ${result.diagnostic}'
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _coverLoading[v.id] = false;
        _coverError[v.id] = 'Cover frame khujte giye vul holo: $e';
      });
    }
  }

  /// v166 — the user tapped a candidate: persist the pick on
  /// the video (the engine saves + sets the status line); the
  /// next panel upload captures exactly this timestamp. The
  /// setState repaints this card with the fresh video object —
  /// the engine also emits through onChanged (the app rebuilds),
  /// but the pick must repaint even when onChanged is not wired.
  Future<void> _onCoverPick(AnimationVideo v, int timeMs) async {
    await widget.engine.pickCoverFrame(v, timeMs);
    if (mounted) setState(() {});
  }

  /// Downscales a full-res candidate JPEG to a ~60x107 display
  /// thumb (the picker shows five of them; decoding five
  /// 1620x2880 JPEGs at full size on the card would be ~90 MB
  /// of pixels). Falls back to the original bytes on failure.
  Uint8List _coverDisplayBytes(Uint8List bytes) {
    try {
      final decoded = img.decodeJpg(bytes);
      if (decoded == null) return bytes;
      final small = img.copyResize(decoded, width: 60, height: 107);
      return Uint8List.fromList(img.encodeJpg(small, quality: 70));
    } catch (_) {
      return bytes;
    }
  }

  /// v166 — the manual cover picker row (under the split, above
  /// the spec line): the candidate frames for this video, each
  /// with its timestamp; tapping one picks it (primary border +
  /// check), 'Auto' clears the pick. Dark candidates are dimmed
  /// so the user can tell a black frame before picking it.
  Widget _coverPickerRow(AnimationVideo v) {
    final thumbs = _coverThumbs[v.id];
    final loading = _coverLoading[v.id] == true;
    final error = _coverError[v.id];
    final note = _coverNote[v.id];
    final picked = v.pickedCoverTimeMs;
    return Container(
      key: ValueKey('coverPicker-${v.id}'),
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.image_outlined, size: 16, color: _cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  picked >= 0
                      ? 'Cover frame: ${(picked / 1000).toStringAsFixed(1)}s beche neoa'
                      : 'Cover frame beche nao',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _cs.onSurface),
                ),
              ),
              if (picked >= 0)
                TextButton(
                  key: ValueKey('coverAuto-${v.id}'),
                  onPressed: () => _onCoverPick(v, -1),
                  child: const Text('Auto', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(note,
                  style: TextStyle(fontSize: 12, color: _cs.error)),
            ),
          if (loading)
            Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: _cs.primary),
                ),
                const SizedBox(width: 8),
                Text('Cover frame khujchi…',
                    style: TextStyle(
                        fontSize: 12,
                        color: _cs.onSurface.withValues(alpha: 0.7))),
              ],
            )
          else if (error != null)
            Row(
              children: [
                Expanded(
                  child: Text(error,
                      style: TextStyle(fontSize: 12, color: _cs.error)),
                ),
                TextButton(
                  onPressed: () => _loadCoverCandidates(v),
                  child: const Text('Abar try koro',
                      style: TextStyle(fontSize: 12)),
                ),
              ],
            )
          else if (thumbs != null)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final t in thumbs)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _coverThumbButton(v, t),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _coverThumbButton(AnimationVideo v, _CoverThumb t) {
    final selected = v.pickedCoverTimeMs == t.timeMs;
    return InkWell(
      key: ValueKey('coverThumb-${v.id}-${t.timeMs}'),
      onTap: () => _onCoverPick(v, t.timeMs),
      borderRadius: BorderRadius.circular(10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              Container(
                width: 60,
                height: 107,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected ? _cs.primary : _cs.outlineVariant,
                    width: selected ? 2.5 : 1,
                  ),
                ),
                child: Opacity(
                  opacity: t.isDark ? 0.45 : 1.0,
                  child: Image.memory(t.bytes, fit: BoxFit.cover),
                ),
              ),
              if (selected)
                Positioned(
                  right: 4,
                  top: 4,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: _cs.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.check,
                        size: 14, color: _cs.onPrimary),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${(t.timeMs / 1000).toStringAsFixed(1)}s${t.isDark ? ' • ondhokar' : ''}',
            style: TextStyle(
                fontSize: 10,
                color: t.isDark
                    ? _cs.error
                    : _cs.onSurface.withValues(alpha: 0.6)),
          ),
        ],
      ),
    );
  }

  /// v169 — queues ONE local-frame capture for [v]'s preview pane
  /// (no-op when already requested). The best frame of the 3-4s
  /// window (the picked one when the user picked) is downscaled
  /// to a pane-sized JPEG and the card repaints with it. Reuses
  /// the picker's candidate thumbs so opening the Cover row
  /// afterwards needs no second capture. Any failure leaves the
  /// play mark in place (the Error log already has the reason).
  void _requestLocalPreview(AnimationVideo v) {
    if (_localPreviewRequested.contains(v.id)) return;
    _localPreviewRequested.add(v.id);
    _localPreviewQueue = _localPreviewQueue.then((_) async {
      if (!mounted) return;
      try {
        final result = await widget.engine.coverCandidates(v);
        if (!mounted || result.frames.isEmpty) return;
        CoverCandidate? best;
        for (final c in result.frames) {
          if (v.pickedCoverTimeMs >= 0 && c.timeMs == v.pickedCoverTimeMs) {
            best = c;
            break;
          }
          if (best == null || (c.luma ?? 0) > (best.luma ?? 0)) best = c;
        }
        if (best == null) return;
        final thumbs = <_CoverThumb>[
          for (final c in result.frames)
            _CoverThumb(
                timeMs: c.timeMs,
                bytes: _coverDisplayBytes(c.bytes),
                luma: c.luma),
        ];
        final preview = _previewBytes(best.bytes);
        setState(() {
          _localPreview[v.id] = preview;
          _coverThumbs.putIfAbsent(v.id, () => thumbs);
        });
      } catch (_) {
        // The play mark stays; nothing else to do.
      }
    });
  }

  /// Pane-sized (2x of the 84px preview) JPEG of a full-res frame.
  Uint8List _previewBytes(Uint8List bytes) {
    try {
      final decoded = img.decodeJpg(bytes);
      if (decoded == null) return bytes;
      final small = img.copyResize(decoded, width: 168, height: 299);
      return Uint8List.fromList(img.encodeJpg(small, quality: 80));
    } catch (_) {
      return bytes;
    }
  }

  /// v161 — the preview half of the two-part card: a small 9:16
  /// pane with ONLY the preview in it — the panel cover frame
  /// when the video has one (thumbUrl, set on panel upload), else
  /// a centred play mark. No text of any kind is overlaid on the
  /// frame (v159 rule). Tap opens the device preview as before
  /// (same `animPlay-<id>` key as the old play tile).
  Widget _videoPreviewPane(AnimationVideo v) {
    const width = 84.0;
    return InkWell(
      key: ValueKey('animPlay-${v.id}'),
      onTap: () => widget.onPlay(v),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        key: ValueKey('animPreview-${v.id}'),
        width: width,
        height: width * 16 / 9,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: _cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _cs.outlineVariant),
        ),
        child: v.thumbUrl.isNotEmpty
            ? Image.network(
                v.thumbUrl,
                fit: BoxFit.cover,
                // Slow network (~30 KB/s): show the play mark
                // while the frame loads instead of a blank pane.
                loadingBuilder: (ctx, child, progress) =>
                    progress == null ? child : _previewPlayMark(),
                errorBuilder: (_, __, ___) => _previewPlayMark(),
              )
            : _localPreviewOrPlayMark(v),
      ),
    );
  }

  /// v169 — no panel cover yet: the locally captured real frame
  /// when there is one, else the play mark (and the capture is
  /// queued, after this frame is built).
  Widget _localPreviewOrPlayMark(AnimationVideo v) {
    final bytes = _localPreview[v.id];
    if (bytes != null) {
      return Image.memory(
        bytes,
        key: ValueKey('animLocalPreview-${v.id}'),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _previewPlayMark(),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _requestLocalPreview(v);
    });
    return _previewPlayMark();
  }

  Widget _previewPlayMark() {
    return Center(
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: _cs.primary.withValues(alpha: 0.16),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.play_arrow_rounded,
            color: _cs.primary, size: 28),
      ),
    );
  }

  /// v161 — the card's spec lines (real duration · size · fps ·
  /// style · model + the honest fps/size notes), shared by the
  /// metadata side (under the split) and the no-metadata column.
  Widget _videoSpecBlock(AnimationVideo v) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
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
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 12, color: _cs.onSurface.withValues(alpha: 0.54)),
        ),
        // v154 — honest fps note under the spec line.
        if (v.fpsNote.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            v.fpsNote,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                const TextStyle(fontSize: 11, color: Color(0xFFFFB020)),
          ),
        ],
        // v159 second pass — over-target file: Gemini gave a
        // bigger file than the 10 MB asked for — say so on the
        // card instead of silently accepting it. The video itself
        // stays usable.
        if (v.sizeNote.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            v.sizeNote,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style:
                const TextStyle(fontSize: 11, color: Color(0xFFFFB020)),
          ),
        ],
      ],
    );
  }

  /// v161 — the metadata side when no AI metadata exists yet:
  /// the prompt title + spec, then the metadata state — either
  /// "banacche…" while the auto-fetch runs, or the Banglish
  /// failure note + manual retry when it failed. Videos finished
  /// before v161 keep the sparkle icon in the actions row below.
  Widget _videoNoMetaColumn(AnimationVideo v, bool busy) {
    final fetchingMeta = busy && widget.engine.busyAction == 'metadata';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(v.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _cs.onSurface)),
        const SizedBox(height: 4),
        _videoSpecBlock(v),
        if (fetchingMeta) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: _cs.primary),
              ),
              const SizedBox(width: 8),
              Text('AI Metadata banacche…',
                  style: TextStyle(
                      fontSize: 12,
                      color: _cs.onSurface.withValues(alpha: 0.7))),
            ],
          ),
        ] else if (v.metadataFailed) ...[
          const SizedBox(height: 8),
          const Text('AI Metadata hoyni — abar try koro.',
              style:
                  TextStyle(fontSize: 12, color: Color(0xFFFFB020))),
          const SizedBox(height: 2),
          TextButton.icon(
            key: ValueKey('animMetaRetry-${v.id}'),
            onPressed: busy ? null : () => _onMetadataTap(v),
            icon: const Icon(Icons.auto_awesome_outlined, size: 18),
            label: const Text('AI Metadata'),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ],
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

/// v166 — one picker candidate, downscaled for display (the
/// captured frame is full-res; showing five 1620x2880 JPEGs
/// would decode ~90 MB of pixels on the card). [luma] is the
/// v162 meter value, so the picker can dim dark frames.
class _CoverThumb {
  const _CoverThumb({
    required this.timeMs,
    required this.bytes,
    this.luma,
  });

  final int timeMs;
  final Uint8List bytes;
  final double? luma;

  bool get isDark => luma != null && luma! < kCoverMinLuminance;
}
