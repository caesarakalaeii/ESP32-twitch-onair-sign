#ifndef CONFIG_H
#define CONFIG_H

// GPIO Pin Assignments
#define ONAIR_PIN 16              // GPIO 16 for ON AIR indicator
#define STATUS_LED_PIN 2          // Built-in LED (most ESP32 boards)

// Timing Configuration
#define POLL_INTERVAL_MS 30000    // 30 seconds
#define WIFI_TIMEOUT_MS 20000     // 20 seconds for WiFi connection
#define TOKEN_REFRESH_MARGIN_MS 3600000  // Refresh token 1 hour before expiry

// API Endpoints
#define TWITCH_TOKEN_URL "https://id.twitch.tv/oauth2/token"
#define TWITCH_STREAMS_URL "https://api.twitch.tv/helix/streams"

// HTTP Configuration
#define HTTP_TIMEOUT_MS 10000     // 10 second timeout for API calls
#define MAX_RETRY_ATTEMPTS 3

// LED Blink Patterns (milliseconds)
#define LED_BLINK_CONNECTING 500
#define LED_BLINK_API_CALL 100
#define LED_BLINK_ERROR 200

#endif
