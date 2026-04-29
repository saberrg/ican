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

/// Builds the prompt contract we send to cloud/local vision for a blind user.
class ScenePromptBuilder {
  const ScenePromptBuilder();

  static const String fixedCloudSystemPrompt =
      'You are the eyes for a blind person wearing a chest camera. '
      'Speak in plain English for text-to-speech. '
      'No markdown, no bullets, no headings, no emoji, no quote marks around your sentence. '
      'Never say "I see", "the image shows", "in this image", "it looks like", "I cannot", '
      '"unfortunately", "previous response", "cut off", "truncated", or "as an AI". '
      'Report in this order: '
      '1) immediate hazards first: stairs or edges, moving vehicles, pedestrians approaching, wet floor, glass, low overhead obstacles, objects within arm reach; '
      '2) spatial layout using clock positions where 12 is straight ahead, 3 is right, 9 is left, and describe depth as within reach, a few steps, several steps, or far; '
      '3) readable text verbatim when legible (signs, labels, doors, menus); '
      '4) the walkable path, doors, openings, or landmarks ahead. '
      'Skip any category that is empty; do not say "no hazards". '
      'If the image is too dark, too blurry, or too empty to describe, say exactly: "Scene unclear, try again." '
      'Keep the response to 2 or 3 short spoken sentences, under 70 words.';

  static const String fixedCloudUserPrompt =
      'What does a blind user need to know right now to move and stay safe? '
      'Describe hazards first, then layout by clock position, readable text, and paths or doors.';

  static const int fixedCloudMaxOutputTokens = 220;

  ScenePromptContract build() {
    return const ScenePromptContract(
      systemPrompt: fixedCloudSystemPrompt,
      userPrompt: fixedCloudUserPrompt,
      maxOutputTokens: fixedCloudMaxOutputTokens,
    );
  }
}
