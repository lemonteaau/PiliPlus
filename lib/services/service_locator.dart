import 'package:PiliPlus/services/audio_handler.dart';
import 'package:PiliPlus/services/audio_session.dart';

VideoPlayerServiceHandler? videoPlayerServiceHandler;
AudioSessionHandler? audioSessionHandler;

Future<void> setupServiceLocator() async {
  audioSessionHandler = AudioSessionHandler();
  final audio = await initAudioService();
  videoPlayerServiceHandler = audio;
}
