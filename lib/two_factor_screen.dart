import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';

import 'matrix_service.dart';

class TwoFactorScreen extends StatefulWidget {
  final String username;
  final String password;
  final String? method;
  final String? emailOrUsername;

  const TwoFactorScreen({
    Key? key,
    required this.username,
    required this.password,
    this.method,
    this.emailOrUsername,
  }) : super(key: key);

  @override
  _TwoFactorScreenState createState() => _TwoFactorScreenState();
}

class _TwoFactorScreenState extends State<TwoFactorScreen> {
  final TextEditingController _codeController = TextEditingController();
  bool _loading = false;
  String _error = '';

  String get _prompt {
    if (_isEmail) {
      final target = widget.emailOrUsername;
      if (target != null && target.isNotEmpty) {
        return tr(
          'two_factor_email_prompt_with_target',
          args: [target],
        );
      }
      return tr('two_factor_email_prompt');
    }
    return tr('two_factor_prompt');
  }

  bool get _isEmail =>
      widget.method?.toLowerCase() == 'email';

  Future<void> _submitCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _error = tr('two_factor_code_required'));
      return;
    }

    setState(() {
      _loading = true;
      _error = '';
    });

    final result = await MatrixService.login(
      widget.username,
      widget.password,
      twoFactorCode: code,
      twoFactorMethod: widget.method,
    );

    if (!mounted) return;
    setState(() => _loading = false);

    if (result.isSuccess) {
      Navigator.pop(context, true);
    } else if (result.status == MatrixLoginStatus.twoFactorInvalid) {
      setState(() => _error = tr('two_factor_invalid_code'));
    } else {
      setState(() => _error = tr('invalid_credentials'));
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: Text('two_factor_title'.tr()),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              Text(
                _prompt,
                style: const TextStyle(fontSize: 15),
                textAlign: TextAlign.center,
              ),
              if (_isEmail) ...[
                const SizedBox(height: 8),
                Text(
                  tr('two_factor_email_spam_tip'),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 24),
              TextField(
                controller: _codeController,
                decoration: InputDecoration(
                  labelText: tr('two_factor_code_label'),
                ),
                keyboardType: TextInputType.number,
                autofocus: true,
                onSubmitted: (_) => _submitCode(),
              ),
              const SizedBox(height: 12),
              if (_error.isNotEmpty)
                Text(
                  _error,
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center,
                ),
              const SizedBox(height: 20),
              _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton(
                      onPressed: _submitCode,
                      child: Text('two_factor_submit'.tr()),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
