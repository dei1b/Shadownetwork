import 'package:flutter_riverpod/flutter_riverpod.dart';

class ComposeMessageState {
  const ComposeMessageState({required this.draft, this.errorText});

  final String draft;
  final String? errorText;

  ComposeMessageState copyWith({
    String? draft,
    String? errorText,
    bool clearError = false,
  }) {
    return ComposeMessageState(
      draft: draft ?? this.draft,
      errorText: clearError ? null : errorText ?? this.errorText,
    );
  }
}

class ComposeMessageController extends StateNotifier<ComposeMessageState> {
  ComposeMessageController() : super(const ComposeMessageState(draft: ''));

  void updateDraft(String value) {
    state = state.copyWith(draft: value, clearError: true);
  }

  bool submitDraft() {
    if (state.draft.trim().isEmpty) {
      state = state.copyWith(errorText: 'Message cannot be empty.');
      return false;
    }

    state = const ComposeMessageState(draft: '');
    return true;
  }
}

final composeMessageProvider =
    StateNotifierProvider<ComposeMessageController, ComposeMessageState>(
      (ref) => ComposeMessageController(),
    );
