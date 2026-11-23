/// v159 second pass — the IMAGE metadata card's styling, shared
/// with the VIDEO metadata card so the two cannot drift apart
/// again. Values copied verbatim from `_metaCard`
/// (lib/main.dart:3786); both cards import these instead of
/// keeping their own copies of the same numbers.
library;

import 'package:flutter/material.dart';

/// The category pill's filled purple (both cards).
const Color kMetaCategoryPillColor = Color(0xFF7A68E0);

/// The metadata card container (both cards).
const double kMetaCardRadius = 16;
const EdgeInsets kMetaCardPadding = EdgeInsets.all(12);

/// The toggle only appears when something is actually hidden: a
/// description longer than ~2 lines, or more tags than fit one
/// row (same rule as `_metaCard`).
bool metaShowsExpandToggle({
  required String description,
  required int tagCount,
}) =>
    description.length > 120 || tagCount > 5;

/// The tag chip from `_metaCard` (lib/main.dart `_tagChip`),
/// verbatim: dark chip with a '#tag' label.
Widget metaTagChip(String tag) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFF12121B),
      border: Border.all(color: Colors.white12),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text('#$tag',
        style: const TextStyle(fontSize: 13, color: Color(0xFFC9C9D2))),
  );
}
