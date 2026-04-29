import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ican/services/vertex_ai_service.dart';

void main() {
  group('VertexAiService failures', () {
    test(
      'missing API key gives API-key error without sending request',
      () async {
        var sentRequest = false;
        final service = VertexAiService(
          apiKey: '',
          httpClient: MockClient((_) async {
            sentRequest = true;
            return http.Response(_successBody, 200);
          }),
        );

        await expectLater(
          service.generateContentFromImage(
            _jpegBytes,
            systemPrompt: 'Describe safely.',
          ),
          throwsA(
            isA<CloudVisionException>().having(
              (e) => e.kind,
              'kind',
              CloudVisionFailureKind.missingApiKey,
            ),
          ),
        );
        expect(sentRequest, isFalse);
      },
    );

    for (final status in [401, 403, 429, 500]) {
      test('HTTP $status gives API HTTP error', () async {
        final service = VertexAiService(
          apiKey: 'test-key',
          httpClient: MockClient((_) async {
            return http.Response(
              jsonEncode({
                'error': {'message': 'HTTP $status from Gemini'},
              }),
              status,
            );
          }),
        );

        await expectLater(
          service.generateContentFromImage(
            _jpegBytes,
            systemPrompt: 'Describe safely.',
          ),
          throwsA(
            isA<CloudVisionException>()
                .having(
                  (e) => e.kind,
                  'kind',
                  CloudVisionFailureKind.httpStatus,
                )
                .having((e) => e.statusCode, 'statusCode', status),
          ),
        );
      });
    }

    test('cloud timeout gives timeout error', () async {
      final completer = Completer<http.Response>();
      final service = VertexAiService(
        apiKey: 'test-key',
        requestTimeout: const Duration(milliseconds: 1),
        httpClient: MockClient((_) => completer.future),
      );

      await expectLater(
        service.generateContentFromImage(
          _jpegBytes,
          systemPrompt: 'Describe safely.',
        ),
        throwsA(
          isA<CloudVisionException>().having(
            (e) => e.kind,
            'kind',
            CloudVisionFailureKind.timeout,
          ),
        ),
      );
    });

    test('malformed cloud response gives malformed-response error', () async {
      final service = VertexAiService(
        apiKey: 'test-key',
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );

      await expectLater(
        service.generateContentFromImage(
          _jpegBytes,
          systemPrompt: 'Describe safely.',
        ),
        throwsA(
          isA<CloudVisionException>().having(
            (e) => e.kind,
            'kind',
            CloudVisionFailureKind.malformedResponse,
          ),
        ),
      );
    });

    test(
      'requests include iOS bundle identifier for restricted API keys',
      () async {
        late http.Request capturedRequest;
        final service = VertexAiService(
          apiKey: 'test-key',
          httpClient: MockClient((request) async {
            capturedRequest = request;
            return http.Response(_successBody, 200);
          }),
        );

        await service.generateContentFromImage(
          _jpegBytes,
          systemPrompt: 'Describe safely.',
        );

        expect(
          capturedRequest.headers['X-Ios-Bundle-Identifier'],
          'com.icannavigation.app',
        );
      },
    );

    test('requests send API key by header and not URL query', () async {
      late http.Request capturedRequest;
      final service = VertexAiService(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          capturedRequest = request;
          return http.Response(_successBody, 200);
        }),
      );

      await service.generateContentFromImage(
        _jpegBytes,
        systemPrompt: 'Describe safely.',
      );

      expect(capturedRequest.headers['x-goog-api-key'], 'test-key');
      expect(capturedRequest.url.queryParameters, isNot(contains('key')));
    });

    test(
      'cloud image requests default to the Flash model for the demo path',
      () async {
        late http.Request capturedRequest;
        final service = VertexAiService(
          apiKey: 'test-key',
          httpClient: MockClient((request) async {
            capturedRequest = request;
            return http.Response(_successBody, 200);
          }),
        );

        await service.generateContentFromImage(
          _jpegBytes,
          systemPrompt: 'Describe safely.',
        );

        // Flash is the demo default. Pro is still selectable via setModel()
        // for diagnostics, but any path that forgets to pick a model must
        // land on Flash so latency stays low.
        expect(capturedRequest.url.path, contains('gemini-2.5-flash'));
        expect(capturedRequest.url.path, isNot(contains('gemini-2.5-pro')));
      },
    );

    test('streaming preserves chunk spacing and finish reason', () async {
      late http.Request capturedRequest;
      final service = VertexAiService(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          capturedRequest = request;
          return http.Response(
            [
              'data: {"candidates":[{"content":{"parts":[{"text":"A clear "}]}}]}',
              '',
              'data: {"candidates":[{"content":{"parts":[{"text":"path ahead."}]},"finishReason":"MAX_TOKENS"}]}',
              '',
            ].join('\n'),
            200,
          );
        }),
      );

      final chunks = await service
          .streamContentFromImage(_jpegBytes, systemPrompt: 'Describe safely.')
          .toList();

      expect(chunks.join(), 'A clear path ahead.');
      expect(service.lastFinishReason, 'MAX_TOKENS');
      expect(capturedRequest.headers['x-goog-api-key'], 'test-key');
      expect(capturedRequest.url.queryParameters, isNot(contains('key')));
    });

    test('streaming accepts SSE data lines without a space', () async {
      final service = VertexAiService(
        apiKey: 'test-key',
        httpClient: MockClient((_) async {
          return http.Response(
            [
              'data:{"candidates":[{"content":{"parts":[{"text":"Door "}]}}]}',
              'data:{"candidates":[{"content":{"parts":[{"text":"ahead."}]}}]}',
            ].join('\n'),
            200,
          );
        }),
      );

      final chunks = await service
          .streamContentFromImage(_jpegBytes, systemPrompt: 'Describe safely.')
          .toList();

      expect(chunks.join(), 'Door ahead.');
    });

    test('image requests use prompt-specific max output tokens', () async {
      late Map<String, dynamic> body;
      final service = VertexAiService(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(_successBody, 200);
        }),
      );

      await service.generateContentFromImage(
        _jpegBytes,
        systemPrompt: 'Describe safely.',
        maxOutputTokens: 760,
      );

      final generationConfig = body['generationConfig'] as Map<String, dynamic>;
      expect(generationConfig['maxOutputTokens'], 760);
    });
  });
}

final _jpegBytes = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);

const _successBody = '''
{
  "candidates": [
    {
      "content": {
        "parts": [
          {"text": "A clear scene description."}
        ]
      }
    }
  ]
}
''';
