import 'package:flutter_test/flutter_test.dart';
import 'package:ican/models/settings_provider.dart';
import 'package:ican/services/scene_prompt_builder.dart';

void main() {
  group('ScenePromptBuilder', () {
    const builder = ScenePromptBuilder();

    test('single opinionated contract ignores detail/profile inputs', () {
      final brief = builder.build(
        detailLevel: DetailLevel.brief,
        promptProfile: PromptProfile.balanced,
      );
      final detailed = builder.build(
        detailLevel: DetailLevel.detailed,
        promptProfile: PromptProfile.reading,
      );

      expect(brief.systemPrompt, detailed.systemPrompt);
      expect(brief.userPrompt, detailed.userPrompt);
      expect(brief.maxOutputTokens, detailed.maxOutputTokens);
    });

    test('system prompt leads with hazards and uses clock positions', () {
      final contract = builder.build(
        detailLevel: DetailLevel.brief,
        promptProfile: PromptProfile.safety,
      );

      expect(contract.systemPrompt.toLowerCase(), contains('hazard'));
      expect(contract.systemPrompt.toLowerCase(), contains('clock position'));
      expect(contract.systemPrompt.toLowerCase(), contains('verbatim'));
      expect(contract.systemPrompt.toLowerCase(), contains('one breath'));
      expect(contract.systemPrompt.toLowerCase(), contains('walkable'));
    });

    test('system prompt bans meta phrases unsafe for a blind user', () {
      final contract = builder.build(
        detailLevel: DetailLevel.brief,
        promptProfile: PromptProfile.balanced,
      );
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
      final contract = builder.build(
        detailLevel: DetailLevel.brief,
        promptProfile: PromptProfile.balanced,
      );

      expect(contract.userPrompt.toLowerCase(), contains('blind user'));
      expect(contract.userPrompt.toLowerCase(), contains('safe'));
      expect(contract.userPrompt.toLowerCase(), contains('one breath'));
    });

    test('max output tokens stays small for spoken output', () {
      final contract = builder.build(
        detailLevel: DetailLevel.brief,
        promptProfile: PromptProfile.balanced,
      );

      expect(contract.maxOutputTokens, lessThanOrEqualTo(256));
      expect(contract.maxOutputTokens, greaterThan(0));
    });
  });
}
