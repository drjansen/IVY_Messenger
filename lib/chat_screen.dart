import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_emoji/flutter_emoji.dart';
import 'package:path/path.dart' show basename;
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:open_file/open_file.dart';
import 'package:animated_emoji/animated_emoji.dart';
import 'package:http/http.dart' as http;
import 'package:collection/collection.dart';

import 'matrix_service.dart';
import 'main.dart';
import 'widgets/emoji_picker.dart';
import 'app_config.dart';

Future<bool> requestStoragePermission() async {
  if (kIsWeb) {
    return true;
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final sdk = androidInfo.version.sdkInt;
    if (sdk >= 33) {
      final status = await Permission.photos.request();
      return status.isGranted;
    } else {
      final status = await Permission.storage.request();
      return status.isGranted;
    }
  } else if (defaultTargetPlatform == TargetPlatform.iOS) {
    final status = await Permission.photosAddOnly.request();
    return status.isGranted;
  }
  return true;
}

class UserNameCache {
  static final Map<String, String> _cache = {};
  static DateTime? _lastFetch;
  static const _fetchCooldown = Duration(milliseconds: 300);

  static Future<String> getRealName({
    required String username,
    required String authToken,
    required String userId,
    required String baseUrl,
  }) async {
    if (_cache.containsKey(username)) return _cache[username]!;

    if (_lastFetch != null &&
        DateTime.now().difference(_lastFetch!) < _fetchCooldown) {
      return username;
    }
    _lastFetch = DateTime.now();

    try {
      final url = Uri.parse('$baseUrl/api/v1/users.info?username=$username');
      final resp = await http.get(url, headers: {
        'X-Auth-Token': authToken,
        'X-User-Id': userId,
      });
      await MatrixService.handlePotentialRevokedSessionResponse(resp);

      if (resp.statusCode == 429) {
        if (kDebugMode) {
          print('⚠️ UserNameCache rate limited for $username');
        }
        return username;
      }

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        final realName = data['user']?['name'] ?? username;
        _cache[username] = realName;
        return realName;
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ UserNameCache error for $username: $e');
      }
    }
    return username;
  }

  static void setRealName(String username, String realName) {
    _cache[username] = realName;
  }

  static Future<void> preloadNames({
    required Set<String> usernames,
    required String authToken,
    required String userId,
    required String baseUrl,
  }) async {
    for (final username in usernames) {
      if (!_cache.containsKey(username)) {
        await getRealName(
          username: username,
          authToken: authToken,
          userId: userId,
          baseUrl: baseUrl,
        );
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }
}

class MessageGroup {
  final List<Map<String, dynamic>> messages;
  MessageGroup(this.messages);
  String get senderId => messages.first['senderId'] as String;
  bool get isOwn => senderId == MatrixService.userId;

  bool get isImageOnly => messages.every((m) =>
  m['imageUrl'] != null &&
      (m['body'] as String).trim().isEmpty &&
      _isImageExtensionStatic(m['imageUrl']) &&
      (m['animatedEmoji'] == null || m['animatedEmoji'].toString().isEmpty));
}

bool _isImageExtensionStatic(String url) {
  final ext = basename(Uri.parse(url).path).toLowerCase();
  return ext.endsWith('.png') ||
      ext.endsWith('.jpg') ||
      ext.endsWith('.jpeg') ||
      ext.endsWith('.gif');
}

final attachmentCache = CacheManager(
  Config(
    'attachmentCache',
    // Reduced from 30 days / 500 objects to limit local retention of
    // potentially sensitive media attachments.
    stalePeriod: const Duration(days: 7),
    maxNrOfCacheObjects: 100,
  ),
);

const Map<String, AnimatedEmojiData> _emojiNameMap = {
  'thumbsUp': AnimatedEmojis.thumbsUp,
  'laughing': AnimatedEmojis.laughing,
  'fire': AnimatedEmojis.fire,
  'partyPopper': AnimatedEmojis.partyPopper,
  'smile': AnimatedEmojis.smile,
  'sad': AnimatedEmojis.sad,
  'starStruck': AnimatedEmojis.starStruck,
  'clap': AnimatedEmojis.clap,
  'wink': AnimatedEmojis.wink,
  'eyes': AnimatedEmojis.eyes,
  'rocket': AnimatedEmojis.rocket,
  'cool': AnimatedEmojis.cool,
  'angry': AnimatedEmojis.angry,
  'surprised': AnimatedEmojis.surprised,
  'rollingEyes': AnimatedEmojis.rollingEyes,
  'sleepy': AnimatedEmojis.sleepy,
  'sweat': AnimatedEmojis.sweat,
};

final Map<String, AnimatedEmojiData> unicodeToAnimatedEmoji = {
  "👍": AnimatedEmojis.thumbsUp,
  "😂": AnimatedEmojis.laughing,
  "🔥": AnimatedEmojis.fire,
  "🎉": AnimatedEmojis.partyPopper,
  "😄": AnimatedEmojis.smile,
  "😢": AnimatedEmojis.sad,
  "🤩": AnimatedEmojis.starStruck,
  "👏": AnimatedEmojis.clap,
  "😉": AnimatedEmojis.wink,
  "👀": AnimatedEmojis.eyes,
  "🚀": AnimatedEmojis.rocket,
  "😎": AnimatedEmojis.cool,
  "😡": AnimatedEmojis.angry,
  "😲": AnimatedEmojis.surprised,
  "🙄": AnimatedEmojis.rollingEyes,
  "😴": AnimatedEmojis.sleepy,
  "😅": AnimatedEmojis.sweat,
};

bool isSingleEmoji(String text) {
  final trimmed = text.trim();
  return unicodeToAnimatedEmoji.containsKey(trimmed);
}

String _animatedEmojiName(AnimatedEmojiData emoji) {
  return _emojiNameMap.entries
      .firstWhere(
        (e) => e.value == emoji,
    orElse: () => const MapEntry('smile', AnimatedEmojis.smile),
  )
      .key;
}

/// Ensures that image uploads have a filename with an extension.
/// Some Android pickers return names without extensions, which breaks MIME inference.
String _ensureImageExtension(String filename) {
  final name = filename.trim();
  if (name.isEmpty) return 'image.jpg';

  final lower = name.toLowerCase();
  final hasExt = lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.jfif');

  return hasExt ? name : '$name.jpg';
}

/// Hybrid image loader:
/// - fast path: CachedNetworkImage with headers + cache manager
/// - fallback: fetch bytes via MatrixService.fetchAuthedBytes and Image.memory
/// - never throws
class SafeRocketChatImage extends StatefulWidget {
  final String url;
  final double width;
  final double height;
  final BoxFit fit;

  const SafeRocketChatImage({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    this.fit = BoxFit.cover,
  });

  @override
  State<SafeRocketChatImage> createState() => _SafeRocketChatImageState();
}

class _SafeRocketChatImageState extends State<SafeRocketChatImage> {
  bool _useBytesFallback = false;

  @override
  Widget build(BuildContext context) {
    if (!_useBytesFallback) {
      return CachedNetworkImage(
        cacheManager: attachmentCache,
        imageUrl: widget.url,
        httpHeaders: {
          'X-Auth-Token': MatrixService.authToken,
          'X-User-Id': MatrixService.userId,
        },
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        placeholder: (_, __) => SizedBox(
          width: widget.width,
          height: widget.height,
          child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
        errorWidget: (_, __, ___) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _useBytesFallback = true);
          });
          return SizedBox(
            width: widget.width,
            height: widget.height,
            child: const Center(child: Icon(Icons.broken_image)),
          );
        },
      );
    }

    return FutureBuilder<Uint8List?>(
      future: MatrixService.fetchAuthedBytes(widget.url),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return SizedBox(
            width: widget.width,
            height: widget.height,
            child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }

        final bytes = snap.data;
        if (bytes == null) {
          return SizedBox(
            width: widget.width,
            height: widget.height,
            child: const Center(child: Icon(Icons.broken_image)),
          );
        }

        return Image.memory(
          bytes,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          errorBuilder: (_, __, ___) => SizedBox(
            width: widget.width,
            height: widget.height,
            child: const Center(child: Icon(Icons.broken_image)),
          ),
        );
      },
    );
  }
}

