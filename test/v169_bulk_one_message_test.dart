// v169: "Ek message-e shob prompt" — the bulk box is sent to Gemini as
// ONE Task message that asks for one video per prompt; the driver
// answers with one video_ready per video (with an index) and a final
// video_batch_done. Each video becomes its own card, matched to its
// own prompt. (Not run here — no Flutter toolchain in the authoring
// environment.)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mp4_test_helpers.dart';

import 'package:gemini_hd_studio/animation_engine.dart';
import 'package:gemini_hd_studio/animation_models.dart';
import 'package:gemini_hd_studio/gecko_browser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v169 video event parsing', () {
    test('video_ready carries the batch index', () {
      final ev = AnimationVideoEvent.fromData('video_ready', {
        'jobId': 'j1',
        'index': 2,
        'url': 'https://x/y.mp4',
      });
      expect(ev, isNotNull);
      expect(ev!.index, 2);
      expect(ev.isVideo, isTrue);
    });

    test('a single-video event has index -1', () {
      final ev = AnimationVideoEvent.fromData('video_ready', {'jobId': 'j1'});
      expect(ev!.index, -1);
    });

    test('video_batch_done is a video event', () {
      final ev =
          AnimationVideoEvent.fromData('video_batch_done', {'jobId': 'j1'});
      expect(ev!.isVideo, isTrue);
    });
  });

  group('v169 one-message bulk in the engine', () {
    late Directory tmp;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tmp = Directory.systemTemp.createTempSync('anim-batch-test-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async {
          if (call.method == 'getApplicationDocumentsDirectory' ||
              call.method == 'getTemporaryDirectory') {
            return tmp.path;
          }
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    GeckoBrowserRequest ready(String jobId, int index) {
      final mp4 = minimalMp4(fps: 30, durationSec: 6);
      return GeckoBrowserRequest('video_ready', const [], '', '', data: {
        'jobId': jobId,
        'index': index,
        'dataUrl': 'data:video/mp4;base64,${base64Encode(mp4)}',
        'width': 1620,
        'height': 2880,
        'durationSec': 6,
      });
    }

    GeckoBrowserRequest batchDone(String jobId, int count) =>
        GeckoBrowserRequest('video_batch_done', const [], '', '',
            data: {'jobId': jobId, 'count': count});

    AnimationEngine engineDelivering(
      List<Map<String, Object>> sent, {
      required int deliver,
    }) {
      late AnimationEngine engine;
      engine = AnimationEngine(
        jobTimeout: const Duration(seconds: 10),
        videoDriverRunner: ({required prompt, required modelId, required jobId}) async =>
            true,
        videoBatchDriverRunner: ({
          required prompt,
          required modelId,
          required jobId,
          required count,
        }) async {
          sent.add({'prompt': prompt, 'count': count, 'jobId': jobId});
          unawaited(Future(() async {
            for (var i = 0; i < deliver; i++) {
              await engine.handleRequest(ready(jobId, i));
            }
            await engine.handleRequest(batchDone(jobId, deliver));
          }));
          return true;
        },
      );
      addTearDown(engine.dispose);
      return engine;
    }

    test('3 lines -> ONE message, 3 videos, each with its own prompt',
        () async {
      final sent = <Map<String, Object>>[];
      final engine = engineDelivering(sent, deliver: 3);
      await engine.load();
      expect(engine.supportsBatch, isTrue);
      await engine.startBulkBatch(
        prompts: ['neon blue phone', 'molten gold tree', 'crimson pine'],
        modelId: 'neon',
        signedIn: true,
      );
      expect(sent, hasLength(1));
      expect(sent.single['count'], 3);
      final msg = sent.single['prompt'] as String;
      expect(msg, contains('Video 1:'));
      expect(msg, contains('Video 2:'));
      expect(msg, contains('Video 3:'));
      expect(msg, contains('neon blue phone'));
      expect(msg, contains('molten gold tree'));
      expect(msg, contains('crimson pine'));
      expect(engine.videos, hasLength(3));
      // videos are stored newest first.
      expect(engine.videos.map((v) => v.prompt).toList().reversed.toList(),
          ['neon blue phone', 'molten gold tree', 'crimson pine']);
      expect(engine.bulkItems.map((i) => i.status),
          everyElement(BulkAnimationStatus.done));
      expect(engine.busy, isFalse);
    });

    test('Gemini sends only 2 of 3: the missing line is failed', () async {
      final sent = <Map<String, Object>>[];
      final engine = engineDelivering(sent, deliver: 2);
      await engine.load();
      await engine.startBulkBatch(
        prompts: ['a quiet snowy meadow', 'a giant glass snowflake', 'a fire'],
        modelId: 'neon',
        signedIn: true,
      );
      expect(engine.videos, hasLength(2));
      expect(engine.bulkItems.map((i) => i.status).toList(), [
        BulkAnimationStatus.done,
        BulkAnimationStatus.done,
        BulkAnimationStatus.failed,
      ]);
      expect(engine.busy, isFalse);
    });

    test('without a batch runner the mode is not offered', () async {
      final engine = AnimationEngine(
        jobTimeout: const Duration(seconds: 5),
        videoDriverRunner: ({required prompt, required modelId, required jobId}) async =>
            true,
      );
      addTearDown(engine.dispose);
      await engine.load();
      expect(engine.supportsBatch, isFalse);
    });
  });
}
