import 'dart:io';
import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';

import 'chat_rooms_tab.dart';
import 'user_bar.dart';
import 'reports/report_screen.dart'; // <-- Import added!
import '../dashboard_screen.dart';
import '../calendar_screen.dart';
import '../ptc_screen.dart';
import 'matrix_service.dart'; // or matrix_service.dart if that is correct
import '../login_screen.dart';
import 'session_manager.dart';

class MainScreen extends StatefulWidget {
  final String accessToken;
  final int initialTab;
  final String username;
  final void Function(String chatRoomId)? cancelNotificationForCurrentChat;

  const MainScreen({
    Key? key,
    required this.accessToken,
    required this.username,
    this.initialTab = 1,
    this.cancelNotificationForCurrentChat,
  }) : super(key: key);

  @override
  _MainScreenState createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late int currentIndex;
  int totalUnread = 0;

  String? avatarUrl;
  String? userName;

  final GlobalKey<DashboardScreenState> dashboardKey =
  GlobalKey<DashboardScreenState>();

  late final List<Widget> screens;

  @override
  void initState() {
    super.initState();
    currentIndex = widget.initialTab;
    _loadUserProfile();
    SessionManager.username = widget.username;

    screens = [
      DashboardScreen(key: dashboardKey),
      ChatRoomsTab(
        accessToken: widget.accessToken,
        onTotalCountChanged: (newTotal) {
          setState(() => totalUnread = newTotal);
        },
        cancelNotificationForCurrentChat: widget.cancelNotificationForCurrentChat,
      ),
      const CalendarScreen(),
      const PtcScreen(),
      const ReportScreen(), // <-- Tab added!
    ];
  }

  String addCacheBuster(String? url) {
    if (url == null) return '';
    final separator = url.contains('?') ? '&' : '?';
    return '$url${separator}v=${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<void> _loadUserProfile() async {
    try {
      final me = await MatrixService.getMe();
      // ignore: avoid_print
      print('Avatar URL: ${me['avatarUrl']}');
      setState(() {
        userName = (me['name'] ?? me['username']) as String?;
        avatarUrl = addCacheBuster(me['avatarUrl'] as String?);
      });
    } catch (e) {
      debugPrint('❌ loadUserProfile: $e');
    }
  }

  Future<void> _changeAvatar(File file) async {
    final ok = await MatrixService.setAvatar(file);
    if (ok) {
      await _loadUserProfile();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('avatar_update_failed'.tr())),
      );
    }
  }

  void _onLogout() {
    debugPrint('UserBar: Logout triggered in MainScreen');
    SessionManager.username = null;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const LoginScreen()),
          (route) => false,
    );
  }

  BoxDecoration _chromeDecoration() {
    return const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFF0B4F24),
          Color(0xFF1E8A46),
          Color(0xFF1E8A46),
          Color(0xFF0A3F1C),
        ],
        stops: [0.0, 0.50, 0.51, 1.0],
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black26,
          blurRadius: 10,
          spreadRadius: 0,
          offset: Offset(0, -4),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedColor = Colors.white;
    final unselectedColor = Colors.white.withOpacity(0.75); // <-- Fixed withOpacity

    return SafeArea(
      child: Scaffold(
        backgroundColor: const Color(0xFFF3F8F4),

        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(76),
          child: UserBar(
            avatarUrl: avatarUrl,
            userName: userName,
            onSettings: null,
            onLogout: _onLogout,
            onChangeAvatar: _changeAvatar,
          ),
        ),
        body: screens[currentIndex],

        bottomSheet: IgnorePointer(
          child: SizedBox(
            height: 10,
            width: double.infinity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.white.withOpacity(0.10),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 1.0],
                ),
              ),
            ),
          ),
        ),

        bottomNavigationBar: DecoratedBox(
          decoration: _chromeDecoration(),
          child: Stack(
            children: [
              BottomNavigationBar(
                currentIndex: currentIndex,
                type: BottomNavigationBarType.fixed,
                backgroundColor: Colors.transparent,
                elevation: 0,
                selectedItemColor: selectedColor,
                unselectedItemColor: unselectedColor,
                onTap: (index) {
                  setState(() => currentIndex = index);
                  if (index == 0) {
                    dashboardKey.currentState?.refreshDashboardData();
                  }
                },
                items: [
                  BottomNavigationBarItem(
                    icon: const Icon(Icons.dashboard),
                    label: tr('tab_dashboard'),
                  ),
                  BottomNavigationBarItem(
                    icon: Stack(
                      children: [
                        const Icon(Icons.chat),
                        if (totalUnread > 0)
                          Positioned(
                            right: 0,
                            top: 0,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(
                                color: Colors.red,
                                shape: BoxShape.circle,
                              ),
                              constraints: const BoxConstraints(
                                minWidth: 16,
                                minHeight: 16,
                              ),
                              child: Text(
                                '$totalUnread',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                      ],
                    ),
                    label: tr('tab_chat'),
                  ),
                  BottomNavigationBarItem(
                    icon: const Icon(Icons.calendar_today),
                    label: tr('tab_calendar'),
                  ),
                  BottomNavigationBarItem(
                    icon: const Icon(Icons.people),
                    label: tr('tab_ptc'),
                  ),
                  BottomNavigationBarItem( // <-- Report tab added!
                    icon: const Icon(Icons.report_problem),
                    label: tr('tab_report'),
                  ),
                ],
              ),

              // Thin top divider line for crisp separation (a thin line above the bar)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: IgnorePointer(
                  child: Container(
                    height: 0.5,
                    color: Colors.white.withOpacity(0.10), // <-- Fixed withOpacity
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}