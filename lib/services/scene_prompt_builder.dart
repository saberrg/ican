import '../models/settings_provider.dart';

class ScenePromptContract {
  const ScenePromptContract({
    required this.systemPrompt,
    required this.userPrompt,
    required this.maxOutputTokens,
  });

  final String systemPrompt;
  final String userPrompt;
  final int maxOutputTokens;
}

class ScenePromptBuilder {
  const ScenePromptBuilder();

  ScenePromptContract build({
    required DetailLevel detailLevel,
    required PromptProfile promptProfile,
  }) {
    final sentenceContract = switch (detailLevel) {
      DetailLevel.brief =>
        'Return 1-2 short sentences unless there is an immediate safety risk.',
      DetailLevel.detailed =>
        'Return 4-6 concise, useful sentences when enough scene detail exists.',
    };

    final profileContract = switch (promptProfile) {
      PromptProfile.balanced =>
        'Describe the overall scene, directly-ahead details, useful landmarks, visible text, and hazards.',
      PromptProfile.safety =>
        'Lead with hazards, obstacles, moving people, vehicles, stairs, edges, crossings, and anything within arm reach. Keep non-safety detail brief.',
      PromptProfile.navigation =>
        'Lead with clear walking space, doors, paths, exits, landmarks, signs, and left/right/ahead orientation cues.',
      PromptProfile.reading =>
        'Read visible text verbatim first, including signs, labels, screens, buttons, menus, or documents, then briefly describe the setting.',
    };

    final systemPrompt = [
      'You are the iCan vision system for a blind person using a chest camera.',
      'Write plain spoken English for text-to-speech. Do not use markdown, bullets, lists, headings, or the phrase "I see."',
      sentenceContract,
      profileContract,
      'Mention immediate safety hazards first when present.',
      'Use clock positions for direction, such as "chair at 2 o clock", and call out what is directly ahead or within reach.',
      'Read visible text verbatim when it is legible.',
      'Include orientation cues and uncertainty only when helpful.',
    ].join('\n');

    return ScenePromptContract(
      systemPrompt: systemPrompt,
      userPrompt:
          'Describe this image for safe navigation and awareness. Keep it concise and spoken.',
      maxOutputTokens: detailLevel == DetailLevel.brief ? 384 : 700,
    );
  }
}