class ChatScreen extends StatefulWidget {
  final String roomId, roomName, roomType, accessToken;
  const ChatScreen({
    super.key,
    required this.roomId,
    required this.roomName,
    required this.roomType,
    required this.accessToken,
  });

  @override
  _ChatScreenState createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with RouteAware, WidgetsBindingObserver {
  List<Map<String, dynamic>> _rawMessages = [];
  List<MessageGroup> _groups = [];
  final Map<String, String> _localReactions = {};
  Set<String> _deletedMessageIds = {};
  String? _pinnedEventId;
  Map<String, dynamic>? _pinnedMessage;

  String? _replyToEventId;
  String? _replyToSender;
  String? _replyToText;

  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();
  final EmojiParser _emojiParser = EmojiParser();
  bool loading = false;
  bool _shouldAutoScroll = true;
  bool _isFetching = false;

  bool _isUploading = false;

  Timer? _refreshDebounce;
  Timer? _pollTimer;
  StreamSubscription<RemoteMessage>? _fcmSub;

  static const List<String> _reactions = ['👍', '❤️', '😂', '😮', '😢', '😡'];

  final List<AnimatedEmojiData> _popularEmojis = [
    AnimatedEmojis.thumbsUp,
    AnimatedEmojis.laughing,
    AnimatedEmojis.fire,
    AnimatedEmojis.partyPopper,
    AnimatedEmojis.smile,
    AnimatedEmojis.sad,
    AnimatedEmojis.starStruck,
    AnimatedEmojis.clap,
    AnimatedEmojis.wink,
    AnimatedEmojis.eyes,
    AnimatedEmojis.rocket,
    AnimatedEmojis.cool,
    AnimatedEmojis.angry,
    AnimatedEmojis.surprised,
    AnimatedEmojis.rollingEyes,
    AnimatedEmojis.sleepy,
    AnimatedEmojis.sweat,
  ];

  final Map<String, String> _realNameCache = {};

  void _requestRefresh({Duration debounce = const Duration(milliseconds: 600)}) {
    if (!mounted) return;
    if (_isUploading) return;

    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(debounce, () {
      if (!mounted) return;
      if (_isUploading) return;
      _fetchNewMessages();
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;
      final cur = _scrollController.position.pixels;
      _shouldAutoScroll = cur <= 50;
    });

    MatrixService.markRoomAsRead(widget.roomId);
    _loadMessages();

    _pollTimer = Timer.periodic(
      const Duration(seconds: 60),
          (_) => _requestRefresh(debounce: const Duration(milliseconds: 400)),
    );

    _fcmSub = FirebaseMessaging.onMessage.listen(
          (_) => _requestRefresh(debounce: const Duration(milliseconds: 400)),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    MatrixService.markRoomAsRead(widget.roomId);
    if (_rawMessages.isNotEmpty) {
      final lastTs = _rawMessages.map((m) => m['timestamp'] as int).reduce(max);
      SharedPreferences.getInstance().then((prefs) {
        prefs.setInt('last_read_${widget.roomId}', lastTs);
      });
    }
    _pollTimer?.cancel();
    _fcmSub?.cancel();
    _refreshDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    routeObserver.unsubscribe(this);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _requestRefresh(debounce: const Duration(milliseconds: 200));
    }
  }

  @override
  void didPopNext() {
    _requestRefresh(debounce: const Duration(milliseconds: 200));
  }

  Future<void> _loadMessages() async {
    if (mounted) {
      setState(() => loading = true);
    }
    final prefs = await SharedPreferences.getInstance();

    _deletedMessageIds =
        (prefs.getStringList('deleted_msgs_${widget.roomId}') ?? []).toSet();
    _pinnedEventId = prefs.getString('pinned_${widget.roomId}');

    final fetched = await MatrixService.fetchMessages(widget.roomId, widget.roomType);

    final uniqueUsernames = <String>{};
    for (var m in fetched) {
      if (m['sender'] != null) uniqueUsernames.add(m['sender']);
    }

    final namesToLookup =
    uniqueUsernames.where((u) => !_realNameCache.containsKey(u)).toSet();
    if (namesToLookup.isNotEmpty) {
      await UserNameCache.preloadNames(
        usernames: namesToLookup,
        authToken: MatrixService.authToken,
        userId: MatrixService.userId,
        baseUrl: AppConfig.chatBaseUrl,
      );

      for (final username in namesToLookup) {
        final realName = await UserNameCache.getRealName(
          username: username,
          authToken: MatrixService.authToken,
          userId: MatrixService.userId,
          baseUrl: AppConfig.chatBaseUrl,
        );
        _realNameCache[username] = realName;
      }
    }

    for (var m in fetched) {
      final sender = m['sender'];
      m['realName'] = _realNameCache[sender] ?? sender;
    }

    _rawMessages = fetched
        .where((m) => !_deletedMessageIds.contains(m['event_id'] as String))
        .toList();
    _groupMessages();

    _localReactions.clear();
    for (var m in _rawMessages) {
      final mid = m['event_id'] as String;
      final r = prefs.getString('reaction_$mid');
      if (r != null) _localReactions[mid] = r;
    }

    if (_pinnedEventId != null) {
      _pinnedMessage = _rawMessages.firstWhereOrNull(
            (m) => m['event_id'] == _pinnedEventId,
      );
    }

    if (mounted) {
      setState(() => loading = false);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.minScrollExtent);
      }
    });
  }

  Future<void> _fetchNewMessages() async {
    if (_isUploading) return;
    if (_isFetching || !mounted) return;
    _isFetching = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      _deletedMessageIds =
          (prefs.getStringList('deleted_msgs_${widget.roomId}') ?? []).toSet();

      final fetched = await MatrixService.fetchMessages(widget.roomId, widget.roomType);
      final filtered = fetched
          .where((m) => !_deletedMessageIds.contains(m['event_id'] as String))
          .toList();

      final uniqueUsernames = <String>{};
      for (var m in filtered) {
        if (m['sender'] != null) uniqueUsernames.add(m['sender']);
      }

      for (final username in uniqueUsernames) {
        if (!_realNameCache.containsKey(username)) {
          final realName = await UserNameCache.getRealName(
            username: username,
            authToken: MatrixService.authToken,
            userId: MatrixService.userId,
            baseUrl: AppConfig.chatBaseUrl,
          );
          _realNameCache[username] = realName;
          UserNameCache.setRealName(username, realName);
        }
      }

      for (var m in filtered) {
        final sender = m['sender'];
        m['realName'] = _realNameCache[sender] ?? sender;
      }

      if (!listEquals(filtered, _rawMessages)) {
        _rawMessages = filtered;
        _groupMessages();

        _localReactions.clear();
        for (var m in _rawMessages) {
          final mid = m['event_id'] as String;
          final r = prefs.getString('reaction_$mid');
          if (r != null) _localReactions[mid] = r;
        }

        if (_pinnedEventId != null) {
          _pinnedMessage = _rawMessages.firstWhereOrNull(
                (m) => m['event_id'] == _pinnedEventId,
          );
        }

        if (mounted) {
          setState(() {});
        }
        if (_shouldAutoScroll && _scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.minScrollExtent);
        }
      }
    } finally {
      if (mounted) {
        _isFetching = false;
      }
    }
  }

  void _groupMessages() {
    final groups = <MessageGroup>[];
    for (var m in _rawMessages) {
      final imageOnly = m['imageUrl'] != null &&
          (m['body'] as String).trim().isEmpty &&
          _isImageExtension(m['imageUrl']) &&
          (m['animatedEmoji'] == null || m['animatedEmoji'].toString().isEmpty);

      if (imageOnly &&
          groups.isNotEmpty &&
          groups.last.isImageOnly &&
          groups.last.senderId == m['senderId']) {
        groups.last.messages.add(m);
      } else {
        groups.add(MessageGroup([m]));
      }
    }
    _groups = groups;
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    if (mounted) {
      setState(() => loading = true);
    }

    final ok = await MatrixService.sendMessage(
      widget.roomId,
      text,
      threadId: _replyToEventId,
    );

    if (ok) {
      _messageController.clear();
      await _loadMessages();
      if (mounted) {
        setState(() {
          _replyToEventId = null;
          _replyToSender = null;
          _replyToText = null;
        });
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to send message. Please try again.')),
        );
      }
    }
    if (mounted) {
      setState(() => loading = false);
    }
  }

  void _insertAtCursor(String text) {
    final controller = _messageController;
    final textValue = controller.text;
    final selection = controller.selection;
    if (selection.start < 0 || selection.end < 0) {
      final newText = textValue + text;
      controller.value = controller.value.copyWith(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
      return;
    }
    final newText = textValue.replaceRange(
      selection.start,
      selection.end,
      text,
    );
    final newSelectionIndex = selection.start + text.length;
    controller.value = controller.value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: newSelectionIndex),
    );
  }

  Future<void> _showEmojiPicker() async {
    final emojiName = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => const AnimatedEmojiPicker(),
    );
    if (emojiName != null && emojiName.isNotEmpty) {
      final emojiData = _emojiNameMap[emojiName] ?? AnimatedEmojis.smile;
      final unicode = emojiData.toUnicodeEmoji();
      _insertAtCursor(unicode);
    }
  }

  void _showPlusMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('Attach File'),
              onTap: () {
                Navigator.pop(ctx);
                _pickFilesAndUpload();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo),
              title: const Text('Attach Media'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImagesAndUpload();
              },
            ),
            ListTile(
              leading: const Icon(Icons.emoji_emotions),
              title: const Text('Emoji'),
              onTap: () {
                Navigator.pop(ctx);
                _showEmojiPicker();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImagesAndUpload() async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Image picking is not supported on web yet.')),
      );
      return;
    }

    // Request permission before attempting to read images.
    final permOk = await requestStoragePermission();
    if (!permOk) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Storage/photos permission denied')),
        );
      }
      return;
    }

    final picks = await _picker.pickMultiImage(imageQuality: 100);
    if (picks.isEmpty) return;

    _isUploading = true;
    if (mounted) setState(() => loading = true);

    try {
      for (final x in picks) {
        try {
          final path = x.path;
          final rawName = x.name.isNotEmpty ? x.name : basename(path);
          final name = _ensureImageExtension(rawName);

          bool ok = false;

          // ✅ 1) Prefer bytes upload first (works with Android Photo Picker/MediaStore)
          try {
            final bytes = await x.readAsBytes();
            if (kDebugMode) {
              print('📸 uploadBytes -> name=$name bytes=${bytes.length} path=$path');
            }
            ok = await MatrixService.uploadBytes(widget.roomId, bytes, name);
          } catch (e) {
            if (kDebugMode) {
              print('⚠️ uploadBytes failed for $name: $e');
            }
          }

          // ✅ 2) Fallback to path upload (only if bytes route failed and file path is usable)
          if (!ok && path.isNotEmpty) {
            try {
              final f = File(path);
              final exists = await f.exists();
              if (kDebugMode) {
                print('📸 uploadFile fallback -> name=$name path=$path exists=$exists');
              }
              if (exists) {
                ok = await MatrixService.uploadFile(widget.roomId, path);
              }
            } catch (e) {
              if (kDebugMode) {
                print('⚠️ uploadFile fallback failed for $name path=$path: $e');
              }
            }
          }

          if (!ok && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to upload: $name')),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error uploading ${x.name}: $e')),
            );
          }
        }
      }
    } finally {
      _isUploading = false;
      if (mounted) setState(() => loading = false);
      _requestRefresh(debounce: const Duration(seconds: 1));
    }
  }

  Future<void> _pickFilesAndUpload() async {
    final files = await openFiles();
    if (files.isEmpty) return;

    _isUploading = true;
    if (mounted) setState(() => loading = true);

    try {
      for (var f in files) {
        try {
          final ok = await MatrixService.uploadFile(widget.roomId, f.path);
          if (!ok && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to upload: ${basename(f.path)}')),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error uploading ${basename(f.path)}: $e')),
            );
          }
        }
      }
    } finally {
      _isUploading = false;
      if (mounted) setState(() => loading = false);
      _requestRefresh(debounce: const Duration(seconds: 1));
    }
  }

  Future<void> _showMessageOptions(
      String eventId,
      String body,
      String sender,
      bool isOwn,
      int timestamp,
      ) async {
    final prefs = await SharedPreferences.getInstance();
    final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(timestamp));
    final canDeleteEveryone = age <= const Duration(minutes: 5);

    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: _reactions.map((emoji) {
                  return GestureDetector(
                    onTap: () async {
                      Navigator.pop(ctx);
                      final short = _emojiParser.unemojify(emoji).replaceAll(':', '');
                      final ok = await MatrixService.reactToMessage(eventId, short);
                      if (ok && mounted) {
                        await prefs.setString('reaction_$eventId', emoji);
                        setState(() => _localReactions[eventId] = emoji);
                      }
                    },
                    child: Text(emoji, style: const TextStyle(fontSize: 28)),
                  );
                }).toList(),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: body));
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.select_all),
              title: const Text('Select and Copy'),
              onTap: () {
                Navigator.pop(ctx);
                showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Select text'),
                    content: SelectableText(body),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(ctx);
                if (mounted) {
                  setState(() {
                    _replyToEventId = eventId;
                    _replyToSender = isOwn ? 'Me' : sender;
                    _replyToText = body;
                  });
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.push_pin),
              title: const Text('Pin Comment'),
              onTap: () async {
                Navigator.pop(ctx);
                await prefs.setString('pinned_${widget.roomId}', eventId);
                if (mounted) {
                  setState(() {
                    _pinnedEventId = eventId;
                    _pinnedMessage = _rawMessages.firstWhere(
                          (m) => m['event_id'] == eventId,
                    );
                  });
                }
              },
            ),
            if (isOwn) ...[
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete (Me)'),
                onTap: () async {
                  Navigator.pop(ctx);
                  _deletedMessageIds.add(eventId);
                  await prefs.setStringList(
                    'deleted_msgs_${widget.roomId}',
                    _deletedMessageIds.toList(),
                  );
                  if (mounted) {
                    setState(() {
                      _rawMessages.removeWhere((m) => m['event_id'] == eventId);
                      _groupMessages();
                    });
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_forever),
                title: const Text('Delete (Everyone)'),
                subtitle: canDeleteEveryone ? null : const Text('Allowed only within 5 minutes'),
                enabled: canDeleteEveryone,
                onTap: canDeleteEveryone
                    ? () async {
                  Navigator.pop(ctx);
                  final ok =
                  await MatrixService.deleteMessage(widget.roomId, eventId);
                  if (ok) {
                    _deletedMessageIds.add(eventId);
                    await prefs.setStringList(
                      'deleted_msgs_${widget.roomId}',
                      _deletedMessageIds.toList(),
                    );
                    if (mounted) {
                      setState(() {
                        _rawMessages.removeWhere((m) => m['event_id'] == eventId);
                        _groupMessages();
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Deleted for everyone')),
                      );
                    }
                  } else {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Failed to delete on server')),
                      );
                    }
                  }
                }
                    : null,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _fmt(int ts) =>
      DateFormat('MMM d, yyyy, hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(ts));

  void _openGallery(List<String> urls, int initialIndex) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ImageGalleryPage(images: urls, initialIndex: initialIndex),
      ),
    );
  }

  bool _isGif(String url) => url.toLowerCase().endsWith('.gif');

  bool _isImageExtension(String url) {
    final ext = basename(Uri.parse(url).path).toLowerCase();
    return ext.endsWith('.png') ||
        ext.endsWith('.jpg') ||
        ext.endsWith('.jpeg') ||
        ext.endsWith('.gif');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.roomName)),
      body: SafeArea(
        child: Column(
          children: [
            if (_pinnedMessage != null) ...[
              Container(
                color: Colors.yellow[100],
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    const Icon(Icons.push_pin),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _emojiParser.emojify(_pinnedMessage!['body'] as String),
                        style: const TextStyle(fontStyle: FontStyle.italic),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () async {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.remove('pinned_${widget.roomId}');
                        if (mounted) {
                          setState(() {
                            _pinnedEventId = null;
                            _pinnedMessage = null;
                          });
                        }
                      },
                    ),
                  ],
                ),
              ),
            ],
            Expanded(
              child: loading && _groups.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                controller: _scrollController,
                reverse: true,
                itemCount: _groups.length,
                itemBuilder: (ctx, i) {
                  final grp = _groups[_groups.length - 1 - i];

                  if (grp.isImageOnly) {
                    final urls =
                    grp.messages.map((m) => m['imageUrl'] as String).toList();

                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: Align(
                        alignment: grp.isOwn
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          decoration: BoxDecoration(
                            color: grp.isOwn ? Colors.blue[100] : Colors.grey[300],
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.all(8),
                          child: Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: grp.messages.asMap().entries.map((e) {
                              final idx = e.key;
                              final m = e.value;
                              final eventId = m['event_id'] as String;
                              final isOwn = m['senderId'] == MatrixService.userId;
                              final body = _emojiParser.emojify(m['body'] as String);
                              final ts = m['timestamp'] as int;
                              final sender = m['realName'] ?? m['sender'];
                              final reaction = _localReactions[eventId];

                              if (m['animatedEmoji'] != null &&
                                  m['animatedEmoji'].toString().isNotEmpty) {
                                final emojiData =
                                    _emojiNameMap[m['animatedEmoji'] as String] ??
                                        AnimatedEmojis.smile;
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 4,
                                  ),
                                  child: Align(
                                    alignment: isOwn
                                        ? Alignment.centerRight
                                        : Alignment.centerLeft,
                                    child: AnimatedEmoji(emojiData, size: 150),
                                  ),
                                );
                              }

                              final url = m['imageUrl'] as String;

                              return GestureDetector(
                                onTap: () => _openGallery(urls, idx),
                                onLongPress: () =>
                                    _showMessageOptions(eventId, body, sender, isOwn, ts),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: _isGif(url)
                                          ? Image.network(
                                        url,
                                        width: 100,
                                        height: 100,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => const Icon(
                                          Icons.broken_image,
                                          size: 40,
                                        ),
                                      )
                                          : SafeRocketChatImage(
                                        url: url,
                                        width: 100,
                                        height: 100,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                    if (reaction != null) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        reaction,
                                        style: const TextStyle(fontSize: 16),
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    );
                  }

                  return Column(
                    children: grp.messages.map((m) {
                      final eventId = m['event_id'] as String;
                      final isOwn = m['senderId'] == MatrixService.userId;
                      final body = _emojiParser.emojify(m['body'] as String);
                      final imageUrl = m['imageUrl'] as String?;
                      final avatarUrl = m['avatarUrl'] as String?;
                      final ts = m['timestamp'] as int;
                      final sender = m['realName'] ?? m['sender'];

                      if (m['animatedEmoji'] != null &&
                          m['animatedEmoji'].toString().isNotEmpty) {
                        final emojiData =
                            _emojiNameMap[m['animatedEmoji'] as String] ??
                                AnimatedEmojis.smile;
                        return Padding(
                          padding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          child: Align(
                            alignment:
                            isOwn ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              decoration: BoxDecoration(
                                color: isOwn ? Colors.blue[100] : Colors.grey[300],
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.all(10),
                              child: Center(
                                child: AnimatedEmoji(emojiData, size: 150),
                              ),
                            ),
                          ),
                        );
                      }

                      if (isSingleEmoji(body)) {
                        final emojiData = unicodeToAnimatedEmoji[body.trim()]!;
                        return Padding(
                          padding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          child: Align(
                            alignment:
                            isOwn ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              decoration: BoxDecoration(
                                color: isOwn ? Colors.blue[100] : Colors.grey[300],
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.all(10),
                              child: Center(
                                child: AnimatedEmoji(emojiData, size: 150),
                              ),
                            ),
                          ),
                        );
                      }

                      String? parentText;
                      String? parentSender;
                      final replyToId = m['replyToEventId'] as String?;
                      if (replyToId != null) {
                        final pm = _rawMessages.firstWhereOrNull(
                              (x) => x['replyToEventId'] == replyToId,
                        );
                        if (pm != null) {
                          parentText = pm['body'] as String? ?? '';
                          parentSender = pm['realName'] ?? pm['sender'] ?? '';
                        }
                      }

                      if (imageUrl != null && _isImageExtension(imageUrl)) {
                        return Padding(
                          padding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          child: Align(
                            alignment:
                            isOwn ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              decoration: BoxDecoration(
                                color: isOwn ? Colors.blue[100] : Colors.grey[300],
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.all(10),
                              child: GestureDetector(
                                onTap: () => _openGallery([imageUrl], 0),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: _isGif(imageUrl)
                                      ? Image.network(
                                    imageUrl,
                                    width: 100,
                                    height: 100,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => const Icon(
                                      Icons.broken_image,
                                      size: 40,
                                    ),
                                  )
                                      : SafeRocketChatImage(
                                    url: imageUrl,
                                    width: 100,
                                    height: 100,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }

                      if (imageUrl != null && !_isImageExtension(imageUrl)) {
                        final filename = Uri.decodeComponent(
                          basename(Uri.parse(imageUrl).path),
                        );
                        final reaction = _localReactions[eventId];
                        return Column(
                          crossAxisAlignment:
                          isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              onLongPress: () =>
                                  _showMessageOptions(eventId, body, sender, isOwn, ts),
                              onTap: () async {
                                final file = await attachmentCache.getSingleFile(
                                  imageUrl,
                                  headers: {
                                    'X-Auth-Token': MatrixService.authToken,
                                    'X-User-Id': MatrixService.userId,
                                  },
                                );
                                await OpenFile.open(file.path);
                              },
                              child: ListTile(
                                leading: const Icon(Icons.insert_drive_file),
                                title: Text(filename),
                              ),
                            ),
                            if (reaction != null && reaction.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(left: 20, bottom: 8),
                                child: Text(
                                  reaction,
                                  style: const TextStyle(fontSize: 16),
                                ),
                              ),
                          ],
                        );
                      }

                      return Padding(
                        padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: GestureDetector(
                          onLongPress: () =>
                              _showMessageOptions(eventId, body, sender, isOwn, ts),
                          child: Align(
                            alignment:
                            isOwn ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              decoration: BoxDecoration(
                                color: isOwn ? Colors.blue[100] : Colors.grey[300],
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment:
                                isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (!isOwn)
                                        CircleAvatar(
                                          radius: 16,
                                          backgroundImage: avatarUrl != null
                                              ? CachedNetworkImageProvider(
                                            _getVersionedAvatarUrl(avatarUrl),
                                            headers: {
                                              'X-Auth-Token': MatrixService.authToken,
                                              'X-User-Id': MatrixService.userId,
                                            },
                                          )
                                              : null,
                                          child: avatarUrl == null
                                              ? const Icon(Icons.person, size: 16)
                                              : null,
                                        ),
                                      if (!isOwn) const SizedBox(width: 8),
                                      Text(
                                        sender,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  if (parentText != null && parentText.isNotEmpty) ...[
                                    Container(
                                      color: Colors.grey.shade200,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      margin: const EdgeInsets.only(bottom: 6),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Reply to $parentSender',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12,
                                            ),
                                          ),
                                          Text(
                                            parentText,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(color: Colors.black54),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                  if (body.isNotEmpty) Text(body),
                                  const SizedBox(height: 4),
                                  Text(
                                    _fmt(ts),
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: Colors.black54,
                                    ),
                                  ),
                                  if (_localReactions.containsKey(eventId)) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      _localReactions[eventId]!,
                                      style: const TextStyle(fontSize: 16),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
            ),
            if (_replyToEventId != null && _replyToText != null) ...[
              Container(
                color: Colors.grey.shade200,
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => setState(() {
                        _replyToEventId = null;
                        _replyToSender = null;
                        _replyToText = null;
                      }),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Reply to $_replyToSender',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            _replyToText!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.black54),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.add, size: 28),
                    onPressed: loading ? null : _showPlusMenu,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: InputDecoration(
                        hintText: _replyToEventId != null ? 'Reply to message…' : 'Enter message…',
                        border: const OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => loading ? null : _sendMessage(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: loading ? null : _sendMessage,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getVersionedAvatarUrl(String url) {
    return url;
  }

  Future<void> _clearAvatarCache(String url) async {
    await CachedNetworkImage.evictFromCache(url);
  }

  Future<void> _downloadFile(String url, String filename) async {
    if (!await requestStoragePermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Storage permission denied')));
      }
      return;
    }
    try {
      final file = await attachmentCache.getSingleFile(
        url,
        headers: {
          'X-Auth-Token': MatrixService.authToken,
          'X-User-Id': MatrixService.userId,
        },
      );
      if (_isImageExtension(filename)) {
        await PhotoManager.editor.saveImageWithPath(file.path, title: filename);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Saved image to Gallery')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e')),
        );
      }
    }
  }
}

class ImageGalleryPage extends StatefulWidget {
  final List<String> images;
  final int initialIndex;

  const ImageGalleryPage({
    super.key,
    required this.images,
    required this.initialIndex,
  });

  @override
  _ImageGalleryPageState createState() => _ImageGalleryPageState();
}

class _ImageGalleryPageState extends State<ImageGalleryPage> {
  late PageController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _isGif(String url) => url.toLowerCase().endsWith('.gif');

  Future<void> _download(String url, String filename) async {
    if (!await requestStoragePermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Storage permission denied')),
        );
      }
      return;
    }
    try {
      final file = await attachmentCache.getSingleFile(
        url,
        headers: {
          'X-Auth-Token': MatrixService.authToken,
          'X-User-Id': MatrixService.userId,
        },
      );
      await PhotoManager.editor.saveImageWithPath(file.path, title: filename);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved image to Gallery')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e')),
        );
      }
    }
  }

  Future<void> _downloadCurrent() async {
    final idx = (_controller.page ?? widget.initialIndex).round();
    final url = widget.images[idx];
    final filename = Uri.decodeComponent(basename(Uri.parse(url).path));
    await _download(url, filename);
  }

  Future<void> _downloadAll() async {
    for (var url in widget.images) {
      final filename = Uri.decodeComponent(basename(Uri.parse(url).path));
      await _download(url, filename);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Photos'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (val) {
              if (val == 'current') {
                _downloadCurrent();
              } else if (val == 'all') {
                _downloadAll();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'current', child: Text('Current Photo Only')),
              PopupMenuItem(value: 'all', child: Text('All Photos')),
            ],
          )
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.images.length,
        itemBuilder: (ctx, i) {
          final url = widget.images[i];
          return Center(
            child: InteractiveViewer(
              panEnabled: true,
              minScale: 1.0,
              maxScale: 5.0,
              child: _isGif(url)
                  ? Image.network(
                url,
                width: double.infinity,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) =>
                const Icon(Icons.broken_image, size: 60),
              )
                  : SafeRocketChatImage(
                url: url,
                width: double.infinity,
                height: double.infinity,
                fit: BoxFit.contain,
              ),
            ),
          );
        },
      ),
    );
  }
}
