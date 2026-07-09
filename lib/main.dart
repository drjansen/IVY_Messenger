import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'login_screen.dart';
import 'main_screen.dart';
import 'matrix_service.dart';
import 'app_config.dart';
import 'firebase_bootstrap.dart';

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
  final String title = data['title'] ?? AppConfig.appDisplayName;
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
  await FirebaseBootstrap.initialize();
  if (!FirebaseBootstrap.isAvailable) {
    return;
  }
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

  await FirebaseBootstrap.initialize();
  await EasyLocalization.ensureInitialized();

  if (FirebaseBootstrap.isAvailable) {
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
  }

  bool sessionRestored = await MatrixService.restoreSession();
  if (sessionRestored) {
    sessionRestored = await MatrixService.validateRestoredSession();
  }

  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('ko'), Locale('en')],
      path: 'assets/langs',
      fallbackLocale: const Locale('ko'),
      startLocale: const Locale('ko'),
      child: IVYApp(sessionRestored: sessionRestored),
    ),
  );
}

class IVYApp extends StatefulWidget {
  final bool sessionRestored;
  const IVYApp({Key? key, required this.sessionRestored}) : super(key: key);

  @override
  State<IVYApp> createState() => _IVYAppState();
}

class _IVYAppState extends State<IVYApp> with WidgetsBindingObserver {
  late bool _sessionRestored;
  String? _sessionNoticeKey;

  @override
  void initState() {
    super.initState();
    _sessionRestored = widget.sessionRestored;
    MatrixService.authEventNoticeKey.addListener(_onAuthEventNotice);
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
    if (FirebaseBootstrap.isAvailable) {
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
  }

  void _onAuthEventNotice() {
    final noticeKey = MatrixService.authEventNoticeKey.value;
    if (noticeKey == null || noticeKey.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _sessionRestored = false;
      _sessionNoticeKey = noticeKey;
    });
    MatrixService.clearAuthEventNotice();
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
    MatrixService.authEventNoticeKey.removeListener(_onAuthEventNotice);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appDisplayName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.blue),
      home: SafeArea(
        child: _sessionRestored
            ? MainScreen(
          accessToken: MatrixService.authToken,
          username: MatrixService.userId,
          cancelNotificationForCurrentChat: cancelNotificationForCurrentChat,
        )
            : LoginScreen(
                sessionNoticeKey: _sessionNoticeKey,
                onSessionNoticeShown: () {
                  if (!mounted) return;
                  setState(() => _sessionNoticeKey = null);
                },
              ),
      ),
      navigatorObservers: [routeObserver],
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
    );
  }
}
