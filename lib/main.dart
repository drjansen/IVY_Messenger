import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'login_screen.dart';
import 'main_screen.dart';
import 'matrix_service.dart';

// 1. ADD THIS CLASS TO TRACK THE CURRENTLY VIEWED CHAT ROOM
class AppState {
  static String? currentChatRoomId;
}

final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();

const String channelId = 'chat_channel';
const String channelName = 'Chat Notifications';
const String channelDescription = 'Notifications for chat messages';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

// 2. THIS IS THE NEW, SIMPLIFIED FUNCTION TO SHOW A SINGLE, REPLACING NOTIFICATION
Future<void> showSimpleNotification(RemoteMessage message) async {
  final data = message.data;
  final String? chatRoomId = data['roomId'] as String? ?? data['chatRoomId'] as String?;
  final String title = data['title'] ?? 'ICS Messenger';
  final String body = data['body'] ?? 'You have a new message';

  // The ID is based on the chat room. This is the key to making notifications replace each other.
  final int notifId = chatRoomId != null ? chatRoomId.hashCode : DateTime.now().millisecondsSinceEpoch;

  const AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
    channelId,
    channelName,
    channelDescription: channelDescription,
    importance: Importance.max,
    priority: Priority.high,
  );
  const NotificationDetails platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);

  await flutterLocalNotificationsPlugin.show(
    id: notifId,
    title: title,
    body: body,
    notificationDetails: platformChannelSpecifics,
    payload: chatRoomId,
  );
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  final InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);

  await flutterLocalNotificationsPlugin.initialize(
    settings: initializationSettings,
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      final String? payload = response.payload;
      if (payload != null) {
        if (kDebugMode) {
          print('🔔 [FCM BG] Notification tapped with payload: $payload');
        }
        // TODO: navigate to chat room with ID = payload
      }
    },
  );
  await showSimpleNotification(message);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await initializeDateFormatting('ko_KR', null);
  Intl.defaultLocale = 'ko_KR';

  await Firebase.initializeApp();
  await EasyLocalization.ensureInitialized();

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  await FirebaseMessaging.instance.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );

  FirebaseMessaging.instance.getToken().then((token) {
    if (token != null) {
      // FCM token obtained — register with push server after login.
    }
  });

  bool sessionRestored = await MatrixService.restoreSession();

  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('ko'), Locale('en')],
      path: 'assets/langs',
      fallbackLocale: const Locale('ko'),
      startLocale: const Locale('ko'),
      child: ICSApp(sessionRestored: sessionRestored),
    ),
  );
}

class ICSApp extends StatefulWidget {
  final bool sessionRestored;
  const ICSApp({Key? key, required this.sessionRestored}) : super(key: key);

  @override
  State<ICSApp> createState() => _ICSAppState();
}

class _ICSAppState extends State<ICSApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
    final InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);

    flutterLocalNotificationsPlugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final String? payload = response.payload;
        if (payload != null) {
          if (kDebugMode) {
            print('🔔 [FCM] Foreground notification tapped with payload: $payload');
          }
          // TODO: navigate to chat room with ID = payload
        }
      },
    );

    // 3. THIS LISTENER NOW CHECKS IF THE USER IS IN THE CHAT ROOM
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final String? chatRoomId = message.data['roomId'] as String? ?? message.data['chatRoomId'] as String?;

      // Only show notification if the user is NOT in the chat room.
      if (chatRoomId != AppState.currentChatRoomId) {
        if (kDebugMode) {
          print('🔔 [FCM] Foreground message for a different room. Showing notification.');
        }
        showSimpleNotification(message);
      } else {
        if (kDebugMode) {
          print('🔔 [FCM] Foreground message for active room. Suppressing notification.');
        }
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      final chatRoomId = message.data['roomId'] as String? ?? message.data['chatRoomId'] as String?;
      if (chatRoomId != null) {
        cancelNotificationForCurrentChat(chatRoomId);
        // TODO: handle navigation to the chat
      }
      if (kDebugMode) {
        print('🔔 [FCM] Notification tapped: ${message.messageId}');
      }
    });
  }

  void cancelNotificationForCurrentChat(String chatRoomId) {
    if (chatRoomId.isNotEmpty) {
      flutterLocalNotificationsPlugin.cancel(
        id: chatRoomId.hashCode,
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ICS Messenger',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.blue),
      home: SafeArea(
        child: widget.sessionRestored
            ? MainScreen(
          accessToken: MatrixService.authToken,
          username: MatrixService.userId,
          cancelNotificationForCurrentChat: cancelNotificationForCurrentChat,
        )
            : const LoginScreen(),
      ),
      navigatorObservers: [routeObserver],
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
    );
  }
}