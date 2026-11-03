import 'package:flutter/material.dart';
import 'package:shadownetwork/core/widgets/action_feedback.dart';

import '../../../security/data/services/user_information_store.dart';
import '../../../security/domain/entities/user_information.dart';

class UserInformationForm extends StatefulWidget {
  const UserInformationForm({super.key});

  @override
  State<UserInformationForm> createState() => _UserInformationFormState();
}

class _UserInformationFormState extends State<UserInformationForm> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _form = GlobalKey<FormState>();
  final _store = UserInformationStore();
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final information = await _store.load();
      if (!mounted) return;
      _name.text = information?.fullName ?? '';
      _phone.text = information?.phoneNumber ?? '';
      _address.text = information?.address ?? '';
    } catch (_) {
      if (!mounted) return;
      _error = 'Unable to load user information. Enter your details again.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (_saving || _form.currentState?.validate() != true) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _store.save(
        UserInformation(
          fullName: _name.text.trim(),
          phoneNumber: _phone.text.trim(),
          address: _address.text.trim(),
        ),
      );
      if (!mounted) return;
      FocusScope.of(context).unfocus();
      ActionFeedback.show(
        context,
        'User information saved on this phone. You can now show your registration QR.',
        kind: FeedbackKind.success,
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Unable to save user information. Your entries are still here; try saving again.',
        );
        ActionFeedback.show(context, _error!, kind: FeedbackKind.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'User information',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        if (_loading) const LinearProgressIndicator(),
        TextFormField(
          controller: _name,
          enabled: !_loading && !_saving,
          maxLength: 100,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Full name',
            prefixIcon: Icon(Icons.person_outline),
          ),
          validator: (value) => value == null || value.trim().isEmpty
              ? 'Enter your full name.'
              : null,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _phone,
          enabled: !_loading && !_saving,
          maxLength: 50,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'Phone number',
            prefixIcon: Icon(Icons.phone_outlined),
          ),
          validator: (value) => value == null || value.trim().isEmpty
              ? 'Enter your phone number.'
              : null,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _address,
          enabled: !_loading && !_saving,
          maxLength: 300,
          minLines: 2,
          maxLines: 4,
          keyboardType: TextInputType.streetAddress,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Address',
            prefixIcon: Icon(Icons.location_on_outlined),
          ),
          validator: (value) => value == null || value.trim().isEmpty
              ? 'Enter your address.'
              : null,
        ),
        if (_error != null)
          ActionStatus(message: _error!, kind: FeedbackKind.error),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _loading || _saving ? null : _save,
          icon: const Icon(Icons.save_outlined),
          label: Text(_saving ? 'Saving...' : 'Save user information'),
        ),
      ],
    ),
  );
}
