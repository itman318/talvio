import 'package:flutter_test/flutter_test.dart';
import '../lib/models/models.dart';
import '../lib/widgets/message_bubble.dart';

MediaInfo audio(String name, {String mime = 'audio/mpeg'}) => MediaInfo(id: 1, kind: 'file', mime: mime, size: 100, name: name, url: '/api/media/1');

void main() {
  test('audio replies identify the attachment by media metadata', () {
    expect(replyLabel('file', '', media: audio('Track.mp3')), '🎵 Track');
    expect(replyLabel('file', '', media: audio('Track.ogg', mime: 'application/octet-stream')), '🎵 Track');
    expect(replyLabel('file', '', media: audio('7ea5741106f70f74fad123456.mp3')), '🎵 Audio');
    expect(replyLabel('file', '', media: audio('notes.pdf', mime: 'application/pdf')), '📄 File');
    expect(replyLabel('file', '', deleted: true, media: audio('Track.mp3')), 'Deleted message');
  });
}
