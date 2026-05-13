import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:easy_localization/easy_localization.dart';

import 'device_policy_service.dart';
import 'matrix_service.dart';
import 'main_screen.dart';
import 'password_reset_service.dart';
import 'session_manager.dart';
import 'two_factor_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController usernameController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  bool loading = false;
  bool agreedToTerms = false;
  bool rememberMe = false;
  String error = '';
  String? currentLocale;

  @override
  void dispose() {
    usernameController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
    _loadSavedLocale();
  }

  Future<void> _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUsername = prefs.getString('saved_username');
    if (!mounted) return;

    if (savedUsername != null) {
      setState(() {
        usernameController.text = savedUsername;
        rememberMe = true;
      });
    }
    // Migrate: remove any previously stored plaintext password.
    await prefs.remove('saved_password');
  }

  Future<void> _saveCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    if (rememberMe) {
      await prefs.setString('saved_username', usernameController.text);
    } else {
      await prefs.remove('saved_username');
    }
    // Passwords must never be stored locally.
    await prefs.remove('saved_password');
  }

  Future<void> _login() async {
    if (!agreedToTerms) return;

    setState(() {
      loading = true;
      error = '';
    });

    final username = usernameController.text.trim();
    final password = passwordController.text;
    final result = await MatrixService.login(username, password);
    if (!mounted) return;

    setState(() => loading = false);

    if (result.status == MatrixLoginStatus.twoFactorRequired) {
      final twoFactorOk = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => TwoFactorScreen(
            username: username,
            password: password,
            method: result.twoFactorMethod,
            emailOrUsername: result.emailOrUsername,
          ),
        ),
      );
      if (twoFactorOk != true) return;
      await _finishSuccessfulLogin(username);
    } else if (result.isSuccess) {
      await _finishSuccessfulLogin(username);
    } else {
      setState(() => error = tr('invalid_credentials'));
    }
  }

  Future<void> _finishSuccessfulLogin(String username) async {
    // ── Device-policy check ──────────────────────────────────────────────
    // Submit device information to the policy backend before completing login.
    // The backend registers new devices and logs a multi_device_detected event
    // (with an internal alert email) when a different device is seen — it no
    // longer blocks access on mismatch.  A genuine server/transport error is
    // still surfaced to the user.
    setState(() => loading = true);

    // Guard: userId must be populated by a successful login before reaching here.
    final userId = MatrixService.userId;
    if (userId.isEmpty) {
      await MatrixService.clearSession();
      setState(() {
        loading = false;
        error = tr('device_policy_error');
      });
      return;
    }

    final policyResult = await DevicePolicyService.checkDevicePolicy(
      userId: userId,
      username: username,
    );

    if (!mounted) return;

    if (policyResult == DevicePolicyResult.error) {
      // The policy service could not be reached.  For security (fail-closed),
      // block the login rather than silently allowing an unverified device.
      await MatrixService.clearSession();
      setState(() {
        loading = false;
        error = tr('device_policy_error');
      });
      return;
    }

    // policyResult == DevicePolicyResult.allowed – continue normal flow.
    await _saveCredentials();
    await FirebaseMessaging.instance
        .requestPermission(alert: true, badge: true, sound: true);
    await MatrixService.registerPushToken('');

    // Save session info centrally using SessionManager
    await SessionManager.saveSession(
      username: username,
      rocketchatAuthToken: MatrixService.rocketchatAuthToken ?? '',
      rocketchatUserId: MatrixService.rocketchatUserId ?? '',
    );

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => MainScreen(
          accessToken: MatrixService.authToken,
          username: username,
        ),
      ),
    );
  }

  Future<void> _loadSavedLocale() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLocale = prefs.getString('user_locale');
    if (!mounted) return;
    if (savedLocale != null && savedLocale.isNotEmpty) {
      context.setLocale(Locale(savedLocale));
      setState(() {
        currentLocale = savedLocale;
      });
    } else {
      setState(() {
        currentLocale = context.locale.languageCode;
      });
    }
  }

  Future<void> _switchLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final newLocale = context.locale.languageCode == 'en' ? 'ko' : 'en';
    await prefs.setString('user_locale', newLocale);
    if (!mounted) return;
    context.setLocale(Locale(newLocale));
    setState(() {
      currentLocale = newLocale;
    });
  }

  bool _isReasonablyValidEmail(String value) {
    final email = value.trim();
    if (email.isEmpty) return false;
    final pattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    return pattern.hasMatch(email);
  }

  Future<void> _showForgotPasswordDialog() async {
    final result = await showDialog<PasswordResetRequestResult>(
      context: context,
      builder: (_) => _ForgotPasswordDialog(
        isReasonablyValidEmail: _isReasonablyValidEmail,
      ),
    );
    if (!mounted || result == null) return;

    final messenger = ScaffoldMessenger.of(context);
    if (result == PasswordResetRequestResult.unavailable) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'forgot_password_temporarily_unavailable_message'.tr(),
          ),
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text('forgot_password_request_failed'.tr()),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: Text('login_title'.tr()),
          actions: [
            TextButton(
              onPressed: _switchLanguage,
              child: Text(
                context.locale.languageCode == 'en' ? '한국어' : 'English',
                style: const TextStyle(color: Colors.green),
              ),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Image.asset('assets/icon.png', height: 100),
              const SizedBox(height: 20),

              // Username & Password
              TextField(
                controller: usernameController,
                decoration: InputDecoration(labelText: 'username'.tr()),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: passwordController,
                decoration: InputDecoration(labelText: 'password'.tr()),
                obscureText: true,
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: loading ? null : _showForgotPasswordDialog,
                  child: Text('forgot_password'.tr()),
                ),
              ),
              const SizedBox(height: 10),

              // Error message
              if (error.isNotEmpty)
                Text(error, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 20),

              // Legal notice (can be translated)
              Text(
                'legal_notice'.tr(),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.justify,
              ),
              const SizedBox(height: 15),

              // Remember me & terms checkboxes
              Row(
                children: [
                  Checkbox(
                    value: rememberMe,
                    onChanged: (v) => setState(() => rememberMe = v ?? false),
                  ),
                  Text('remember_me'.tr()),
                ],
              ),
              Row(
                children: [
                  Checkbox(
                    value: agreedToTerms,
                    onChanged: (v) => setState(() => agreedToTerms = v ?? false),
                  ),
                  Expanded(
                    child: Text(
                      'agree_terms'.tr(),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Login button or loader
              loading
                  ? const CircularProgressIndicator()
                  : ElevatedButton(
                onPressed: agreedToTerms ? _login : null,
                child: Text('login'.tr()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ForgotPasswordDialog extends StatefulWidget {
  final bool Function(String value) isReasonablyValidEmail;

  const _ForgotPasswordDialog({
    required this.isReasonablyValidEmail,
  });

  @override
  State<_ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<_ForgotPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid || _submitting) return;

    setState(() => _submitting = true);
    final result = await PasswordResetService.requestPasswordReset(
      _emailController.text,
    );
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('forgot_password'.tr()),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              container: true,
              child: Text('forgot_password_preparing_hint'.tr()),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: InputDecoration(
                labelText: 'forgot_password_email_label'.tr(),
              ),
              validator: (value) {
                final raw = value ?? '';
                if (raw.trim().isEmpty) {
                  return 'forgot_password_email_required'.tr();
                }
                if (!widget.isReasonablyValidEmail(raw)) {
                  return 'forgot_password_invalid_email'.tr();
                }
                return null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text('cancel'.tr()),
        ),
        ElevatedButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('forgot_password_submit'.tr()),
        ),
      ],
    );
  }
}
