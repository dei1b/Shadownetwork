import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/sos_message.dart';
import '../providers/sos_clock_provider.dart';
import '../utils/sos_timing_labels.dart';

class SosReceiptSummary extends ConsumerWidget {
  const SosReceiptSummary({super.key, required this.message});

  final SosMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(sosClockProvider);
    final age = SosTimingLabels.age(message, now);
    final propagation = SosTimingLabels.propagation(message);
    final warning =
        SosTimingLabels.hasClockMismatch(message) ||
        age == 'Clock mismatch detected';
    final transport = SosTimingLabels.transport(message.receivedTransport);
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            age,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF585858),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '$propagation • ${SosTimingLabels.hops(message.hopCount)}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: warning
                  ? const Color(0xFF9B341E)
                  : const Color(0xFF333333),
            ),
          ),
          if (transport != null) ...[
            const SizedBox(height: 3),
            Text(
              'Last hop: $transport',
              style: const TextStyle(fontSize: 11, color: Color(0xFF666666)),
            ),
          ],
        ],
      ),
    );
  }
}
