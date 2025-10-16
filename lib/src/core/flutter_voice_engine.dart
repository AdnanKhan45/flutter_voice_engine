import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'audio_config.dart';
import 'audio_session_config.dart';

class FlutterVoiceEngine {
  static const MethodChannel _channel =
  MethodChannel('flutter_voice_engine');
  static const EventChannel _eventChannel =
  EventChannel('flutter_voice_engine/events');

  AudioConfig audioConfig = AudioConfig();
  AudioSessionConfig sessionConfig = AudioSessionConfig();
  bool isInitialized = false;
  bool isRecording = false;

  final _audioChunkController = StreamController<Uint8List>.broadcast();
  final _musicPositionController =
  StreamController<Map<String, double>>.broadcast();
  final _musicStateController = StreamController<bool>.broadcast();
  final _errorController = StreamController<String>.broadcast();

  FlutterVoiceEngine() {
    _eventChannel.receiveBroadcastStream().listen(
          (dynamic event) {
        if (event is Map) {
          final type = event['type'] as String?;
          switch (type) {
            case 'audio_chunk':
              final data = event['data'];
              if (data is Uint8List) {
                _audioChunkController.add(data);
              } else {
                _errorController
                    .add('Invalid audio chunk data type: ${data.runtimeType}');
              }
              break;
            case 'music_position':
              final pos = event['position'] as double?;
              final dur = event['duration'] as double?;
              if (pos != null && dur != null) {
                _musicPositionController.add({
                  'position': pos,
                  'duration': dur,
                });
              } else {
                _errorController.add('Invalid music position data: $event');
              }
              break;
            case 'music_state':
              final playing = event['state'] as bool?;
              if (playing != null) {
                _musicStateController.add(playing);
              } else {
                _errorController
                    .add('Invalid music state data: ${event['state']}');
              }
              break;
            case 'error':
              final msg = event['message'] as String?;
              if (msg != null) _errorController.add(msg);
              break;
            default:
              _errorController.add('Unknown event type: $type');
          }
        } else {
          _errorController
              .add('Invalid event data type: ${event.runtimeType}');
        }
      },
      onError: (e) => _errorController.add('Event stream error: $e'),
      onDone: () => _errorController.add('Event stream closed'),
    );
  }

  /// Streams
  Stream<Uint8List> get audioChunkStream => _audioChunkController.stream;

  Stream<Map<String, double>> get musicPositionStream =>
      _musicPositionController.stream;

  Stream<bool> get musicStateStream => _musicStateController.stream;

  Stream<String> get errorStream => _errorController.stream;

  /// Converters for nicer Dart-level streams:
  Stream<Duration> get backgroundMusicPositionStream =>
      musicPositionStream.map((m) => Duration(
          milliseconds: (m['position']! * 1000).round()));

  Stream<Duration> get backgroundMusicDurationStream => musicPositionStream.map((event) {
    final d = event['duration'] as double;
    final ms = d.isFinite ? (d * 1000).round() : 0;
    return Duration(milliseconds: ms);
  });


  Stream<bool> get backgroundMusicIsPlayingStream =>
      musicStateStream;

  /// Initialization
  Future<void> initialize() async {
    await _channel.invokeMethod('initialize', {
      'audioConfig': audioConfig.toMap(),
      'sessionConfig': sessionConfig.toMap(),
      'processors': [],
    });
    isInitialized = true;
  }

  /// Recording
  Future<void> startRecording() async {
    if (!isInitialized) throw Exception('VoiceEngine not initialized');
    await _channel.invokeMethod('startRecording');
    isRecording = true;
  }

  Future<void> stopRecording() async {
    if (!isInitialized || !isRecording) return;
    await _channel.invokeMethod('stopRecording');
    isRecording = false;
  }

  Future<void> playAudioChunk(Uint8List data) async {
    if (!isInitialized) throw Exception('VoiceEngine not initialized');
    await _channel.invokeMethod('playAudioChunk', {'audioData': data});
  }

  Future<void> stopPlayback() async {
    if (!isInitialized) return;
    await _channel.invokeMethod('stopPlayback');
  }

  /// Background Music
  Future<void> playBackgroundMusic(String source,
      {bool loop = true}) async {
    if (!isInitialized) throw Exception('VoiceEngine not initialized');
    await _channel.invokeMethod('playBackgroundMusic', {
      'source': source,
      'loop': loop,
    });
  }

  Future<void> stopBackgroundMusic() async {
    if (!isInitialized) throw Exception('VoiceEngine not initialized');
    await _channel.invokeMethod('stopBackgroundMusic');
  }

  Future<void> seekBackgroundMusic(Duration position) async {
    if (!isInitialized) throw Exception('VoiceEngine not initialized');
    await _channel.invokeMethod('seekBackgroundMusic', {
      'position': position.inMilliseconds / 1000.0,
    });
  }

  Future<void> setBackgroundMusicVolume(double volume) async {
    if (!isInitialized) throw Exception('VoiceEngine not initialized');
    await _channel.invokeMethod('setBackgroundMusicVolume', {
      'volume': volume,
    });
  }

  Future<double> getBackgroundMusicVolume() async {
    if (!isInitialized) return 1.0;
    final vol = await _channel.invokeMethod('getBackgroundMusicVolume');
    return (vol as num).toDouble();
  }


  /// Playlist support
  Future<void> setMusicPlaylist(List<String> urls) async {
    if (!isInitialized) throw Exception('VoiceEngine not initialized');
    await _channel.invokeMethod('setMusicPlaylist', {'urls': urls});
  }

  Future<void> playTrackAtIndex(int index) async {
    if (!isInitialized) throw Exception('VoiceEngine not initialized');
    await _channel.invokeMethod('playTrackAtIndex', {'index': index});
  }

  /// Shutdown
  Future<void> shutdownBot() async {
    if (!isInitialized) return;
    await _channel.invokeMethod('shutdownBot');
  }

  Future<void> shutdownAll() async {
    if (!isInitialized) return;
    await _channel.invokeMethod('shutdownAll');
    isInitialized = false;
    isRecording = false;
    await _audioChunkController.close();
    await _musicPositionController.close();
    await _musicStateController.close();
    await _errorController.close();
  }

  Future<void> stop() async {
    if (!isInitialized) return;
    await _channel.invokeMethod('stop');
    isInitialized = false;
    isRecording = false;
  }
}
