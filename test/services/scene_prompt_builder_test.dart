import 'package:flutter_test/flutter_test.dart';
import 'package:ican/services/scene_prompt_builder.dart';

void main() {
  group('ScenePromptBuilder', () {
    const builder = ScenePromptBuilder();

    test('builds one fixed cloud prompt contract', () {
      final first = builder.build();
      final second = builder.build();

      expect(first.systemPrompt, second.systemPrompt);
      expect(first.userPrompt, second.userPrompt);
      expect(first.maxOutputTokens, second.maxOutputTokens);
      expect(first.systemPrompt, contains('2 or 3 short spoken sentences'));
    });

    test('system prompt leads with hazards and uses clock positions', () {
      final contract = builder.build();

      expect(contract.systemPrompt.toLowerCase(), contains('hazard'));
      expect(contract.systemPrompt.toLowerCase(), contains('clock position'));
      expect(contract.systemPrompt.toLowerCase(), contains('verbatim'));
      expect(contract.systemPrompt.toLowerCase(), contains('walkable'));
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
        expect(
          lower,
          contains(banned),
          reason:
              'system prompt must explicitly forbid the phrase "$banned" so '
              'the model avoids it in output.',
        );
      }
    });

    test('user prompt is a direct safety-first question', () {
      final contract = builder.build();

      expect(contract.userPrompt.toLowerCase(), contains('blind user'));
      expect(contract.userPrompt.toLowerCase(), contains('safe'));
      expect(contract.userPrompt.toLowerCase(), contains('hazards first'));
    });

    test('max output tokens stays small for spoken output', () {
      final contract = builder.build();

      expect(contract.maxOutputTokens, lessThanOrEqualTo(400));
      expect(contract.maxOutputTokens, greaterThan(0));
    });
  });
}
