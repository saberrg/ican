import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Available AI models for image understanding, ordered by speed.
enum AiModel {
  flashLite(
    id: 'gemini-2.5-flash-lite',
    label: 'Flash Lite',
    description: 'Fastest, basic quality',
  ),
  flash(
    id: 'gemini-2.5-flash',
    label: 'Flash',
    description: 'Fast, good quality (recommended)',
  ),
  pro(
    id: 'gemini-2.5-pro',
    label: 'Pro',
    description: 'Best quality, slower (~3s)',
  );

  const AiModel({
    required this.id,
    required this.label,
    required this.description,
  });

  final String id;
  final String label;
  final String description;
}

enum CloudVisionFailureKind {
  missingApiKey,
  httpStatus,
  timeout,
  malformedResponse,
  network,
}

class CloudVisionException implements Exception {
  const CloudVisionException._(
    this.kind,
    this.message, {
    this.statusCode,
    this.detail,
  });

  factory CloudVisionException.missingApiKey() {
    return const CloudVisionException._(
      CloudVisionFailureKind.missingApiKey,
      'Cloud vision API key is missing',
    );
  }

  factory CloudVisionException.httpStatus(int statusCode, {String? detail}) {
    return CloudVisionException._(
      CloudVisionFailureKind.httpStatus,
      'Cloud vision API returned $statusCode',
      statusCode: statusCode,
      detail: detail,
    );
  }

  factory CloudVisionException.timeout() {
    return const CloudVisionException._(
      CloudVisionFailureKind.timeout,
      'Cloud vision request timed out',
    );
  }

  factory CloudVisionException.malformedResponse(String detail) {
    return CloudVisionException._(
      CloudVisionFailureKind.malformedResponse,
      'Cloud vision returned a malformed response',
      detail: detail,
    );
  }

  factory CloudVisionException.network(Object error) {
    return CloudVisionException._(
      CloudVisionFailureKind.network,
      'Cloud vision network request failed',
      detail: error.toString(),
    );
  }

  final CloudVisionFailureKind kind;
  final String message;
  final int? statusCode;
  final String? detail;

  String get userMessage {
    switch (kind) {
      case CloudVisionFailureKind.missingApiKey:
        return 'Cloud vision API key is missing';
      case CloudVisionFailureKind.httpStatus:
        return 'Cloud vision API returned $statusCode';
      case CloudVisionFailureKind.timeout:
        return 'Cloud vision request timed out';
      case CloudVisionFailureKind.malformedResponse:
        return 'Cloud vision returned an unreadable response';
      case CloudVisionFailureKind.network:
        return 'Cloud vision network request failed';
    }
  }

  @override
  String toString() {
    final suffix = detail == null ? '' : ': $detail';
    return '$message$suffix';
  }
}

class VertexAiService extends ChangeNotifier {
  VertexAiService({
    http.Client? httpClient,
    String? apiKey,
    Duration requestTimeout = const Duration(seconds: 20),
  }) : _client = httpClient ?? http.Client(),
       _apiKey = apiKey ?? const String.fromEnvironment('API_KEY'),
       _requestTimeout = requestTimeout,
       _ownsClient = httpClient == null;

  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  static const String _prefsKey = 'ai_model';
  static const String _iosBundleIdentifier = String.fromEnvironment(
    'IOS_BUNDLE_IDENTIFIER',
    defaultValue: 'com.icannavigation.app',
  );

  final http.Client _client;
  final String _apiKey;
  final Duration _requestTimeout;
  final bool _ownsClient;

  AiModel _model = AiModel.flash;
  AiModel get model => _model;

  bool get isConfigured => _apiKey.isNotEmpty && _apiKey != 'dummy';

  String? _lastFinishReason;
  String? get lastFinishReason => _lastFinishReason;

