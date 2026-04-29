import '../models/settings_provider.dart';

class ScenePromptContext {
  const ScenePromptContext({
    this.detailLevel = DetailLevel.detailed,
    this.hazardSensitivity = HazardSensitivity.high,
  });

  factory ScenePromptContext.fromSettings(SettingsProvider settings) {
    return ScenePromptContext(
      detailLevel: settings.detailLevel,
      hazardSensitivity: settings.hazardSensitivity,
    );
  }

  final DetailLevel detailLevel;
  final HazardSensitivity hazardSensitivity;
}

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

  static const String invariantSafetyAndTtsRules =
      'You are the eyes for a blind person wearing a chest camera. '
      'Speak in plain English for text-to-speech. '
      'No markdown, no bullets, no headings, no emoji, no quote marks around your sentence. '
      'Never say "I see", "the image shows", "in this image", "it looks like", "I cannot", '
      '"unfortunately", "previous response", "cut off", "truncated", or "as an AI". '
      'Skip any category that is empty; do not say "no hazards". '
      'If the image is too dark, too blurry, or too empty to describe, say exactly: "Scene unclear, try again."';

  static const String fixedCloudSystemPrompt =
      '$invariantSafetyAndTtsRules '
      'DRAW THE SCENE FOR THE USER!! '
      'Dynamic routing instructions: Automatically prioritize immediate hazards first. If prominent text is visible, read it verbatim. Otherwise, describe the general layout in rich detail. '
      'You MUST use exact spatial clock-positions for all objects (e.g., "Tree at 1 o\'clock", "Car at 10 o\'clock"). '
      'Paint a practical mental map with concrete phrases. '
      'Use 4 to 6 complete spoken sentences with extreme verbosity and concrete detail for safe movement, under 170 words.';

  static const String fixedCloudUserPrompt =
      'What does a blind user need to know right now to move and stay safe? '
      'DRAW THE SCENE FOR THE USER!! Describe hazards first, then use mandatory clock positions for layout, read prominent text verbatim, and describe paths or doors.';

  static const int fixedCloudMaxOutputTokens = 420;

  ScenePromptContract build([
    ScenePromptContext context = const ScenePromptContext(),
  ]) {
    final detailInstructions = _detailInstructions(context.detailLevel);
    final hazardInstructions = _hazardInstructions(context.hazardSensitivity);
    return ScenePromptContract(
      systemPrompt: [
        invariantSafetyAndTtsRules,
        'Report hazards, layout, readable text verbatim, and landmarks. Use clock positions.',
        hazardInstructions,
        detailInstructions.system,
      ].join(' '),
      userPrompt: [
        'For a blind user moving right now, answer with only useful spoken scene information.',
        'Put hazards first when hazards are present. Describe layout, text, and paths.',
        detailInstructions.user,
      ].join(' '),
      maxOutputTokens: detailInstructions.maxOutputTokens,
    );
  }

  String _hazardInstructions(HazardSensitivity sensitivity) {
    return switch (sensitivity) {
      HazardSensitivity.low =>
        'Hazard sensitivity is low: call out only clear immediate hazards and obstacles within about ${HazardSensitivity.low.thresholdCm} centimeters.',
      HazardSensitivity.medium =>
        'Hazard sensitivity is medium: call out hazards and obstacles within about ${HazardSensitivity.medium.thresholdCm} centimeters or a few steps.',
      HazardSensitivity.high =>
        'Hazard sensitivity is high: call out possible hazards, moving objects, and obstacles within about ${HazardSensitivity.high.thresholdCm} centimeters.',
    };
  }

  _DetailPrompt _detailInstructions(DetailLevel detailLevel) {
    return switch (detailLevel) {
      DetailLevel.brief => const _DetailPrompt(
        system:
            'DRAW THE SCENE FOR THE USER!! Automatically prioritize hazards if present. Use exactly 3 complete spoken sentences, under 90 words. You MUST use exact spatial clock-positions (e.g., "Obstacle at 2 o\'clock"). Read prominent text verbatim. Otherwise, describe the general layout.',
        user:
            'Give a detailed but fast 3 sentence description for immediate use. Prioritize hazards, use clock positions, and read prominent text.',
        maxOutputTokens: 280,
      ),
      DetailLevel.detailed => const _DetailPrompt(
        system:
            'DRAW THE SCENE FOR THE USER!! Automatically prioritize hazards if present. Use 4 to 6 complete spoken sentences, under 170 words. You MUST use exact spatial clock-positions for all objects (e.g., "Tree at 1 o\'clock"). Read prominent text verbatim. Otherwise, describe the general layout in rich detail.',
        user:
            'Include rich practical detail in 4 to 6 complete sentences. Prioritize hazards, use mandatory clock positions, and read prominent text verbatim.',
        maxOutputTokens: 560,
      ),
    };
  }
}

class _DetailPrompt {
  const _DetailPrompt({
    required this.system,
    required this.user,
    required this.maxOutputTokens,
  });

  final String system;
  final String user;
  final int maxOutputTokens;
}
