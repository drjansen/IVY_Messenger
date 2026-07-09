import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

class AvatarNotifier extends ValueNotifier<String?> {
  AvatarNotifier(String? value) : super(value);

  @override
  set value(String? newValue) {
    if (newValue != this.value) {
      // Optionally clear cache on change
      if (this.value != null) {
        CachedNetworkImage.evictFromCache(this.value!);
      }
    }
    super.value = newValue;
  }
}

final avatarNotifier = AvatarNotifier(null);