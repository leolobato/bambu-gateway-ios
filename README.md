# BambuGateway iOS

iOS client for [Bambu Gateway](../bambu-gateway/) — browse printers, upload 3MF files, preview G-code, and start prints from your phone.

## Features

- Connect to a local Bambu Gateway server
- Browse and manage 3MF files for printing
- Preview G-code before printing
- Configure printer profiles, filaments, and plates
- Browse MakerWorld for models
- Share Extension for quick file imports from other apps

## Requirements

- iOS 18.0+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- A running [Bambu Gateway](../bambu-gateway/) server on your local network

## Building

```bash
# Install XcodeGen if needed
brew install xcodegen

# Generate the Xcode project
xcodegen generate

# Build (no signing required for simulator)
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

### Signing for a physical device

Copy the example config and set your Apple Development Team ID:

```bash
cp Configuration/LocalSigning.xcconfig.example Configuration/LocalSigning.xcconfig
# Edit LocalSigning.xcconfig and set your DEVELOPMENT_TEAM and APP_BUNDLE_ID
xcodegen generate
```

`LocalSigning.xcconfig` is gitignored and won't be committed.

## Configuration

Point the app at your Bambu Gateway server URL in the Settings screen (e.g. `http://192.168.1.10:4844`).

## Disclaimer

This project was built almost entirely through agentic programming using [Claude Code](https://claude.ai/code). The architecture, implementation, and tests were generated through AI-assisted development with human guidance and review.

## License

MIT
