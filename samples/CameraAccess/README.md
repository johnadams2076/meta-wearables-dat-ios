# Camera Access App

A sample iOS application demonstrating integration with Meta Wearables Device Access Toolkit. This app showcases streaming video from Meta AI glasses, capturing photos, and managing connection states.

## Features

- Connect to Meta AI glasses
- Stream camera feed from the device
- Capture photos from glasses
- Copy visible text from the current frame with on-device OCR
- Share captured photos
- Open firmware and glasses app update flows when required

## Prerequisites

- iOS 17.0+
- Xcode 14.0+
- Swift 5.0+
- Meta Wearables Device Access Toolkit (included as a dependency)
- A Meta AI glasses device for testing (optional for development)

## Building the app

### Using Xcode

1. Clone this repository
1. Open the project in Xcode
1. Select your target device
1. Click the "Build" button or press `Cmd+B` to build the project
1. To run the app, click the "Run" button (▶️) or press `Cmd+R`

## Running the app

1. Turn 'Developer Mode' on in the Meta AI app.
1. Launch the app.
1. Press the "Connect" button to complete app registration.
1. Once connected, the camera stream from the device will be displayed
1. Use the on-screen controls to:
   - Capture photos
   - View and save captured photos
   - Disconnect from the device
1. If a firmware update is required, tap "Update firmware" from the connection screen.
1. If session start reports that the app on the glasses is outdated, tap "Update app on glasses" from the connection screen.

## Painting identification integration notes

The Camera Access sample already exposes the two capture paths you would use for artwork recognition:

- `VideoFrame.makeUIImage()` for live frames
- `Stream.capturePhoto(format: .jpeg)` for higher-quality still images

For painting identification, prefer the captured JPEG photo path over live frames. The still image is a better fit for network APIs and avoids sending repeated low-detail stream frames over the network.

### API options

| Option | Best at | Tradeoffs |
| ------ | ------- | --------- |
| Apple Vision + custom Core ML model | Fully on-device style or collection-specific classification | Requires training and shipping your own art model; no built-in painting-title recognition |
| Google Cloud Vision Web Detection | Matching famous works that already appear on the web | Cloud upload required; strongest when the artwork already has public image coverage |
| GPT-4o / Gemini vision APIs | Natural-language identification, artist/style summaries, fallback descriptions when exact matches are uncertain | Cloud upload required; results depend on model knowledge instead of a dedicated museum catalog |
| Museum collection APIs | Enriching metadata after you already know a likely title or artist | Lookup only; they do not identify a painting from pixels by themselves |

### Recommended first integration

1. Keep streaming local to the app until the user explicitly captures a photo.
1. Send the JPEG produced by `capturePhoto(format: .jpeg)` to a backend proxy instead of embedding third-party API keys in the iOS app.
1. Start with one general vision API for identification and fallback description.
1. Optionally follow that result with a museum collection lookup to enrich the response with collection, date, or attribution details.

This staged approach keeps the sample aligned with DAT's existing camera pipeline while leaving room to swap providers based on privacy, latency, and recognition quality requirements.

## Troubleshooting

For issues related to the Meta Wearables Device Access Toolkit, please refer to the [developer documentation](https://wearables.developer.meta.com/docs/develop/) or visit our [discussions forum](https://github.com/facebook/meta-wearables-dat-ios/discussions)

## License

This source code is licensed under the license found in the LICENSE file in the root directory of this source tree.
