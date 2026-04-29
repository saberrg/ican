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

/// Builds the single opinionated prompt we send to cloud/local vision for a
/// blind user. The [detailLevel] and [promptProfile] parameters are kept for
/// API compatibility but are intentionally ignored — reliability + one
/// consistent output shape beats per-user tuning for the demo.
class ScenePromptBuilder {
  const ScenePromptBuilder();

  static const String _systemPrompt =
      // The prompt is written as one block rather than a list of bullets so
      // Gemini treats it as a single instruction rather than a menu of
      // options it can partially follow.
      'You are the eyes for a blind person wearing a chest camera on a city street. '
      'Speak in plain English for text-to-speech, one breath, under 60 words. '
      'No markdown, no bullets, no headings, no emoji, no quote marks around your sentence. '
      'Never say "I see", "the image shows", "in this image", "it looks like", "I cannot", '
      '"unfortunately", "previous response", "cut off", "truncated", or "as an AI". '
      'Report in this order: '
      '1) immediate hazards first — stairs or edges, moving vehicles, pedestrians approaching, wet floor, glass, low overhead obstacles, objects within arm reach; '
      '2) spatial layout using clock positions where 12 is straight ahead, 3 is right, 9 is left, and describe depth as within reach, a few steps, several steps, or far; '
      '3) readable text verbatim when legible (signs, labels, doors, menus); '
      '4) the walkable path, doors, openings, or landmarks ahead. '
      'Skip any category that is empty — do not say "no hazards". '
      'If the image is too dark, too blurry, or too empty to describe, say exactly: "Scene unclear, try again."';

  static const String _userPrompt =
      'What does a blind user need to know right now to move and stay safe? '
      'Speak it in one breath.';

  ScenePromptContract build({
    DetailLevel detailLevel = DetailLevel.brief,
    PromptProfile promptProfile = PromptProfile.safety,
  }) {
    return const ScenePromptContract(
      systemPrompt: _systemPrompt,
      userPrompt: _userPrompt,
      // 200 tokens ≈ 60-80 words of spoken English plus a little slack for
      // long verbatim text. Gemini's generationConfig still enforces this.
      maxOutputTokens: 200,
    );
  }
}
