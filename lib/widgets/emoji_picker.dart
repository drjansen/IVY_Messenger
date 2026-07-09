import 'package:flutter/material.dart';
import 'package:animated_emoji/animated_emoji.dart';

/// A full‐screen grid of curated animated emojis.
/// Returns the selected emoji’s name string via Navigator.pop.
class AnimatedEmojiPicker extends StatelessWidget {
  const AnimatedEmojiPicker({Key? key}) : super(key: key);

  /// Curated list of available animated emojis that are guaranteed present in your version.
  static const List<MapEntry<String, AnimatedEmojiData>> _curatedEmojis = [
    MapEntry('thumbsUp', AnimatedEmojis.thumbsUp),
    MapEntry('laughing', AnimatedEmojis.laughing),
    MapEntry('fire', AnimatedEmojis.fire),
    MapEntry('partyPopper', AnimatedEmojis.partyPopper),
    MapEntry('smile', AnimatedEmojis.smile),
    MapEntry('sad', AnimatedEmojis.sad),
    MapEntry('starStruck', AnimatedEmojis.starStruck),
    MapEntry('clap', AnimatedEmojis.clap),
    MapEntry('wink', AnimatedEmojis.wink),
    MapEntry('eyes', AnimatedEmojis.eyes),
    MapEntry('rocket', AnimatedEmojis.rocket),
    MapEntry('cool', AnimatedEmojis.cool),
    MapEntry('angry', AnimatedEmojis.angry),
    MapEntry('surprised', AnimatedEmojis.surprised),
    MapEntry('rollingEyes', AnimatedEmojis.rollingEyes),
    MapEntry('sleepy', AnimatedEmojis.sleepy),
    MapEntry('sweat', AnimatedEmojis.sweat),
    // Add more if you verify their existence in your AnimatedEmojis version!
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 6,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
        itemCount: _curatedEmojis.length,
        itemBuilder: (context, idx) {
          final entry = _curatedEmojis[idx];
          final emojiName = entry.key;
          final emojiData = entry.value;
          return GestureDetector(
            onTap: () => Navigator.pop(context, emojiName),
            child: AnimatedEmoji(emojiData, size: 100, repeat: false),
          );
        },
      ),
    );
  }
}