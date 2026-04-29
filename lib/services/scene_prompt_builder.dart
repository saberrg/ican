import '../models/settings_provider.dart';

class ScenePromptContext {
  const ScenePromptContext({
    this.profile = PromptProfile.safety,
    this.detailLevel = DetailLevel.brief,
    this.hazardSensitivity = HazardSensitivity.medium,
  });

  factory ScenePromptContext.fromSettings(SettingsProvider settings) {
    return ScenePromptContext(
      profile: settings.promptProfile,
      detailLevel: settings.detailLevel,
      hazardSensitivity: settings.hazardSensitivity,
    );
  }

  final PromptProfile profile;
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
      'Report in this order: immediate hazards first; spatial layout using clock positions where 12 is straight ahead, 3 is right, 9 is left, and depth is within reach, a few steps, several steps, or far; readable text verbatim when legible; then walkable path, doors, openings, or landmarks ahead. '
      'Keep the response to 2 or 3 short spoken sentences, under 70 words.';

  static const String fixedCloudUserPrompt =
      'What does a blind user need to know right now to move and stay safe? '
      'Describe hazards first, then layout by clock position, readable text, and paths or doors.';

  static const int fixedCloudMaxOutputTokens = 220;

  ScenePromptContract build([
    ScenePromptContext context = const ScenePromptContext(),
  ]) {
    final profileInstructions = _profileInstructions(context.profile);
    final detailInstructions = _detailInstructions(context.detailLevel);
    final hazardInstructions = _hazardInstructions(context.hazardSensitivity);
    return ScenePromptContract(
      systemPrompt: [
        invariantSafetyAndTtsRules,
        profileInstructions.system,
        hazardInstructions,
        detailInstructions.system,
      ].join(' '),
      userPrompt: [
        'For a blind user moving right now, answer with only useful spoken scene information.',
        'Put hazards first when hazards are present.',
        profileInstructions.user,
        detailInstructions.user,
      ].join(' '),
      maxOutputTokens: detailInstructions.maxOutputTokens,
    );
  }

  _ProfilePrompt _profileInstructions(PromptProfile profile) {
    switch (profile) {
      case PromptProfile.safety:
        return const _ProfilePrompt(
          system:
              'Safety profile: report hazards, movement, within-reach obstacles, drop-offs, crossings, vehicles, approaching people, and the safest visible path first. Keep non-safety context short.',
          user:
              'Give the safety-first description: hazards, movement, within-reach obstacles, and the safe path before anything else.',
        );
      case PromptProfile.reading:
        return const _ProfilePrompt(
          system:
              'Reading profile: read visible text verbatim first, including signs, labels, screens, buttons, doors, and documents. Then add immediate safety hazards and brief spatial context.',
          user:
              'Read visible text verbatim first, then add safety and spatial context needed right now.',
        );
      case PromptProfile.navigation:
        return const _ProfilePrompt(
          system:
              'Navigation profile: report clear walking space, doors, openings, signs, landmarks, obstacles, and left-right-ahead orientation. Mention hazards immediately if present.',
          user:
              'Describe paths, doors, signs, landmarks, and obstacles using clock positions.',
        );
      case PromptProfile.balanced:
        return const _ProfilePrompt(
          system:
              'Balanced profile: report hazards if present, what is directly ahead, spatial layout, readable text verbatim, and landmarks or doors. Use clock positions where useful.',
          user:
              'Describe hazards if present, ahead/layout, readable text, and landmarks or doors.',
        );
    }
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
            'Keep the response to 1 or 2 short spoken sentences, under 45 words.',
        user: 'Keep it brief for immediate use.',
        maxOutputTokens: 160,
      ),
      DetailLevel.detailed => const _DetailPrompt(
        system:
            'Keep the response to 2 or 3 short spoken sentences, under 85 words.',
        user: 'Include useful detail without slowing speech.',
        maxOutputTokens: 260,
      ),
    };
  }
}

class _ProfilePrompt {
  const _ProfilePrompt({required this.system, required this.user});

  final String system;
  final String user;
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
