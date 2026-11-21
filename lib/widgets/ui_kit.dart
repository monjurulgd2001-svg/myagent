import 'package:flutter/material.dart';

import '../app_theme.dart';

/// Shared building blocks so every screen looks the same on a phone:
/// cards with a tinted icon header, button groups that lay out in equal
/// columns (never squeezed / wrapped labels), status pills and hints.

/// Card with an icon + title header.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(16, 16, 16, 16),
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
                icon: icon, title: title, subtitle: subtitle, trailing: trailing),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(
      {super.key,
      required this.icon,
      required this.title,
      this.subtitle,
      this.trailing});
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        IconBadge(icon: icon),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.1)),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurfaceVariant)),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}

/// Rounded square with a tinted icon.
class IconBadge extends StatelessWidget {
  const IconBadge({super.key, required this.icon, this.color, this.size = 38});
  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(icon, size: size * 0.53, color: c),
    );
  }
}

enum AppButtonKind { primary, tonal, outline, text, danger }

/// Button with a single-line label (ellipsis instead of wrapping).
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.kind = AppButtonKind.primary,
    this.loading = false,
    this.expand = true,
    this.tooltip,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final AppButtonKind kind;
  final bool loading;
  final bool expand;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lbl = Text(label,
        maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false);
    final Widget? ic = loading
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.2))
        : (icon == null ? null : Icon(icon));
    final cb = loading ? null : onPressed;
    Widget b;
    switch (kind) {
      case AppButtonKind.primary:
        b = ic == null
            ? FilledButton(onPressed: cb, child: lbl)
            : FilledButton.icon(onPressed: cb, icon: ic, label: lbl);
      case AppButtonKind.tonal:
        b = ic == null
            ? FilledButton.tonal(onPressed: cb, child: lbl)
            : FilledButton.tonalIcon(onPressed: cb, icon: ic, label: lbl);
      case AppButtonKind.outline:
        b = ic == null
            ? OutlinedButton(onPressed: cb, child: lbl)
            : OutlinedButton.icon(onPressed: cb, icon: ic, label: lbl);
      case AppButtonKind.text:
        b = ic == null
            ? TextButton(onPressed: cb, child: lbl)
            : TextButton.icon(onPressed: cb, icon: ic, label: lbl);
      case AppButtonKind.danger:
        final style = OutlinedButton.styleFrom(
          foregroundColor: scheme.error,
          side: BorderSide(color: scheme.error.withValues(alpha: 0.45)),
        );
        b = ic == null
            ? OutlinedButton(style: style, onPressed: cb, child: lbl)
            : OutlinedButton.icon(
                style: style, onPressed: cb, icon: ic, label: lbl);
    }
    if (expand) b = SizedBox(width: double.infinity, child: b);
    if (tooltip != null) b = Tooltip(message: tooltip!, child: b);
    return b;
  }
}

/// Lays buttons out in equal-width columns: 2 per row on phones, more on
/// wide screens, 1 per row on very narrow ones. Labels never wrap.
class ButtonGroup extends StatelessWidget {
  const ButtonGroup({
    super.key,
    required this.children,
    this.minItemWidth = 150,
    this.spacing = 10,
    this.maxColumns = 4,
  });

  final List<Widget> children;
  final double minItemWidth;
  final double spacing;
  final int maxColumns;

  @override
  Widget build(BuildContext context) {
    final items = children;
    if (items.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, c) {
      var cols = ((c.maxWidth + spacing) / (minItemWidth + spacing)).floor();
      cols = cols.clamp(1, maxColumns).clamp(1, items.length);
      final rows = <Widget>[];
      for (var i = 0; i < items.length; i += cols) {
        final row = items.sublist(i, (i + cols).clamp(0, items.length));
        rows.add(Row(children: [
          for (var j = 0; j < row.length; j++) ...[
            if (j > 0) SizedBox(width: spacing),
            Expanded(child: row[j]),
          ],
        ]));
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var r = 0; r < rows.length; r++) ...[
            if (r > 0) SizedBox(height: spacing),
            rows[r],
          ],
        ],
      );
    });
  }
}

/// Small coloured status label.
class StatusPill extends StatelessWidget {
  const StatusPill(
      {super.key, required this.label, required this.color, this.icon});
  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
        ],
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

/// Muted helper text with an info icon.
class HintText extends StatelessWidget {
  const HintText(this.text, {super.key, this.icon = Icons.info_outline});
  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Text(text,
        style: TextStyle(
            fontSize: 12.5, height: 1.45, color: scheme.onSurfaceVariant));
    if (icon == null) return t;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 1),
        child: Icon(icon, size: 15, color: scheme.onSurfaceVariant),
      ),
      const SizedBox(width: 8),
      Expanded(child: t),
    ]);
  }
}

/// Numbered how-to steps.
class StepList extends StatelessWidget {
  const StepList(this.steps, {super.key});
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.16),
                    shape: BoxShape.circle),
                child: Text('${i + 1}',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(steps[i],
                    style: TextStyle(
                        fontSize: 13.5,
                        height: 1.45,
                        color: scheme.onSurfaceVariant)),
              ),
            ]),
          ),
      ],
    );
  }
}

/// Centered empty-state message.
class EmptyState extends StatelessWidget {
  const EmptyState(
      {super.key, required this.icon, required this.title, this.message});
  final IconData icon;
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 12),
      child: Column(children: [
        IconBadge(icon: icon, size: 56, color: scheme.onSurfaceVariant),
        const SizedBox(height: 14),
        Text(title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        if (message != null) ...[
          const SizedBox(height: 6),
          Text(message!,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, height: 1.45, color: scheme.onSurfaceVariant)),
        ],
      ]),
    );
  }
}

/// Compact square icon action (40 dp visual, 48 dp touch target).
class IconAction extends StatelessWidget {
  const IconAction(
      {super.key,
      required this.icon,
      required this.tooltip,
      required this.onPressed,
      this.color,
      this.selected = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      style: IconButton.styleFrom(
        foregroundColor:
            color ?? (selected ? scheme.primary : scheme.onSurfaceVariant),
        backgroundColor: selected
            ? scheme.primary.withValues(alpha: 0.14)
            : scheme.surfaceContainerHigh,
        minimumSize: const Size(42, 42),
        fixedSize: const Size(42, 42),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

/// Success / warning colours (theme-independent).
Color successColor(BuildContext _) => AppTheme.success;
Color warningColor(BuildContext _) => AppTheme.warning;
