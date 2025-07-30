# SparkAirPlay - macOS AirPlay Receiver

A custom AirPlay receiver implementation for macOS that allows you to stream content from iOS devices (iPhone/iPad) directly to your Mac. The app creates a full-screen Space that integrates seamlessly with macOS's Mission Control and supports standard swipe gestures between Spaces.

## Features

- 🎯 **Native AirPlay Receiver**: Advertises as an AirPlay target over Bonjour
- 🖥️ **Full-Screen Space Integration**: Becomes its own macOS Space with proper swipe gesture support
- 🎬 **Hardware-Accelerated Video**: Uses VideoToolbox for H.264 decoding
- 🔊 **Audio Playback**: Supports AAC audio streams
- 📱 **iOS Device Discovery**: Automatically appears in iOS Control Center
- 🎮 **Gesture Passthrough**: Maintains standard macOS swipe gestures for Space switching
- ⚡ **Real-Time Streaming**: Low-latency RTSP/RTP implementation

## Requirements

- macOS 12.0 or later
- Xcode 14.0 or later
- Swift 5.7 or later
- Network access for Bonjour discovery

## Installation

1. Clone or download this project
2. Open `SparkAirPlay.xcodeproj` in Xcode
3. Build and run the project (⌘+R)

## How to Use

### Starting the Receiver

1. Launch the SparkAirPlay app
2. The service will automatically start and advertise itself on the network
3. You'll see a discovery screen with connection instructions

### Connecting from iOS

1. On your iPhone or iPad, open Control Center:
   - iPhone X and later: Swipe down from the top-right corner
   - iPhone 8 and earlier: Swipe up from the bottom
   - iPad: Swipe down from the top-right corner

2. Tap the AirPlay button (📺 or 🎵 icon)

3. Select "SparkAirPlay" from the list of available devices

4. Start playing content (video, music, or screen mirroring)

### Full-Screen Mode

- Click the "Full Screen" button to enter full-screen mode
- The app will create its own Space in Mission Control
- Use standard macOS gestures to switch between Spaces:
  - Three-finger swipe left/right on trackpad
  - Control + Left/Right arrow keys
  - Mission Control (F3) to see all Spaces

### Disconnecting

- Click the "Disconnect" button in the app
- Or stop AirPlay from your iOS device's Control Center

## Architecture

### Core Components

1. **AirPlayReceiverService**: Handles Bonjour discovery and RTSP server
2. **RTSPServer**: Implements RTSP protocol for AirPlay communication
3. **VideoDecoder**: Hardware-accelerated H.264 video decoding using VideoToolbox
4. **AudioPlayer**: AAC audio playback using AVAudioEngine
5. **AirPlayManager**: Coordinates all components and manages UI state

### Network Protocol

The app implements the AirPlay protocol stack:

- **Bonjour**: Service discovery (`_airplay._tcp.`)
- **RTSP**: Real Time Streaming Protocol for session management
- **RTP**: Real-time Transport Protocol for media streaming
- **H.264**: Video codec with hardware acceleration
- **AAC**: Audio codec for high-quality sound

### Full-Screen Space Behavior

The app configures its window with specific collection behaviors:

```swift
window.collectionBehavior = [
    .fullScreenPrimary,      // Creates its own Space
    .fullScreenAllowsTiling, // Allows Split View
    .managed                 // Participates in Mission Control
]
```

## Project Structure

```
SparkAirPlay/
├── SparkAirPlayApp.swift          # Main app entry point
├── ContentView.swift              # Main UI coordinator
├── AirPlayManager.swift           # Core AirPlay management
├── AirPlayReceiverService.swift   # Bonjour and RTSP service
├── RTSPServer.swift               # RTSP protocol implementation
├── VideoDecoder.swift             # H.264 video decoding
├── AudioPlayer.swift              # AAC audio playback
├── AirPlayVideoView.swift         # Video display view
├── DiscoveryView.swift            # Connection UI
└── SparkAirPlay.entitlements      # App permissions
```

## Permissions

The app requires the following entitlements:

- `com.apple.security.network.server`: For RTSP server
- `com.apple.security.network.client`: For network communication
- `com.apple.security.device.audio-input`: For audio processing
- `com.apple.security.device.camera`: For video processing

## Troubleshooting

### Connection Issues

1. **Device not appearing in AirPlay list**:
   - Ensure both devices are on the same Wi-Fi network
   - Check that the service is running (green indicator)
   - Restart the app and try again

2. **Video not displaying**:
   - Check console logs for decoder errors
   - Ensure the iOS device is sending H.264 video
   - Try disconnecting and reconnecting

3. **Audio not playing**:
   - Check system audio settings
   - Ensure the app has audio permissions
   - Try adjusting volume on both devices

### Performance Issues

1. **Choppy video playback**:
   - Close other resource-intensive apps
   - Ensure strong Wi-Fi signal
   - Check for network interference

2. **High CPU usage**:
   - Hardware acceleration should reduce CPU load
   - Check Activity Monitor for other processes

## Development Notes

### Extending the Implementation

To add support for additional AirPlay features:

1. **Screen Mirroring**: Extend the RTSP server to handle mirroring requests
2. **Audio-Only Mode**: Add support for audio-only AirPlay sessions
3. **Multiple Clients**: Modify the server to handle multiple simultaneous connections
4. **Encryption**: Implement AirPlay's encryption for secure streaming

### Testing

- Use iOS Simulator's AirPlay feature for basic testing
- Test with real iOS devices for full functionality
- Verify Space behavior with multiple displays
- Test gesture passthrough in full-screen mode

## Known Limitations

1. **Encryption**: Current implementation doesn't support AirPlay encryption
2. **Multiple Streams**: Only supports one client connection at a time
3. **Advanced Codecs**: Limited to H.264/AAC (most common AirPlay formats)
4. **iOS Compatibility**: Tested with iOS 15+ devices

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly on real devices
5. Submit a pull request

## License

This project is provided as-is for educational and development purposes. Please ensure compliance with Apple's AirPlay licensing requirements for commercial use.

## Support

For issues and questions:
1. Check the troubleshooting section above
2. Review console logs for error messages
3. Test with different iOS devices and content types
4. Ensure network connectivity and permissions are correct

---

**Note**: This implementation is designed for development and testing purposes. For production use, consider implementing additional security measures and error handling.