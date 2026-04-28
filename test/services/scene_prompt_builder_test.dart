import 'package:flutter_test/flutter_test.dart';
import 'package:ican/models/settings_provider.dart';
import 'package:ican/services/scene_prompt_builder.dart';

void main() {
  group('ScenePromptBuilder', () {
    const builder = ScenePromptBuilder();

    test('rich scene contract asks for multi-sentence useful output', () {
      final contract = builder.build(
        detailLevel: DetailLevel.detailed,
        promptProfile: PromptProfile.balanced,
      );

      expect(contract.systemPrompt, contains('4-6 concise'));
      expect(contract.systemPrompt, contains('clock positions'));
      expect(contract.systemPrompt, contains('visible text verbatim'));
      expect(contract.maxOutputTokens, 700);
    });

    test('reading profile puts visible text first', () {
      final contract = builder.build(
        detailLevel: DetailLevel.brief,
        promptProfile: PromptProfile.reading,
      );

      expect(
        contract.systemPrompt,
        contains('Read visible text verbatim first'),
      );
      expect(contract.maxOutputTokens, 384);
    });

    test('safety profile leads with hazards and movement risks', () {
      final contract = builder.build(
        detailLevel: DetailLevel.detailed,
        promptProfile: PromptProfile.safety,
      );

      expect(contract.systemPrompt, contains('Lead with hazards'));
      expect(contract.systemPrompt, contains('within arm reach'));
    });
  });
}
