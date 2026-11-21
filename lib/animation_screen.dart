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

  @override
  State<AnimationSection> createState() => _AnimationSectionState();
}

class _AnimationSectionState extends State<AnimationSection> {
  final _promptCtrl = TextEditingController();
  bool _polishing = false;
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
      color: _cs.surface,
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
                fillColor: _cs.surfaceContainerHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: _cs.outlineVariant),
                ),
                suffixIcon: _promptCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        key: const ValueKey('animPromptClear'),
                        icon: Icon(Icons.clear,
                            size: 18, color: _cs.onSurface.withValues(alpha: 0.54)),
                        tooltip: 'Clear',
                        onPressed: () => _promptCtrl.clear(),
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
            const SizedBox(height: 8),
            // v88 — Polish + copyright guard. Polish rewrites the
            // idea via the Gemini session (same as the image Prompt
            // Polish, video-tuned). The warning shows live while a
            // blocked term is in the prompt — a copy gets his Zedge
            // account struck, so Generate stays off until it is
            // reworded.
            Row(
              children: [
                TextButton.icon(
                  key: const ValueKey('animPolishButton'),
                  onPressed: (prompt.isEmpty || _polishing || engine.busy)
                      ? null
                      : _onPolishTap,
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: Text(_polishing ? 'Polishing…' : 'Polish prompt'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Gemini prompt-ta sajiye debe — original concept thakbe',
                    style: TextStyle(fontSize: 11, color: _cs.onSurface.withValues(alpha: 0.54)),
                  ),
                ),
              ],
            ),
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
            // Model picker (his Gemini app's picker: Auto / Everyday
            // help — Hydrogen / Deeper analysis — Neon / Code &
            // complex work — Carbon, locked). Neon is the default.
            Row(
              children: [
                Text('Model',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _cs.onSurface.withValues(alpha: 0.7))),
                const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: _cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _cs.outlineVariant),
                    ),
                    child: DropdownButton<AnimationModel>(
                      key: const ValueKey('animModelPicker'),
                      value: animationModelById(engine.selectedModelId),
                      isExpanded: true,
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
                Text('Style',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _cs.onSurface.withValues(alpha: 0.7))),
                const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: _cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _cs.outlineVariant),
                    ),
                    child: DropdownButton<AnimationMood>(
                      key: const ValueKey('animStylePicker'),
                      value: animationMoodById(engine.selectedStyleId),
                      isExpanded: true,
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
                Text('Duration',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _cs.onSurface.withValues(alpha: 0.7))),
                const SizedBox(width: 10),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    children: [
                      for (final seconds in kAnimationDurations)
                        ChoiceChip(
                          key: ValueKey('animDuration-$seconds'),
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
                ],
              ),
            ],
            if (!widget.signedIn) ...[
              const SizedBox(height: 8),
              const Text(
                  'Age Login tab theke Gemini-te sign in koro — tarpor animation banbe.',
                  style: TextStyle(fontSize: 12, color: Color(0xFFFBBF24))),
            ],
            if (!isAndroid) ...[
              const SizedBox(height: 8),
              Text(
                  'Video generation ekhon Android app-e — Windows-e gallery + ZIP cholbe.',
                  style: TextStyle(fontSize: 12, color: _cs.onSurface.withValues(alpha: 0.54))),
            ],
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
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _cs.outlineVariant),
                ),
                child: Text('${engine.videos.length} videos',
                    style:
                        TextStyle(fontSize: 12, color: _cs.onSurface.withValues(alpha: 0.7))),
              ),
            ],
          ),
        ),
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

  Widget _galleryBody() {
    final engine = widget.engine;
    if (engine.videos.isEmpty) {
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
    return Column(
      children: [
        for (final v in engine.videos) _videoCard(v),
      ],
    );
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
    // v87: four actions do NOT fit beside the title on a 360px
    // phone (the first attempt squeezed the title to ~55px and
    // the subtitle wrapped character by character). The card
    // keeps the v86 ListTile (play tile + title + spec + Play)
    // and puts Metadata / Upload / Delete on their own row
    // below, so the title always gets the full width.
    final busy = widget.engine.busyVideoId == v.id;
    return Card(
      color: _cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: _cs.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _cs.primary.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.play_circle_outline,
                  color: _cs.primary, size: 22),
            ),
            title: Text(v.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _cs.onSurface)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                    '${v.specLine} · ${animationModelById(v.modelId).label}',
                    style: TextStyle(
                        fontSize: 12, color: _cs.onSurface.withValues(alpha: 0.54))),
                if (v.isUploaded)
                  Text('Queued on ${v.uploadedAccount}',
                      style: TextStyle(
                          fontSize: 11, color: _cs.primary)),
              ],
            ),
            trailing: IconButton(
              key: ValueKey('animPlay-${v.id}'),
              icon: Icon(Icons.play_arrow, color: _cs.onSurface.withValues(alpha: 0.7)),
              tooltip: 'Play',
              onPressed: () => widget.onPlay(v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
            // Wrap, not Row: the Ahem test font is much wider than
            // Roboto, so the three labeled buttons overflow a Row
            // by ~66px under tests — Wrap drops the last button
            // to a second line instead of erroring, while real
            // Roboto phones keep one row.
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              children: [
                TextButton.icon(
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8)),
                  key: ValueKey('animMeta-${v.id}'),
                  icon: Icon(
                      v.hasMetadata
                          ? Icons.auto_awesome
                          : Icons.auto_awesome_outlined,
                      size: 16,
                      color: v.hasMetadata
                          ? _cs.primary
                          : _cs.onSurface.withValues(alpha: 0.7)),
                  label: Text(v.hasMetadata ? 'Metadata' : 'AI Metadata',
                      style: TextStyle(
                          fontSize: 12,
                          color: v.hasMetadata
                              ? _cs.primary
                              : _cs.onSurface.withValues(alpha: 0.7))),
                  onPressed: busy ? null : () => _onMetadataTap(v),
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8)),
                  key: ValueKey('animUpload-${v.id}'),
                  icon: Icon(
                      v.isUploaded
                          ? Icons.cloud_done_outlined
                          : Icons.cloud_upload_outlined,
                      size: 16,
                      color: v.isUploaded
                          ? _cs.primary
                          : _cs.onSurface.withValues(alpha: 0.7)),
                  label: Text(v.isUploaded ? 'Queued' : 'Upload',
                      style: TextStyle(
                          fontSize: 12,
                          color: v.isUploaded
                              ? _cs.primary
                              : _cs.onSurface.withValues(alpha: 0.7))),
                  onPressed:
                      busy ? null : () => widget.onUploadToPanel(v),
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8)),
                  key: ValueKey('animDelete-${v.id}'),
                  icon: Icon(Icons.delete_outline,
                      size: 16, color: _cs.onSurface.withValues(alpha: 0.54)),
                  label: Text('Delete',
                      style:
                          TextStyle(fontSize: 12, color: _cs.onSurface.withValues(alpha: 0.54))),
                  onPressed: () => widget.onDelete(v),
                ),
              ],
            ),
          ),
        ],
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
