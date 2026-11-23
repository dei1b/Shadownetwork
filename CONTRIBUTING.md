# Contributing to Shadow Network

Use the GitHub issue templates to report a bug or propose a change. Check
existing issues first. For broad changes, discuss the scope before opening a
pull request.

Follow the setup steps in the [README](README.md) and the repository guidelines
in [AGENTS.md](AGENTS.md). Run these commands from the repository root before
opening a pull request:

```sh
flutter pub get
flutter analyze
flutter test
```

Keep pull requests focused. Describe the user-facing change and list the checks
you ran. Include screenshots or recordings for UI changes. For changes to SOS
delivery, peer discovery, or relay behavior, record which Android devices and
transport you tested and distinguish physical-device results from automated
checks.

Use synthetic or redacted examples. Keep private keys, credentials, registration
codes, personal data, and real SOS messages out of issues and pull requests.
Report suspected vulnerabilities through the [security policy](SECURITY.md).
Follow the [code of conduct](CODE_OF_CONDUCT.md) in project spaces.
