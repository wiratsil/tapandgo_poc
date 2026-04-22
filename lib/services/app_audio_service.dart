import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

enum AppSound {
  welcome('Welcome_v2.m4a', Duration(milliseconds: 1264)),
  tapCard('TapCard_v2.m4a', Duration(milliseconds: 407)),
  scanQr('ScanQR_v2.m4a', Duration(milliseconds: 1081)),
  payment('Payment_v2.m4a', Duration(milliseconds: 807)),
  successful('Successful_v2.m4a', Duration(milliseconds: 430)),
  unsuccessful('Unsuccessful_v2.m4a', Duration(milliseconds: 530)),
  tryAgain('TryAgain_v2.m4a', Duration(milliseconds: 1706));

  const AppSound(this.fileName, this.duration);

  final String fileName;
  final Duration duration;
}

class AppAudioService {
  AppAudioService._();

  static final AppAudioService instance = AppAudioService._();

  Future<void> _queue = Future<void>.value();
  bool _isInitialized = false;
  bool _isDisposed = false;
  final List<AudioPlayer> _activePlayers = [];
  static const Duration _sequenceOverlap = Duration(milliseconds: 30);

  bool get isReady => _isInitialized && !_isDisposed;

  Future<void> init() async {
    if (_isInitialized || _isDisposed) return;
    _isInitialized = true;
  }

  Future<void> play(AppSound sound) => playSequence([sound]);

  Future<void> playSequence(List<AppSound> sounds) {
    if (sounds.isEmpty || _isDisposed) return Future<void>.value();

    _queue =
        _queue.then((_) => _playSequenceInternal(sounds)).catchError((e, _) {
      debugPrint('[AUDIO] Queue error: $e');
    });
    return _queue;
  }

  Future<void> _playSequenceInternal(List<AppSound> sounds) async {
    await init();

    for (final sound in sounds) {
      if (_isDisposed) return;
      await _playSingle(sound);
    }
  }

  Future<void> _playSingle(AppSound sound) async {
    final player = AudioPlayer();
    _activePlayers.add(player);

    try {
      await player.setPlayerMode(PlayerMode.lowLatency);
      await player.setReleaseMode(ReleaseMode.stop);

      await player.play(AssetSource('audio/${sound.fileName}'));
      final waitDuration = sound.duration > _sequenceOverlap
          ? sound.duration - _sequenceOverlap
          : sound.duration;
      await Future<void>.delayed(waitDuration);
    } catch (e) {
      debugPrint('[AUDIO] Failed to play ${sound.fileName}: $e');
      await Future<void>.delayed(const Duration(milliseconds: 800));
    } finally {
      try {
        await player.stop();
      } catch (_) {}
      _activePlayers.remove(player);
      await player.dispose();
    }
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    for (final player in List<AudioPlayer>.from(_activePlayers)) {
      await player.dispose();
    }
    _activePlayers.clear();
  }
}
