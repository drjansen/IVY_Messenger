import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

class FirebaseBootstrap {
  static bool _isAvailable = false;

  static bool get isAvailable => _isAvailable;

  static Future<void> initialize() async {
    _isAvailable = false;
    try {
      await Firebase.initializeApp();
      _isAvailable = true;
    } on FirebaseException catch (error) {
      _isAvailable = false;
      assert(() {
        debugPrint(
          'Firebase initialization skipped. Add local platform config files to enable push notifications: $error',
        );
        return true;
      }());
    } catch (error) {
      _isAvailable = false;
      assert(() {
        debugPrint(
          'Firebase initialization skipped due to an unexpected error. Add local platform config files to enable push notifications: $error',
        );
        return true;
      }());
    }
  }
}