  /// Load saved model preference. Call once at app startup.
  Future<void> loadSavedModel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKey);
      if (saved != null) {
        _model = AiModel.values.firstWhere(
          (m) => m.id == saved,
          orElse: () => AiModel.flash,
        );
      }
    } catch (_) {}
  }

  /// Switch the active model and persist the choice.
  Future<void> setModel(AiModel newModel) async {
    if (_model == newModel) return;
    _model = newModel;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, newModel.id);
    } catch (_) {}
    debugPrint('[VisionAI] Model changed to: ${newModel.id}');
  }

  Future<String> generateContent(String prompt) async {
    return _sendRequest([
      {'text': prompt},
    ]);
  }

  Future<String> generateContentFromImage(
    Uint8List imageBytes, {
    required String systemPrompt,
    String userPrompt = 'Describe what you see.',
    int maxOutputTokens = 500,
  }) async {
    final base64Image = base64Encode(imageBytes);

    return _sendRequest(
      [
        {
          'inlineData': {'mimeType': 'image/jpeg', 'data': base64Image},
        },
        {'text': userPrompt},
      ],
      systemPrompt: systemPrompt,
      maxOutputTokens: maxOutputTokens,
    );
  }

  Future<String> _sendRequest(
    List<Map<String, dynamic>> parts, {
    String? systemPrompt,
    int maxOutputTokens = 500,
  }) async {
    _assertApiKeyPresent();
    _lastFinishReason = null;

    final url = Uri.parse('$_baseUrl/${_model.id}:generateContent');

    final body = <String, dynamic>{
      'contents': [
        {'role': 'user', 'parts': parts},
      ],
      'generationConfig': {
        'temperature': 0.2,
        'maxOutputTokens': maxOutputTokens,
        'topP': 0.8,
      },
    };

    if (systemPrompt != null) {
      body['system_instruction'] = {
        'parts': [
          {'text': systemPrompt},
        ],
      };
    }

    try {
      final response = await _client
          .post(url, headers: _requestHeaders, body: jsonEncode(body))
          .timeout(_requestTimeout);

      debugPrint('[VisionAI] ${_model.id} response: ${response.statusCode}');

      if (response.statusCode != 200) {
        _logErrorBody('Error', response.body);
        throw CloudVisionException.httpStatus(
          response.statusCode,
          detail: _safeErrorDetail(response.body),
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw CloudVisionException.malformedResponse(
          'Top-level response was ${decoded.runtimeType}',
        );
      }
      return _extractText(decoded).trim();
    } on CloudVisionException {
      rethrow;
    } on TimeoutException {
      debugPrint('[VisionAI] ${_model.id} request timed out');
      throw CloudVisionException.timeout();
    } on FormatException catch (e) {
      debugPrint('[VisionAI] Malformed JSON response: ${e.message}');
      throw CloudVisionException.malformedResponse(e.message);
    } catch (e) {
      debugPrint('[VisionAI] Network request failed: $e');
      throw CloudVisionException.network(e);
    }
  }

  /// Stream content from image using SSE for lower first-token latency.
  /// Yields incremental text chunks as they arrive from the API.
  Stream<String> streamContentFromImage(
    Uint8List imageBytes, {
    required String systemPrompt,
    String userPrompt = 'Describe what you see.',
    int maxOutputTokens = 500,
  }) async* {
    _assertApiKeyPresent();
    _lastFinishReason = null;

    final request = http.Request('POST', _streamUrl());
    request.headers.addAll(_requestHeaders);
    request.body = jsonEncode(
      _imageRequestBody(
        imageBytes,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        maxOutputTokens: maxOutputTokens,
      ),
    );

    try {
      final streamed = await _client.send(request).timeout(_requestTimeout);

      if (streamed.statusCode != 200) {
        final errorBody = await streamed.stream.bytesToString();
        _logErrorBody('Stream error', errorBody);
        throw CloudVisionException.httpStatus(
          streamed.statusCode,
          detail: _safeErrorDetail(errorBody),
        );
      }

      debugPrint('[VisionAI] ${_model.id} streaming started');

      // Parse SSE events: "data: {json}\n\n"
      String lineBuf = '';
      var yieldedText = false;
      var sawMalformedEvent = false;
      await for (final chunk in streamed.stream.transform(
        const Utf8Decoder(),
      )) {
        lineBuf += chunk;
        while (lineBuf.contains('\n')) {
          final lineEnd = lineBuf.indexOf('\n');
          final line = lineBuf.substring(0, lineEnd).trim();
          lineBuf = lineBuf.substring(lineEnd + 1);

          final data = _sseDataPayload(line);
          if (data != null) {
            try {
              final json = jsonDecode(data) as Map<String, dynamic>;
              final text = _extractText(json, allowEmptyText: true);
              if (text.isNotEmpty) {
                yieldedText = true;
                yield text;
              }
            } catch (e) {
              sawMalformedEvent = true;
              debugPrint('[VisionAI] SSE parse error: $e');
            }
          }
        }
      }

      // Flush remaining data; the last SSE line may not end with \n.
      final remaining = lineBuf.trim();
      final remainingData = _sseDataPayload(remaining);
      if (remainingData != null) {
        try {
          final json = jsonDecode(remainingData) as Map<String, dynamic>;
          final text = _extractText(json, allowEmptyText: true);
          if (text.isNotEmpty) {
            yieldedText = true;
            yield text;
          }
        } catch (e) {
          sawMalformedEvent = true;
          debugPrint('[VisionAI] SSE flush parse error: $e');
        }
      }

      if (!yieldedText) {
        throw CloudVisionException.malformedResponse(
          sawMalformedEvent
              ? 'Streaming response had malformed events'
              : 'Streaming response contained no text',
        );
      }

      debugPrint('[VisionAI] stream complete');
    } on CloudVisionException {
      rethrow;
    } on TimeoutException {
      debugPrint('[VisionAI] ${_model.id} stream timed out');
      throw CloudVisionException.timeout();
    } catch (e) {
      debugPrint('[VisionAI] Stream request failed: $e');
      throw CloudVisionException.network(e);
    }
  }

  void _assertApiKeyPresent() {
    if (_apiKey.isEmpty || _apiKey == 'dummy') {
      debugPrint('[VisionAI] Missing API key; cloud request not sent');
      throw CloudVisionException.missingApiKey();
    }
  }

  Uri _streamUrl() {
    return Uri.parse('$_baseUrl/${_model.id}:streamGenerateContent?alt=sse');
  }

  String? _sseDataPayload(String line) {
    if (!line.startsWith('data:')) return null;
    final data = line.substring(5).trimLeft();
    if (data.isEmpty || data == '[DONE]') return null;
    return data;
  }

  Map<String, String> get _requestHeaders {
    return {
      'Content-Type': 'application/json',
      'x-goog-api-key': _apiKey,
      'X-Ios-Bundle-Identifier': _iosBundleIdentifier,
    };
  }

  Map<String, dynamic> _imageRequestBody(
    Uint8List imageBytes, {
    required String systemPrompt,
    required String userPrompt,
    required int maxOutputTokens,
  }) {
    final base64Image = base64Encode(imageBytes);
    return <String, dynamic>{
      'system_instruction': {
        'parts': [
          {'text': systemPrompt},
        ],
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {
              'inlineData': {'mimeType': 'image/jpeg', 'data': base64Image},
            },
            {'text': userPrompt},
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0.2,
        'maxOutputTokens': maxOutputTokens,
        'topP': 0.8,
      },
    };
  }

  void _logErrorBody(String label, String body) {
    debugPrint(
      '[VisionAI] $label: '
      '${body.substring(0, body.length > 300 ? 300 : body.length)}',
    );
  }

  String? _safeErrorDetail(String body) {
    if (body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic>) {
          final message = error['message'];
          if (message is String && message.isNotEmpty) return message;
        }
      }
    } catch (_) {
      // Fall through to the truncated raw body below.
    }
    return body.substring(0, body.length > 120 ? 120 : body.length);
  }

  String _extractText(
    Map<String, dynamic> json, {
    bool allowEmptyText = false,
  }) {
    final candidates = json['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw CloudVisionException.malformedResponse('Missing candidates');
    }
    final first = candidates.first;
    if (first is! Map<String, dynamic>) {
      throw CloudVisionException.malformedResponse('Candidate was not a map');
    }
    final finishReason = first['finishReason'];
    if (finishReason is String && finishReason.isNotEmpty) {
      _lastFinishReason = finishReason;
      if (finishReason == 'MAX_TOKENS') {
        debugPrint(
          '[VisionAI] Gemini finished because max tokens were reached',
        );
      }
    }
    final content = first['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    if (parts == null || parts.isEmpty) {
      throw CloudVisionException.malformedResponse('Missing content parts');
    }
    final sb = StringBuffer();
    for (final part in parts) {
      if (part is! Map<String, dynamic>) continue;
      final txt = part['text'] as String?;
      if (txt != null) sb.write(txt);
    }
    final result = sb.toString();
    if (result.trim().isEmpty && !allowEmptyText) {
      throw CloudVisionException.malformedResponse('Missing text content');
    }
    return result;
  }

  @override
  void dispose() {
    if (_ownsClient) {
      _client.close();
    }
    super.dispose();
  }
}
