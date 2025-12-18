# ESP32 Twitch On-Air Sign

An ESP32-WROOM firmware that monitors the Twitch API and controls GPIO 16 to indicate when a streamer goes live. Perfect for creating an "ON AIR" sign, controlling lights, or triggering other devices when your favorite streamer starts streaming.

## Features

- Monitors Twitch API every 30 seconds
- GPIO 16 goes HIGH when streamer is live, LOW when offline
- Status LED shows connection and polling activity
- Automatic WiFi reconnection
- OAuth token management with automatic refresh
- Comprehensive error handling and recovery
- Easy configuration via Makefile

## Hardware Requirements

- ESP32-WROOM development board
- USB cable for power and programming
- Optional: LED, relay module, or other indicator connected to GPIO 16

## Software Requirements

- [PlatformIO](https://platformio.org/) (install via VS Code extension or CLI)
- USB drivers for your ESP32 board (usually CH340 or CP2102)

## Twitch API Setup

Before you can use this project, you need to register an application with Twitch to get API credentials:

1. Go to the [Twitch Developer Console](https://dev.twitch.tv/console/apps)
2. Log in with your Twitch account
3. Click **"Register Your Application"**
4. Fill in the form:
   - **Name**: "My ESP32 On-Air Sign" (or any name you prefer)
   - **OAuth Redirect URLs**: `http://localhost` (required but not used)
   - **Category**: IoT
5. Click **"Create"**
6. On the application page, copy the **Client ID**
7. Click **"New Secret"** and copy the **Client Secret** (save it immediately, you can't view it again!)

## Installation

### 1. Clone the Repository

```bash
git clone https://github.com/yourusername/ESP32-twitch-onair-sign.git
cd ESP32-twitch-onair-sign
```

### 2. Configure Your Credentials

Copy the example secrets file and fill in your credentials:

```bash
cp include/secrets.example.h include/secrets.h
```

Edit `include/secrets.h` with your favorite text editor and make the following changes:

1. **Change the header guard** at the top of the file from `SECRETS_EXAMPLE_H` to `SECRETS_H`:
   ```cpp
   #ifndef SECRETS_H
   #define SECRETS_H
   ```

2. **Fill in your actual credentials**:
   ```cpp
   // WiFi Credentials
   #define WIFI_SSID "YourWiFiNetwork"
   #define WIFI_PASSWORD "YourWiFiPassword"

   // Twitch API Credentials (from the setup above)
   #define TWITCH_CLIENT_ID "your_client_id_here"
   #define TWITCH_CLIENT_SECRET "your_client_secret_here"

   // Twitch Channel to Monitor (use the username, not display name)
   #define TWITCH_STREAMER_NAME "streamer_username"
   ```

**Important**: Use the streamer's **username** (lowercase, URL format), not their display name. For example, if the channel URL is `twitch.tv/coolstreamer`, use `coolstreamer`.

### 3. Build and Upload

Connect your ESP32 to your computer via USB, then:

```bash
make upload
```

This will:
- Check that `secrets.h` exists
- Install dependencies (ArduinoJson)
- Compile the firmware
- Upload to your ESP32

### 4. Monitor Serial Output

To see the device in action:

```bash
make monitor
```

Or combine upload and monitor:

```bash
make flash
```

Press `Ctrl+C` to exit the monitor.

## Makefile Commands

| Command | Description |
|---------|-------------|
| `make help` | Show all available commands |
| `make build` | Compile without uploading |
| `make upload` | Build and flash to ESP32 |
| `make monitor` | Open serial monitor (115200 baud) |
| `make flash` | Upload and monitor (combined) |
| `make clean` | Clean build files |
| `make check-secrets` | Verify secrets.h exists |
| `make update-deps` | Update library dependencies |

## LED Status Guide

The built-in LED (GPIO 2) shows the current system status:

| Pattern | Meaning |
|---------|---------|
| **Slow blink** (500ms) | Connecting to WiFi |
| **Solid ON** | Connected and operational |
| **Quick flash** (100ms) | Making API request |
| **Fast blink** (200ms) | Error state - will restart soon |
| **OFF** | System halted (critical error) |

## Serial Monitor Output

When everything is working, you'll see output like this:

```
========================================
ESP32 Twitch On-Air Sign
========================================

Initialized GPIO 16 as output (ON AIR indicator)
Status LED initialized
Monitoring streamer: coolstreamer
Poll interval: 30 seconds

----------------------------------------
Connecting to WiFi...
.....Connected! IP: 192.168.1.100
Signal strength: -45 dBm

----------------------------------------
Acquiring Twitch OAuth token...
OAuth token acquired successfully!
Token expires in: 5011271 seconds

----------------------------------------
Checking stream status [10s]...
Stream still OFFLINE

----------------------------------------
Checking stream status [40s]...

========================================
STREAM STATUS CHANGED: LIVE
========================================
  Title: Playing Awesome Game!
  Game: Awesome Game
  Viewers: 42
```

## Configuration

You can customize the behavior by editing `include/config.h`:

```cpp
// Change poll interval (default: 30 seconds)
#define POLL_INTERVAL_MS 60000    // Poll every 60 seconds

// Change GPIO pins
#define ONAIR_PIN 16              // GPIO for ON AIR indicator
#define STATUS_LED_PIN 2          // Built-in LED

// Change timeouts
#define WIFI_TIMEOUT_MS 20000     // WiFi connection timeout
#define HTTP_TIMEOUT_MS 10000     // API request timeout
```

## Hardware Connection

### Simple LED Indicator

```
GPIO 16 → 330Ω Resistor → LED → GND
```

### Relay Module (Recommended for high-voltage loads)

```
GPIO 16 → Relay Module IN → Relay Module controls external device
```

Make sure to use a 3.3V-compatible relay module, or use a 5V relay module with proper level shifting.

### Power

The ESP32 can be powered via USB (5V). Most USB ports provide sufficient current (500mA) for the ESP32 plus a small indicator LED.

## Troubleshooting

### WiFi Connection Issues

**Symptom**: "WiFi connection failed!" repeating

**Solutions**:
- Double-check WIFI_SSID and WIFI_PASSWORD in `secrets.h`
- Ensure your WiFi network is 2.4GHz (ESP32 doesn't support 5GHz)
- Check that your WiFi router is within range
- Try moving ESP32 closer to the router

### Token Acquisition Failed

**Symptom**: "Token acquisition failed" error

**Solutions**:
- Verify TWITCH_CLIENT_ID and TWITCH_CLIENT_SECRET are correct
- Make sure you copied the full client secret (no extra spaces)
- Check that your Twitch application is active in the developer console
- Verify ESP32 has internet access (can it reach `id.twitch.tv`?)

### Streamer Not Found

**Symptom**: "Streamer not found" in error message

**Solutions**:
- Use the streamer's **username** (from the URL), not display name
- Username should be lowercase
- Verify the streamer exists by visiting `twitch.tv/username`

### GPIO 16 Not Changing

**Symptom**: Stream goes live but GPIO 16 doesn't go HIGH

**Solutions**:
- Verify with serial monitor that status changes are detected
- Check GPIO 16 with a multimeter (should read ~3.3V when HIGH)
- Ensure your external circuit doesn't draw too much current (max 12mA per pin)
- Try the built-in LED test first to confirm software is working

### System Keeps Restarting

**Symptom**: Device enters error state and restarts every 30 seconds

**Solutions**:
- Check serial monitor for specific error messages
- Verify internet connection is stable
- Check if Twitch API is operational: https://status.twitch.tv
- Try increasing timeouts in `config.h`

### Compilation Errors

**Symptom**: Build fails with "secrets.h: No such file or directory"

**Solution**: You forgot to create `include/secrets.h` from the example file:
```bash
cp include/secrets.example.h include/secrets.h
```

**Symptom**: Build fails with library errors

**Solution**: Update PlatformIO and dependencies:
```bash
make update-deps
pio pkg update
```

## Project Structure

```
ESP32-twitch-onair-sign/
├── include/                    # Header files
│   ├── secrets.example.h      # Template for credentials
│   ├── secrets.h              # Your credentials (gitignored)
│   ├── config.h               # System configuration
│   ├── wifi_manager.h         # WiFi connection management
│   ├── twitch_api.h           # Twitch API interface
│   └── led_controller.h       # LED status indicators
├── src/                       # Source files
│   ├── main.cpp               # Main application
│   ├── wifi_manager.cpp       # WiFi implementation
│   ├── twitch_api.cpp         # Twitch API implementation
│   └── led_controller.cpp     # LED implementation
├── platformio.ini             # PlatformIO configuration
├── Makefile                   # Build commands
├── .gitignore                 # Git ignore rules
├── LICENSE                    # AGPL-3.0 license
└── README.md                  # This file
```

## How It Works

### State Machine

The firmware uses a state machine with four main states:

1. **WiFi Connecting**: Attempts to connect to WiFi (retries 3x)
2. **Token Acquiring**: Gets OAuth token from Twitch (retries 3x)
3. **Operational**: Polls API every 30 seconds, controls GPIO 16
4. **Error**: Waits 30 seconds then restarts the ESP32

### Twitch API Flow

1. Acquire OAuth token using Client Credentials flow
2. Use token to call GET `/helix/streams?user_login=STREAMER`
3. If response data array is empty: streamer is offline
4. If response data array has elements: streamer is live
5. Proactively refresh token 1 hour before expiry

### Error Recovery

- **WiFi disconnection**: Immediately attempts reconnection
- **API failures**: Retries 3 times with 5-second delays
- **Token expiration**: Automatically refreshes before expiry
- **Multiple consecutive failures**: Enters error state and restarts

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

This project is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0). See the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [PlatformIO](https://platformio.org/) - Development platform
- [ArduinoJson](https://arduinojson.org/) - JSON parsing library
- [Twitch API](https://dev.twitch.tv/docs/api/) - Stream data

## Support

If you encounter issues:

1. Check the [Troubleshooting](#troubleshooting) section above
2. Review the serial monitor output for specific error messages
3. Open an issue on GitHub with:
   - Your serial monitor output
   - Hardware details (ESP32 board model)
   - Configuration changes you made

## Future Enhancements

Potential improvements for future versions:

- Web interface for configuration (no need to edit code)
- Support for monitoring multiple streamers
- WebSocket connection for instant notifications
- E-ink display showing stream info
- Home Assistant / MQTT integration
- Over-the-air (OTA) firmware updates

---

Made with ❤️ for the Twitch community
