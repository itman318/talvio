import 'package:flutter/material.dart';

import '../theme/brand.dart';

/// A read receipt can arrive before the delivery watermark catches up.
Icon deliveryReceipt({
  required int messageId,
  required int deliveredUpTo,
  required int readUpTo,
  required bool onDark,
}) {
  final read = messageId <= readUpTo;
  final delivered = read || messageId <= deliveredUpTo;
  final color = read
      ? (onDark ? Brand.primaryLight : Brand.primaryDeep)
      : (onDark ? const Color(0xFFF0EDF4) : const Color(0xFF595465));
  return Icon(
    delivered ? Icons.done_all_rounded : Icons.done_rounded,
    size: 19,
    color: color,
    semanticLabel: read ? 'Read' : delivered ? 'Delivered' : 'Sent',
  );
}
