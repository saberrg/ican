import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ican/services/on_device_vision_service.dart';
import 'package:ican/services/scene_description_service.dart';
import 'package:ican/services/vertex_ai_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _runLiveGemini = bool.fromEnvironment('RUN_LIVE_GEMINI');
const _apiKey = String.fromEnvironment('API_KEY');

void main() {
  test(
    'cloud-only scene description reaches Gemini with restricted key',
    () async {
      expect(_apiKey, isNotEmpty, reason: 'API_KEY dart-define is required');
      SharedPreferences.setMockInitialValues({});

      final cloud = VertexAiService(
        apiKey: _apiKey,
        requestTimeout: const Duration(seconds: 45),
      );
      addTearDown(cloud.dispose);

      final service = SceneDescriptionService(
        cloudService: cloud,
        onDeviceService: OnDeviceVisionService(),
      );
      await service.setMode(VisionMode.cloudOnly);

      final chunks = await service
          .describeScene(
            _jpegBytes,
            systemPrompt:
                'Describe this image for a blind user in 3 complete spoken sentences with hazards, layout, text, and path details.',
            userPrompt: 'Describe this test image in 3 complete sentences.',
            maxOutputTokens: 220,
          )
          .toList();
      final text = chunks.join().trim();

      expect(service.lastBackend, VisionBackend.cloud);
      expect(text, isNotEmpty);
      expect(service.lastCompletionMetadata.finishReason, isNotEmpty);
      expect(service.lastCompletionMetadata.wasTruncated, isFalse);
    },
    skip: _runLiveGemini
        ? false
        : 'Set RUN_LIVE_GEMINI=true and API_KEY to run the live Gemini gate.',
  );
}

final _jpegBytes = Uint8List.fromList(
  base64Decode(
    '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoH'
    'BwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQME'
    'BAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU'
    'FBQUFBQUFBQUFBQUFBT/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQE'
    'AAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRB'
    'RIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3'
    'ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJW'
    'Wl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5u'
    'fo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL'
    '/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRob'
    'HBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYW'
    'VpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0'
    'tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADA'
    'MBAAIRAxEAPwD9U6KKKAP/2Q==',
  ),
);
