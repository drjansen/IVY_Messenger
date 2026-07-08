import 'dart:async';
import 'dart:convert'; // ✅ ADDED: For JSON encoding/decoding
import 'dart:math';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:easy_localization/easy_localization.dart';

import 'main.dart'; // for routeObserver
import 'chat_screen.dart';
import 'matrix_service.dart';
import 'firebase_bootstrap.dart';

typedef TotalCountCallback = void Function(int totalUnread);

class ChatRoomsTab extends StatefulWidget {
  final String accessToken;
  final TotalCountCallback onTotalCountChanged;
  final void Function(String chatRoomId)? cancelNotificationForCurrentChat;

  const ChatRoomsTab({
    Key? key,
    required this.accessToken,
    required this.onTotalCountChanged,
    this.cancelNotificationForCurrentChat,
  }) : super(key: key);

  @override
  _ChatRoomsTabState createState() => _ChatRoomsTabState();
}

class _ChatRoomsTabState extends State<ChatRoomsTab>
    with RouteAware, WidgetsBindingObserver {
  List<Map<String, dynamic>> rooms = [];
  Map<String, int> unreadCounts = {};
  Map<String, bool> mutedRooms = {};
  Set<String> newMessageRooms = {};
  bool loading = true;

  // ✅ NEW (Option B): client-computed unread counts (fallback when server unread=0 but alert=true)
  Map<String, int> computedUnreadCounts = {};

  // ✅ NEW: throttle per-room computation to reduce network load
  final Map<String, DateTime> _lastComputedAt = {};
  static const Duration _computeCooldown = Duration(seconds: 30);

  Timer? _pollTimer;
  StreamSubscription<RemoteMessage>? _fcmSub;
  String? _lastOpenedRoom;

  bool _isFetching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeRooms();

    if (FirebaseBootstrap.isAvailable) {
      _fcmSub = FirebaseMessaging.onMessage.listen((msg) {
        // Gate FCM payload inspection behind debug mode — message data and
        // notification bodies must not appear in release logs.
        if (kDebugMode) {
          debugPrint('📩 FCM onMessage data: ${msg.data}');
          debugPrint(
              '📩 FCM onMessage notification: title=${msg.notification?.title} body=${msg.notification?.body}');
        }

        final rid = (msg.data['room_id'] ?? msg.data['rid']) as String?;
        if (kDebugMode) {
          debugPrint('📩 Parsed rid=$rid');
        }

        if (rid != null && mutedRooms[rid] != true) {
          if (mounted) {
            setState(() {
              // ✅ For Option B we still increment locally so UI reacts immediately,
              // but server polling will reconcile later.
              unreadCounts[rid] = (unreadCounts[rid] ?? 0) + 1;
              newMessageRooms.add(rid);
            });
          }
          _notifyTotal();

          // ✅ Trigger a background recompute soon-ish (throttled) so counts become accurate
          _requestComputeForRoom(rid);
        } else {
          if (kDebugMode) {
            debugPrint('📩 No rid found or room muted; not incrementing unread.');
          }
        }
      });
    }
  }

  // ✅ NEW: Main initialization function
  Future<void> _initializeRooms() async {
    await _loadRoomsFromCache();
    await _loadLocalMutes();

    MatrixService.registerPushToken(widget.accessToken);
    _fetchRoomsAndNotify();

    _pollTimer = Timer.periodic(
      const Duration(seconds: 15),
          (_) => _fetchRoomsAndNotify(),
    );
  }

  // ✅ NEW: Helper function to load rooms from local storage
  Future<void> _loadRoomsFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedData = prefs.getString('cached_chat_rooms');
    if (cachedData != null && mounted) {
      try {
        final decodedData = jsonDecode(cachedData) as List;
        setState(() {
          rooms = decodedData.cast<Map<String, dynamic>>();
          loading = rooms.isEmpty;
        });
      } catch (e) {
        if (kDebugMode) {
          debugPrint("Error decoding cached rooms: $e");
        }
      }
    }
  }

  // ✅ NEW: Helper function to save rooms to local storage
  Future<void> _saveRoomsToCache(List<Map<String, dynamic>> roomsToCache) async {
    final prefs = await SharedPreferences.getInstance();
    final dataToCache = jsonEncode(roomsToCache);
    await prefs.setString('cached_chat_rooms', dataToCache);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _fcmSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _fetchRoomsAndNotify();
    }
  }

  @override
  void didPopNext() {
    if (_lastOpenedRoom != null) {
      if (mounted) {
        setState(() {
          newMessageRooms.remove(_lastOpenedRoom);
          _lastOpenedRoom = null;
        });
      }
      _notifyTotal();
    }
    _fetchRoomsAndNotify();
  }

  Future<void> _loadLocalMutes() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('muted_rooms') ?? [];
    if (mounted) {
      setState(() => mutedRooms = {for (var id in list) id: true});
    }
  }

  Future<void> _saveLocalMutes() async {
    final prefs = await SharedPreferences.getInstance();
    final list =
    mutedRooms.entries.where((e) => e.value).map((e) => e.key).toList();
    await prefs.setStringList('muted_rooms', list);
  }

  // ✅ NEW (Option B): schedule a compute attempt for a room id (throttled)
  void _requestComputeForRoom(String roomId) {
    // We don't know the roomType here; we will compute from the current rooms list when possible.
    // Just kick a refresh (throttled compute happens inside _fetchRoomsAndNotify and _computeLocalUnreadForRoom).
    Future.delayed(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _fetchRoomsAndNotify();
    });
  }

  // ✅ NEW (Option B): compute unread count from message timestamps vs last_read_<rid>
  // - counts messages AFTER last_read
  // - excludes own messages
  // - only looks at last 50 messages (same as fetchMessages)
  Future<int> _computeLocalUnreadForRoom({
    required String roomId,
    required String roomType,
    required bool includeOwnMessages,
  }) async {
    final now = DateTime.now();
    final lastAt = _lastComputedAt[roomId];
    if (lastAt != null && now.difference(lastAt) < _computeCooldown) {
      return computedUnreadCounts[roomId] ?? 0;
    }
    _lastComputedAt[roomId] = now;

    final prefs = await SharedPreferences.getInstance();
    final lastReadTs = prefs.getInt('last_read_$roomId') ?? 0;

    final msgs = await MatrixService.fetchMessages(roomId, roomType);
    if (msgs.isEmpty) return 0;

    final myUserId = MatrixService.userId;

    int count = 0;
    for (final m in msgs) {
      final ts = (m['timestamp'] as int?) ?? 0;
      if (ts <= lastReadTs) continue;

      final senderId = m['senderId']?.toString() ?? '';
      final isOwn = senderId.isNotEmpty && senderId == myUserId;
      if (!includeOwnMessages && isOwn) continue;

      count++;
    }

    return count;
  }

  Future<void> _fetchRoomsAndNotify() async {
    if (_isFetching || !mounted) return;
    _isFetching = true;

    if (mounted && rooms.isEmpty) {
      setState(() => loading = true);
    }

    final prefs = await SharedPreferences.getInstance();
    final localMutes = prefs.getStringList('muted_rooms') ?? [];

    List<Map<String, dynamic>> fetched;
    try {
      fetched = await MatrixService.fetchJoinedRoomIds(widget.accessToken);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ fetchRooms error: $e');
      }
      if (mounted) {
        setState(() => loading = false);
      }
      _isFetching = false;
      return;
    }

    if (!mounted) {
      _isFetching = false;
      return;
    }

    await _saveRoomsToCache(fetched);

    final counts = <String, int>{};
    final mutes = <String, bool>{};
    final computed = Map<String, int>.from(computedUnreadCounts); // keep previous

    // ✅ Option B settings:
    // - Do NOT count own messages as unread (typical UX)
    const bool includeOwnMessages = false;

    // ✅ Compute local counts ONLY when:
    // - server unread == 0
    // - server alert == true
    // This keeps network usage reasonable.
    final computeFutures = <Future<void>>[];

    for (var r in fetched) {
      final id = r['id'] as String;
      final isMuted = localMutes.contains(id);
      mutes[id] = isMuted;

      final serverUnread = r['unread'] as int? ?? 0;
      final alert = r['alert'] as bool? ?? false;
      final roomType = r['type'] as String? ?? '';

      // Track "new message room" highlighting
      if ((unreadCounts[id] ?? 0) == 0 && serverUnread > 0) {
        newMessageRooms.add(id);
      }

      // Default: use server unread
      counts[id] = serverUnread;

      // ✅ Option B: compute count when server doesn't give a number but signals activity
      if (serverUnread == 0 && alert && !isMuted) {
        computeFutures.add(() async {
          final localCount = await _computeLocalUnreadForRoom(
            roomId: id,
            roomType: roomType,
            includeOwnMessages: includeOwnMessages,
          );
          computed[id] = localCount;
        }());
      } else {
        // If server provides a number or there is no alert, clear computed fallback
        computed.remove(id);
      }
    }

    // Wait for local computations to finish (bounded by throttling + only alert rooms)
    if (computeFutures.isNotEmpty) {
      await Future.wait(computeFutures);
    }

    if (!mounted) {
      _isFetching = false;
      return;
    }

    setState(() {
      rooms = fetched;
      unreadCounts = counts;
      mutedRooms = mutes;
      computedUnreadCounts = computed;
      loading = false;
    });

    _isFetching = false;
    _notifyTotal();
  }

  void _notifyTotal() {
    // ✅ Include computed counts when server unread is 0 but alert=true (computed > 0)
    int total = 0;

    for (final room in rooms) {
      final id = room['id'] as String;
      if (mutedRooms[id] == true) continue;

      final serverUnread = unreadCounts[id] ?? 0;
      if (serverUnread > 0) {
        total += serverUnread;
        continue;
      }

      final alert = room['alert'] as bool? ?? false;
      if (alert) {
        total += (computedUnreadCounts[id] ?? 0);
      }
    }

    widget.onTotalCountChanged(total);
  }

  Future<void> _toggleMute(String roomId) async {
    final next = !(mutedRooms[roomId] ?? false);

    if (mounted) {
      setState(() => mutedRooms[roomId] = next);
    }
    await _saveLocalMutes();

    final prefs = await SharedPreferences.getInstance();
    final names = prefs.getStringList('muted_room_names') ?? [];
    final raw = rooms.firstWhere((r) => r['id'] == roomId)['name'] as String;
    final name = raw.replaceAll('_', ' ');
    if (next) {
      if (!names.contains(name)) names.add(name);
    } else {
      names.remove(name);
    }
    await prefs.setStringList('muted_room_names', names);

    final ok = await MatrixService.setRoomMute(roomId, next);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('failed_update_server_mute'.tr())),
      );
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            next ? 'push_notifications_muted'.tr() : 'push_notifications_unmuted'.tr(),
          ),
        ),
      );
    }

    _notifyTotal();
  }

  @override
  Widget build(BuildContext context) {
    return loading && rooms.isEmpty
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
      onRefresh: _fetchRoomsAndNotify,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: rooms.length,
        itemBuilder: (ctx, i) {
          final room = rooms[i];
          final id = room['id'] as String;
          final rawName = room['name'] as String;
          final displayName = rawName.replaceAll('_', ' ');

          final serverUnread = unreadCounts[id] ?? 0;
          final muted = mutedRooms[id] ?? false;
          final isNew = newMessageRooms.contains(id);
          final alert = room['alert'] as bool? ?? false;

          // ✅ Option B: If server doesn't provide a number but there is activity, use computed count.
          final computedUnread = computedUnreadCounts[id] ?? 0;

          final int displayUnread =
          serverUnread > 0 ? serverUnread : (alert ? computedUnread : 0);

          // ✅ If there is activity but count computes to 0 (e.g., only old messages),
          // keep a dot as a fallback so the user still sees "something happened".
          final bool showDotOnly = (serverUnread == 0) && alert && (computedUnread == 0);

          Color? bg;
          if (isNew && !muted) {
            bg = Colors.green[100];
          } else if ((displayUnread > 0 || alert) && !muted) {
            bg = Colors.yellow[100];
          }

          return Card(
            elevation: 2,
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: bg,
            child: ListTile(
              title: Text(
                displayName,
                style: TextStyle(
                  fontWeight: (displayUnread > 0 || (alert && !muted))
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ✅ Show numeric badge when we have a number (server or computed)
                  if (displayUnread > 0 && !muted)
                    Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '$displayUnread',
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    )
                  // ✅ Otherwise show a dot when alert=true
                  else if (!muted && showDotOnly)
                    Container(
                      margin: const EdgeInsets.only(right: 14),
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                    ),
                  IconButton(
                    icon: Icon(muted ? Icons.notifications_off : Icons.notifications),
                    onPressed: () => _toggleMute(id),
                  ),
                ],
              ),
              onTap: () async {
                _lastOpenedRoom = id;
                await MatrixService.markRoomAsRead(id);

                final msgs =
                await MatrixService.fetchMessages(id, room['type'] as String);
                if (msgs.isNotEmpty) {
                  final lastTs =
                  msgs.map((m) => m['timestamp'] as int).reduce(max);
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setInt('last_read_$id', lastTs);
                }

                if (mounted) {
                  setState(() {
                    unreadCounts[id] = 0;
                    computedUnreadCounts.remove(id);
                    newMessageRooms.remove(id);
                  });
                }
                _notifyTotal();

                if (widget.cancelNotificationForCurrentChat != null) {
                  widget.cancelNotificationForCurrentChat!(id);
                }

                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(
                      roomId: id,
                      roomName: displayName,
                      roomType: room['type'] as String,
                      accessToken: widget.accessToken,
                    ),
                  ),
                );

                // Refresh after returning, so server + computed counts reconcile
                _fetchRoomsAndNotify();
              },
            ),
          );
        },
      ),
    );
  }
}