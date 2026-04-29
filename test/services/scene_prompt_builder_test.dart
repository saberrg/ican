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
      expect(first.systemPrompt, contains('Safety profile'));
    });

    test(
      'balanced profile includes hazards ahead layout text and landmarks',
      () {
        final contract = builder.build(
          const ScenePromptContext(profile: PromptProfile.balanced),
        );

        expect(contract.systemPrompt.toLowerCase(), contains('hazard'));
        expect(contract.systemPrompt.toLowerCase(), contains('clock position'));
        expect(contract.systemPrompt.toLowerCase(), contains('verbatim'));
        expect(contract.systemPrompt.toLowerCase(), contains('landmarks'));
        expect(contract.userPrompt.toLowerCase(), contains('ahead/layout'));
      },
    );

    test('safety profile prioritizes hazards movement and safe path', () {
      final contract = builder.build(
        const ScenePromptContext(profile: PromptProfile.safety),
      );

      expect(contract.systemPrompt.toLowerCase(), contains('movement'));
      expect(contract.systemPrompt.toLowerCase(), contains('within-reach'));
      expect(
        contract.systemPrompt.toLowerCase(),
        contains('safest visible path'),
      );
      expect(contract.userPrompt.toLowerCase(), contains('safety-first'));
    });

    test('reading profile reads visible text before spatial context', () {
      final contract = builder.build(
        const ScenePromptContext(profile: PromptProfile.reading),
      );

      expect(contract.systemPrompt.toLowerCase(), contains('reading profile'));
      expect(contract.systemPrompt.toLowerCase(), contains('verbatim first'));
      expect(contract.userPrompt.toLowerCase(), contains('visible text'));
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
        contains('4 or 5 complete spoken sentences'),
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
        const ScenePromptContext(profile: PromptProfile.safety),
      );

      expect(contract.userPrompt.toLowerCase(), contains('blind user'));
      expect(contract.userPrompt.toLowerCase(), contains('safe'));
      expect(contract.userPrompt.toLowerCase(), contains('hazards first'));
    });

    test('max output tokens stays small for spoken output', () {
      final contract = builder.build();

      expect(contract.maxOutputTokens, lessThanOrEqualTo(500));
      expect(contract.maxOutputTokens, greaterThan(0));
    });
  });
}
