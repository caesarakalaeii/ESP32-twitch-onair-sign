#include <Arduino.h>
#include "secrets.h"
#include "config.h"
#include "wifi_manager.h"
#include "twitch_api.h"
#include "led_controller.h"

// Global objects
WiFiManager wifiMgr;
TwitchAPI twitchAPI(TWITCH_CLIENT_ID, TWITCH_CLIENT_SECRET);
LEDController statusLED(STATUS_LED_PIN);

// State machine
enum SystemState {
    STATE_INIT,
    STATE_WIFI_CONNECTING,
    STATE_TOKEN_ACQUIRING,
    STATE_OPERATIONAL,
    STATE_ERROR
};

SystemState current_state = STATE_INIT;
unsigned long last_poll_ms = 0;
bool onair_state = false;
int retry_count = 0;

void handleWiFiConnection();
void handleTokenAcquisition();
void handleOperationalMode();
void handleErrorState();

void setup() {
    // Initialize Serial
    Serial.begin(115200);
    delay(1000);  // Give serial time to initialize

    Serial.println("\n\n========================================");
    Serial.println("ESP32 Twitch On-Air Sign");
    Serial.println("========================================");
    Serial.println();

    // Initialize GPIO
    pinMode(ONAIR_PIN, OUTPUT);
    digitalWrite(ONAIR_PIN, LOW);
    Serial.print("Initialized GPIO ");
    Serial.print(ONAIR_PIN);
    Serial.println(" as output (ON AIR indicator)");

    // Initialize status LED
    statusLED.begin();
    statusLED.setPattern(LED_BLINK_SLOW);
    Serial.println("Status LED initialized");

    Serial.print("Monitoring streamer: ");
    Serial.println(TWITCH_STREAMER_NAME);
    Serial.print("Poll interval: ");
    Serial.print(POLL_INTERVAL_MS / 1000);
    Serial.println(" seconds");
    Serial.println();

    current_state = STATE_WIFI_CONNECTING;
}

void loop() {
    // Update LED animations (non-blocking)
    statusLED.update();

    // Execute current state handler
    switch (current_state) {
        case STATE_WIFI_CONNECTING:
            handleWiFiConnection();
            break;

        case STATE_TOKEN_ACQUIRING:
            handleTokenAcquisition();
            break;

        case STATE_OPERATIONAL:
            handleOperationalMode();
            break;

        case STATE_ERROR:
            handleErrorState();
            break;

        default:
            break;
    }
}

void handleWiFiConnection() {
    Serial.println("----------------------------------------");
    Serial.println("Connecting to WiFi...");
    statusLED.setPattern(LED_BLINK_SLOW);

    WiFiStatus status = wifiMgr.connect(WIFI_SSID, WIFI_PASSWORD, WIFI_TIMEOUT_MS);

    if (status == WIFI_CONNECTED) {
        Serial.print("Connected! IP: ");
        Serial.println(wifiMgr.getLocalIP());
        Serial.print("Signal strength: ");
        Serial.print(wifiMgr.getSignalStrength());
        Serial.println(" dBm");
        Serial.println();

        statusLED.setPattern(LED_ON);
        current_state = STATE_TOKEN_ACQUIRING;
        retry_count = 0;
    } else {
        Serial.println("WiFi connection failed!");
        retry_count++;
        Serial.print("Retry count: ");
        Serial.print(retry_count);
        Serial.print("/");
        Serial.println(MAX_RETRY_ATTEMPTS);

        if (retry_count >= MAX_RETRY_ATTEMPTS) {
            current_state = STATE_ERROR;
            statusLED.setPattern(LED_BLINK_FAST);
        } else {
            delay(5000);  // Wait before retry
        }
    }
}

