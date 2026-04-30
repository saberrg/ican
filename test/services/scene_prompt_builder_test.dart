import 'package:flutter_test/flutter_test.dart';
import 'package:ican/models/settings_provider.dart';
import 'package:ican/services/scene_prompt_builder.dart';

void main() {
  group('ScenePromptBuilder', () {
    const builder = ScenePromptBuilder();

    test('builds deterministic default cloud prompt contract', () {
      final first = builder.build();
      final second = builder.build();

      expect(first.systemPrompt, second.systemPrompt);
      expect(first.userPrompt, second.userPrompt);
      expect(first.maxOutputTokens, second.maxOutputTokens);
      expect(first.systemPrompt, contains('Report hazards'));
      expect(first.systemPrompt, contains('150 centimeters'));
    });

    test('detail level and hazard sensitivity affect prompt contract', () {
      final brief = builder.build(
        const ScenePromptContext(
          detailLevel: DetailLevel.brief,
          hazardSensitivity: HazardSensitivity.low,
        ),
      );
      final detailed = builder.build(
        const ScenePromptContext(
          detailLevel: DetailLevel.detailed,
          hazardSensitivity: HazardSensitivity.high,
        ),
      );

      expect(brief.maxOutputTokens, lessThan(detailed.maxOutputTokens));
      expect(brief.systemPrompt, contains('40 centimeters'));
      expect(detailed.systemPrompt, contains('150 centimeters'));
      expect(
        brief.systemPrompt,
        contains('exactly 3 complete spoken sentences'),
      );
      expect(
        detailed.systemPrompt,
        contains('exactly 5 complete spoken sentences'),
      );
    });

    test('system prompt bans meta phrases unsafe for a blind user', () {
      final contract = builder.build();
      final lower = contract.systemPrompt.toLowerCase();

      for (final banned in <String>[
        'i see',
        'the image shows',
        'it looks like',
        'previous response',
        'cut off',
        'markdown',
        'as an ai',
      ]) {
        expect(lower, contains(banned));
      }
    });

    test('user prompt is a direct safety-first request', () {
      final contract = builder.build();

      expect(contract.userPrompt.toLowerCase(), contains('blind user'));
      expect(contract.userPrompt.toLowerCase(), contains('hazards first'));
    });

    test('max output tokens stays bounded for spoken output', () {
      final contract = builder.build();

      expect(contract.maxOutputTokens, lessThanOrEqualTo(650));
      expect(contract.maxOutputTokens, greaterThan(0));
    });
  });
}
