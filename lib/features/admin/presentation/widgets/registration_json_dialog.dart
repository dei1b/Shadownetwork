import 'package:flutter/material.dart';

class RegistrationJsonDialog extends StatefulWidget {
  const RegistrationJsonDialog({super.key});
  @override
  State<RegistrationJsonDialog> createState() => _RegistrationJsonDialogState();
}

class _RegistrationJsonDialogState extends State<RegistrationJsonDialog> {
  final _controller = TextEditingController();
  bool _empty = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Phone registration JSON'),
    content: SizedBox(
      width: 560,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Paste the registration JSON copied from the phone. Its signature is checked before filling the form.',
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('desktop-registration-json'),
            controller: _controller,
            autofocus: true,
            minLines: 4,
            maxLines: 9,
            decoration: InputDecoration(
              labelText: 'Registration JSON',
              border: const OutlineInputBorder(),
              errorText: _empty ? 'Paste the phone registration JSON.' : null,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          final source = _controller.text.trim();
          if (source.isEmpty) {
            setState(() => _empty = true);
            return;
          }
          Navigator.pop(context, source);
        },
        child: const Text('Read registration'),
      ),
    ],
  );
}
