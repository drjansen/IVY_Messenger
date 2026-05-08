import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:easy_localization/easy_localization.dart';

import 'matrix_service.dart';
import 'main_screen.dart';
import 'session_manager.dart';

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
  void initState() {
    super.initState();
    _loadSavedCredentials();
    _loadSavedLocale();
  }

  Future<void> _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUsername = prefs.getString('saved_username');
    final savedPassword = prefs.getString('saved_password');

    if (savedUsername != null && savedPassword != null) {
      setState(() {
        usernameController.text = savedUsername;
        passwordController.text = savedPassword;
        rememberMe = true;
      });
    }
  }

  Future<void> _saveCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    if (rememberMe) {
      await prefs.setString('saved_username', usernameController.text);
      await prefs.setString('saved_password', passwordController.text);
    } else {
      await prefs.remove('saved_username');
      await prefs.remove('saved_password');
    }
  }

  Future<void> _login() async {
    if (!agreedToTerms) return;

    setState(() {
      loading = true;
      error = '';
    });

    final username = usernameController.text.trim();
    final password = passwordController.text;
    final success = await MatrixService.login(
      username,
      password,
    );

    setState(() => loading = false);

    if (success) {
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

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => MainScreen(
            accessToken: MatrixService.authToken,
            username: username,
          ),
        ),
      );
    } else {
      setState(() => error = tr('invalid_credentials'));
    }
  }

  Future<void> _loadSavedLocale() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLocale = prefs.getString('user_locale');
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
    context.setLocale(Locale(newLocale));
    setState(() {
      currentLocale = newLocale;
    });
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