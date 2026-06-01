import 'package:flutter_test/flutter_test.dart';
import 'package:shadownetwork/features/messaging/domain/entities/message_moderation_status.dart';
import 'package:shadownetwork/features/messaging/domain/services/spam_detection_service.dart';

void main() {
  const service = SpamDetectionService();
  final baseTime = DateTime.utc(2026, 6, 1, 10);

  MessageSimilaritySample sample({
    required String senderPeerId,
    required String body,
    required DateTime createdAt,
    required String id,
  }) {
    return MessageSimilaritySample(
      senderPeerId: senderPeerId,
      body: body,
      createdAt: createdAt,
      messageId: id,
    );
  }

  test('flags similar repeated messages from the same sender', () {
    final result = service.classify(
      candidate: sample(
        senderPeerId: 'peer-a',
        body: 'Need water and food near the chapel',
        createdAt: baseTime.add(const Duration(minutes: 5)),
        id: 'candidate',
      ),
      priorMessages: [
        sample(
          senderPeerId: 'peer-a',
          body: 'Need water and food near the chapel!',
          createdAt: baseTime,
          id: 'prior',
        ),
      ],
    );

    expect(result.status, MessageModerationStatus.spam);
    expect(result.matchedMessageId, 'prior');
    expect(result.score, greaterThanOrEqualTo(0.80));
  });

  test('ignores similar messages from different senders', () {
    final result = service.classify(
      candidate: sample(
        senderPeerId: 'peer-a',
        body: 'Need rescue at the barangay hall',
        createdAt: baseTime.add(const Duration(minutes: 5)),
        id: 'candidate',
      ),
      priorMessages: [
        sample(
          senderPeerId: 'peer-b',
          body: 'Need rescue at the barangay hall',
          createdAt: baseTime,
          id: 'prior',
        ),
      ],
    );

    expect(result.status, MessageModerationStatus.normal);
  });

  test('detects reordered words with Jaccard similarity', () {
    final result = service.classify(
      candidate: sample(
        senderPeerId: 'peer-a',
        body: 'medicine water food need now',
        createdAt: baseTime.add(const Duration(minutes: 2)),
        id: 'candidate',
      ),
      priorMessages: [
        sample(
          senderPeerId: 'peer-a',
          body: 'need food water medicine now',
          createdAt: baseTime,
          id: 'prior',
        ),
      ],
    );

    expect(result.status, MessageModerationStatus.spam);
    expect(result.reason, 'jaccard_similarity');
  });

  test(
    'detects small text variations with normalized Levenshtein similarity',
    () {
      final result = service.classify(
        candidate: sample(
          senderPeerId: 'peer-a',
          body: 'need rescure at purok 3 now',
          createdAt: baseTime.add(const Duration(minutes: 2)),
          id: 'candidate',
        ),
        priorMessages: [
          sample(
            senderPeerId: 'peer-a',
            body: 'need rescue at purok 3 now',
            createdAt: baseTime,
            id: 'prior',
          ),
        ],
      );

      expect(result.status, MessageModerationStatus.spam);
      expect(result.reason, 'levenshtein_similarity');
    },
  );
}
