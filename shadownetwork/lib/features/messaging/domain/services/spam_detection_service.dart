import '../entities/spam_detection_result.dart';

class MessageSimilaritySample {
  const MessageSimilaritySample({
    required this.senderPeerId,
    required this.body,
    required this.createdAt,
    this.messageId,
    this.messageHash,
  });

  final String senderPeerId;
  final String body;
  final DateTime createdAt;
  final String? messageId;
  final String? messageHash;
}

class SpamDetectionService {
  const SpamDetectionService({
    this.window = const Duration(minutes: 10),
    this.jaccardThreshold = 0.80,
    this.levenshteinThreshold = 0.85,
  });

  final Duration window;
  final double jaccardThreshold;
  final double levenshteinThreshold;

  SpamDetectionResult classify({
    required MessageSimilaritySample candidate,
    required Iterable<MessageSimilaritySample> priorMessages,
  }) {
    SpamDetectionResult bestResult = const SpamDetectionResult.normal();

    for (final prior in priorMessages) {
      if (!_canCompare(candidate, prior)) {
        continue;
      }

      final jaccardScore = jaccardSimilarity(candidate.body, prior.body);
      if (jaccardScore >= jaccardThreshold && jaccardScore > bestResult.score) {
        bestResult = SpamDetectionResult.spam(
          score: jaccardScore,
          reason: 'jaccard_similarity',
          matchedMessageId: prior.messageId,
          matchedMessageHash: prior.messageHash,
        );
      }

      final levenshteinScore = normalizedLevenshteinSimilarity(
        candidate.body,
        prior.body,
      );
      if (levenshteinScore >= levenshteinThreshold &&
          levenshteinScore > bestResult.score) {
        bestResult = SpamDetectionResult.spam(
          score: levenshteinScore,
          reason: 'levenshtein_similarity',
          matchedMessageId: prior.messageId,
          matchedMessageHash: prior.messageHash,
        );
      }
    }

    return bestResult;
  }

  double jaccardSimilarity(String left, String right) {
    final leftWords = normalizeWords(left).toSet();
    final rightWords = normalizeWords(right).toSet();
    if (leftWords.isEmpty || rightWords.isEmpty) {
      return 0;
    }

    final intersection = leftWords.intersection(rightWords).length;
    final union = leftWords.union(rightWords).length;
    return intersection / union;
  }

  double normalizedLevenshteinSimilarity(String left, String right) {
    final normalizedLeft = normalizeText(left);
    final normalizedRight = normalizeText(right);
    final maxLength = normalizedLeft.length > normalizedRight.length
        ? normalizedLeft.length
        : normalizedRight.length;
    if (maxLength == 0) {
      return 0;
    }

    final distance = _levenshteinDistance(normalizedLeft, normalizedRight);
    return 1 - (distance / maxLength);
  }

  List<String> normalizeWords(String value) {
    final normalized = normalizeText(value);
    if (normalized.isEmpty) {
      return const [];
    }

    return normalized
        .split(' ')
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
  }

  String normalizeText(String value) {
    final withoutRepeatedPunctuation = value
        .toLowerCase()
        .trim()
        .replaceAllMapped(RegExp(r'([!?.,;:])\1+'), (match) => match.group(1)!);

    return withoutRepeatedPunctuation
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _canCompare(
    MessageSimilaritySample candidate,
    MessageSimilaritySample prior,
  ) {
    if (candidate.senderPeerId != prior.senderPeerId) {
      return false;
    }
    if (_sameMessage(candidate, prior)) {
      return false;
    }

    final timeDifference = candidate.createdAt
        .toUtc()
        .difference(prior.createdAt.toUtc())
        .abs();
    return timeDifference <= window;
  }

  bool _sameMessage(
    MessageSimilaritySample candidate,
    MessageSimilaritySample prior,
  ) {
    final candidateHash = candidate.messageHash;
    final priorHash = prior.messageHash;
    if (candidateHash != null && priorHash != null) {
      return candidateHash == priorHash;
    }

    final candidateId = candidate.messageId;
    final priorId = prior.messageId;
    return candidateId != null && priorId != null && candidateId == priorId;
  }

  int _levenshteinDistance(String left, String right) {
    if (left == right) {
      return 0;
    }
    if (left.isEmpty) {
      return right.length;
    }
    if (right.isEmpty) {
      return left.length;
    }

    var previous = List<int>.generate(right.length + 1, (index) => index);
    var current = List<int>.filled(right.length + 1, 0);

    for (var i = 0; i < left.length; i++) {
      current[0] = i + 1;
      for (var j = 0; j < right.length; j++) {
        final substitutionCost = left.codeUnitAt(i) == right.codeUnitAt(j)
            ? 0
            : 1;
        final deletion = previous[j + 1] + 1;
        final insertion = current[j] + 1;
        final substitution = previous[j] + substitutionCost;
        current[j + 1] = _min3(deletion, insertion, substitution);
      }

      final swap = previous;
      previous = current;
      current = swap;
    }

    return previous[right.length];
  }

  int _min3(int first, int second, int third) {
    final smaller = first < second ? first : second;
    return smaller < third ? smaller : third;
  }
}