void handleTokenAcquisition() {
    Serial.println("----------------------------------------");
    Serial.println("Acquiring Twitch OAuth token...");
    statusLED.setPattern(LED_FLASH_QUICK);

    if (twitchAPI.acquireToken()) {
        Serial.println("Token acquired successfully!");
        Serial.println();

        statusLED.setPattern(LED_ON);
        current_state = STATE_OPERATIONAL;
        retry_count = 0;
        last_poll_ms = 0;  // Force immediate first poll
    } else {
        Serial.print("Token acquisition failed: ");
        Serial.println(twitchAPI.getLastError());
        retry_count++;
        Serial.print("Retry count: ");
        Serial.print(retry_count);
        Serial.print("/");
        Serial.println(MAX_RETRY_ATTEMPTS);

        if (retry_count >= MAX_RETRY_ATTEMPTS) {
            current_state = STATE_ERROR;
            statusLED.setPattern(LED_BLINK_FAST);
        } else {
            delay(5000);  // Wait before retry
        }
    }
}

void handleOperationalMode() {
    // Check WiFi connection
    if (!wifiMgr.isConnected()) {
        Serial.println("----------------------------------------");
        Serial.println("WiFi connection lost!");
        current_state = STATE_WIFI_CONNECTING;
        digitalWrite(ONAIR_PIN, LOW);
        onair_state = false;
        retry_count = 0;
        return;
    }

    // Check if token needs refresh
    if (twitchAPI.needsRefresh()) {
        Serial.println("----------------------------------------");
        Serial.println("Token expiring soon, refreshing...");
        current_state = STATE_TOKEN_ACQUIRING;
        retry_count = 0;
        return;
    }

    // Poll Twitch API
    unsigned long now = millis();
    if (now - last_poll_ms >= POLL_INTERVAL_MS) {
        last_poll_ms = now;

        Serial.println("----------------------------------------");
        Serial.print("Checking stream status [");
        Serial.print(now / 1000);
        Serial.println("s]...");
        statusLED.setPattern(LED_FLASH_QUICK);

        StreamStatus status;
        if (twitchAPI.checkStreamStatus(TWITCH_STREAMER_NAME, status)) {
            statusLED.setPattern(LED_ON);

            if (status.is_live != onair_state) {
                // Stream status changed
                onair_state = status.is_live;
                digitalWrite(ONAIR_PIN, onair_state ? HIGH : LOW);

                Serial.println();
                Serial.println("========================================");
                Serial.print("STREAM STATUS CHANGED: ");
                Serial.println(onair_state ? "LIVE" : "OFFLINE");
                Serial.println("========================================");

                if (onair_state) {
                    Serial.print("  Title: ");
                    Serial.println(status.stream_title);
                    Serial.print("  Game: ");
                    Serial.println(status.game_name);
                    Serial.print("  Viewers: ");
                    Serial.println(status.viewer_count);
                }
                Serial.println();
            } else {
                // Stream status unchanged
                Serial.print("Stream still ");
                Serial.println(onair_state ? "LIVE" : "OFFLINE");

                if (onair_state) {
                    Serial.print("  Viewers: ");
                    Serial.println(status.viewer_count);
                }
            }

            retry_count = 0;
        } else {
            statusLED.setPattern(LED_BLINK_FAST);
            Serial.print("API call failed: ");
            Serial.println(twitchAPI.getLastError());

            retry_count++;
            Serial.print("Consecutive failures: ");
            Serial.print(retry_count);
            Serial.print("/");
            Serial.println(MAX_RETRY_ATTEMPTS);

            if (retry_count >= MAX_RETRY_ATTEMPTS) {
                current_state = STATE_ERROR;
            }
        }
    }
}

void handleErrorState() {
    Serial.println("========================================");
    Serial.println("SYSTEM IN ERROR STATE");
    Serial.println("Restarting in 30 seconds...");
    Serial.println("========================================");

    statusLED.setPattern(LED_BLINK_FAST);

    for (int i = 30; i > 0; i--) {
        Serial.print(i);
        Serial.println(" seconds remaining...");
        delay(1000);
        statusLED.update();
    }

    Serial.println("Restarting NOW!");
    ESP.restart();
}
