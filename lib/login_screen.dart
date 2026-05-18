import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:url_launcher/url_launcher.dart';

import 'device_policy_service.dart';
import 'matrix_service.dart';
import 'main_screen.dart';
import 'password_reset_service.dart';
import 'password_policy_validator.dart';
import 'session_manager.dart';
import 'two_factor_screen.dart';

class LoginScreen extends StatefulWidget {
  final String? sessionNoticeKey;
  final VoidCallback? onSessionNoticeShown;

  const LoginScreen({
    Key? key,
    this.sessionNoticeKey,
    this.onSessionNoticeShown,
  }) : super(key: key);

  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static final Uri _privacyPolicyUri = Uri.parse('https://privacy.icsportals.org/');

  final TextEditingController usernameController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  bool loading = false;
  bool agreedToTerms = false;
  bool rememberMe = false;
  String error = '';
  String? sessionNoticeKey;
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
    sessionNoticeKey = widget.sessionNoticeKey;
    if (sessionNoticeKey != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onSessionNoticeShown?.call();
      });
    }
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
    // The backend tracks exclusive-session state and can signal when this
    // session has already been superseded by a newer login on another device.
    setState(() => loading = true);

    // Guard: the Rocket.Chat session headers must be populated by a successful
    // login before reaching here.
    if (MatrixService.userId.isEmpty || MatrixService.authToken.isEmpty) {
      await MatrixService.clearSession();
      setState(() {
        loading = false;
        error = tr('device_policy_error');
      });
      return;
    }

    final policyResult = await DevicePolicyService.checkDevicePolicy();

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

    if (policyResult == DevicePolicyResult.revoked) {
      await MatrixService.forceLogoutForRevokedSession();
      setState(() {
        loading = false;
        sessionNoticeKey = 'session_revoked_notice';
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

  Future<void> _openPrivacyPolicy() async {
    try {
      final launched = await launchUrl(
        _privacyPolicyUri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('privacy_policy_open_error'.tr())),
        );
      }
    } catch (e) {
      if (!mounted) return;
      debugPrint('Failed to open privacy policy URL: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('privacy_policy_open_error'.tr())),
      );
    }
  }

  Future<void> _showForgotPasswordDialog() async {
    // ── Step 1: collect email and request reset code ──────────────────────
    final email = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ForgotPasswordRequestDialog(
        isReasonablyValidEmail: _isReasonablyValidEmail,
      ),
    );
    // null → user cancelled
    if (!mounted || email == null) return;

    // Neutral confirmation: avoid leaking whether the account exists.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('forgot_password_code_sent'.tr())),
    );

    // ── Step 2: enter reset code + new password ───────────────────────────
    final confirmResult = await showDialog<PasswordResetConfirmResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ForgotPasswordConfirmDialog(email: email),
    );
    if (!mounted) return;

    if (confirmResult == PasswordResetConfirmResult.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('forgot_password_reset_success'.tr())),
      );
    }
    // Failure is surfaced inside _ForgotPasswordConfirmDialog; null means
    // the user cancelled, in which case no top-level message is needed.
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
              if (sessionNoticeKey != null)
                Text(
                  tr(sessionNoticeKey!),
                  style: const TextStyle(color: Colors.deepOrange),
                ),
              const SizedBox(height: 20),

              // Legal notice (can be translated)
              Text(
                'legal_notice'.tr(),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.justify,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _openPrivacyPolicy,
                  child: Text('privacy_policy_link'.tr()),
                ),
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

// ── Step-1 dialog: enter email and request a reset code ──────────────────────

class _ForgotPasswordRequestDialog extends StatefulWidget {
  final bool Function(String value) isReasonablyValidEmail;

  const _ForgotPasswordRequestDialog({
    required this.isReasonablyValidEmail,
  });

  @override
  State<_ForgotPasswordRequestDialog> createState() =>
      _ForgotPasswordRequestDialogState();
}

class _ForgotPasswordRequestDialogState
    extends State<_ForgotPasswordRequestDialog> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _submitting = false;
  String _error = '';

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid || _submitting) return;

    setState(() {
      _submitting = true;
      _error = '';
    });

    final email = _emailController.text.trim();
    final result = await PasswordResetService.requestPasswordReset(email);
    if (!mounted) return;

    if (result == PasswordResetRequestResult.sent) {
      // Pop and return the email so step 2 can pre-fill it.
      Navigator.of(context).pop(email);
    } else {
      setState(() {
        _submitting = false;
        _error = 'forgot_password_request_failed'.tr();
      });
    }
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
            Text('forgot_password_email_hint'.tr()),
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
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _error,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ],
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

// ── Step-2 dialog: enter reset code + new password ────────────────────────────

class _ForgotPasswordConfirmDialog extends StatefulWidget {
  final String email;

  const _ForgotPasswordConfirmDialog({required this.email});

  @override
  State<_ForgotPasswordConfirmDialog> createState() =>
      _ForgotPasswordConfirmDialogState();
}

class _ForgotPasswordConfirmDialogState
    extends State<_ForgotPasswordConfirmDialog> {
  final _formKey = GlobalKey<FormState>();
  final _codeController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _submitting = false;
  String _error = '';

  @override
  void dispose() {
    _codeController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid || _submitting) return;

    setState(() {
      _submitting = true;
      _error = '';
    });

    final result = await PasswordResetService.confirmPasswordReset(
      email: widget.email,
      code: _codeController.text,
      newPassword: _newPasswordController.text,
    );
    if (!mounted) return;

    if (result == PasswordResetConfirmResult.success) {
      Navigator.of(context).pop(result);
    } else {
      setState(() {
        _submitting = false;
        _error = 'forgot_password_reset_failed'.tr();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('forgot_password_confirm_title'.tr()),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'forgot_password_code_sent_to'.tr(args: [widget.email]),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'forgot_password_code_label'.tr(),
                ),
                validator: (value) {
                  if ((value ?? '').trim().isEmpty) {
                    return 'forgot_password_code_required'.tr();
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              Text(
                'forgot_password_password_policy_hint'.tr(),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _newPasswordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'forgot_password_new_password_label'.tr(),
                ),
                onChanged: (_) {
                  if (_confirmPasswordController.text.isNotEmpty) {
                    _formKey.currentState?.validate();
                  }
                },
                validator: (value) {
                  final errorKey = PasswordPolicyValidator.validateResetPassword(
                    value ?? '',
                  );
                  if (errorKey != null) {
                    return errorKey.tr();
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _confirmPasswordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'forgot_password_confirm_password_label'.tr(),
                ),
                validator: (value) {
                  if ((value ?? '').isEmpty) {
                    return 'forgot_password_confirm_password_required'.tr();
                  }
                  if (value != _newPasswordController.text) {
                    return 'forgot_password_passwords_mismatch'.tr();
                  }
                  return null;
                },
              ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _error,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],
            ],
          ),
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
              : Text('forgot_password_confirm_submit'.tr()),
        ),
      ],
    );
  }
}
