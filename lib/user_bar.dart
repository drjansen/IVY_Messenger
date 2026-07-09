import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:permission_handler/permission_handler.dart';

class UserBar extends StatelessWidget {
  final String? avatarUrl;
  final String? userName;
  final VoidCallback? onSettings;
  final VoidCallback? onLogout;
  final Future<void> Function(File newAvatarFile)? onChangeAvatar;

  const UserBar({
    Key? key,
    this.avatarUrl,
    this.userName,
    this.onSettings,
    this.onLogout,
    this.onChangeAvatar,
  }) : super(key: key);

  Future<void> _handleAvatarTap(BuildContext context) async {
    debugPrint('UserBar: avatar tapped');

    // Optional but helps on Android 13+
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final status = await Permission.photos.request();
      if (!status.isGranted) {
        debugPrint('UserBar: photos permission denied');
        return;
      }
    }

    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    debugPrint('UserBar: picked = ${picked?.path}');
    if (picked == null) return;

    final cropped = await ImageCropper().cropImage(
      sourcePath: picked.path,
      compressFormat: ImageCompressFormat.jpg,
      compressQuality: 85,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: tr('crop_avatar'),
          cropStyle: CropStyle.circle,
        ),
        IOSUiSettings(
          title: tr('crop_avatar'),
          cropStyle: CropStyle.circle,
        ),
      ],
    );

    debugPrint('UserBar: cropped = ${cropped?.path}');
    if (cropped == null) return;

    if (onChangeAvatar != null) {
      await onChangeAvatar!(File(cropped.path));
    } else {
      debugPrint('UserBar: onChangeAvatar is null');
    }
  }

  void _showSettingsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.logout),
              title: Text('logout'.tr()),
              onTap: () {
                Navigator.pop(ctx);
                onLogout?.call();
              },
            ),
            if (onSettings != null) ...[
              ListTile(
                leading: const Icon(Icons.settings),
                title: Text('settings'.tr()),
                onTap: () {
                  Navigator.pop(ctx);
                  onSettings!.call();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Subtle "green chrome" = metallic multi-stop gradient + a soft top sheen.
    // No rounded corners; shadow biased downward for a 3D bottom edge.
    final decoration = BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFF0B4F24), // dark edge
          Color(0xFF1E8A46), // mid green
          Color(0xFF74E6A0), // highlight band (subtle)
          Color(0xFF1E8A46), // mid green again
          Color(0xFF0A3F1C), // dark edge
        ],
        stops: [0.0, 0.28, 0.52, 0.78, 1.0],
      ),
      boxShadow: const [
        BoxShadow(
          color: Colors.black26,
          blurRadius: 10,
          spreadRadius: 0,
          offset: Offset(0, 6), // downward -> bottom shadow emphasis
        ),
      ],
    );

    return DecoratedBox(
      decoration: decoration,
      child: Stack(
        children: [
          // Content
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _handleAvatarTap(context),
                  child: avatarUrl != null
                      ? CachedNetworkImage(
                    imageUrl: avatarUrl!,
                    imageBuilder: (ctx, img) =>
                        CircleAvatar(radius: 24, backgroundImage: img),
                    placeholder: (ctx, _) => const CircleAvatar(
                      radius: 24,
                      child: CircularProgressIndicator(),
                    ),
                    errorWidget: (ctx, _, __) => const CircleAvatar(
                      radius: 24,
                      child: Icon(Icons.person),
                    ),
                  )
                      : const CircleAvatar(
                    radius: 24,
                    child: Icon(Icons.person, size: 28),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    userName ?? '',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.settings, color: Colors.white),
                  onPressed: () => _showSettingsSheet(context),
                ),
              ],
            ),
          ),

          // Subtle top sheen (specular highlight)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withOpacity(0.22),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.55],
                  ),
                ),
              ),
            ),
          ),

          // Very subtle bottom edge line to make the "lip" feel crisp
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Container(
                height: 1,
                color: Colors.white.withOpacity(0.20),
              ),
            ),
          ),
        ],
      ),
    );
  }
}