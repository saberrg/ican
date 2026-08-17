# Secrets Management

## API Key Injection

The Gemini API key is injected at **compile time** via Dart's `--dart-define` flag.
It is read in code as `const String.fromEnvironment('API_KEY')`.

### Running locally

```bash
flutter run --dart-define=API_KEY=<your-gemini-api-key>
```

### Building for release

```bash
flutter build ios --dart-define=API_KEY=<your-gemini-api-key>
flutter build apk --dart-define=API_KEY=<your-gemini-api-key>
```

### Generating a key

Create or rotate your key at https://aistudio.google.com/apikey

### Restricting the Gemini key

Use a dedicated key in a project you control. Do not record project numbers,
key identifiers, or key strings in this repository.

Required restrictions include:

- API target: `generativelanguage.googleapis.com`
- iOS bundle ID: `com.icannavigation.app`

The app sends the key in the `x-goog-api-key` request header and sends
`X-Ios-Bundle-Identifier: com.icannavigation.app` for iOS-restricted requests.
Set `IOS_BUNDLE_IDENTIFIER` to the current application bundle identifier on
release builds.

iOS API-key restrictions reduce accidental abuse but are not strong app-only
authentication. Keep the API restriction, monitor usage, and prefer a backend
proxy or app attestation layer before depending on the key as a durable
production boundary.

## Rules

- **`.env` must never be committed.** It is in `.gitignore` for local convenience only.
- Do not hardcode API keys anywhere in source files.
- For CI/CD, store the key as a secret environment variable and pass it via `--dart-define`.
