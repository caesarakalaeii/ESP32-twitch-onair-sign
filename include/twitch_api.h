#ifndef TWITCH_API_H
#define TWITCH_API_H

#include <Arduino.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>

struct TwitchToken {
    String access_token;
    String token_type;
    unsigned long expires_at_ms;  // Absolute time when token expires
};

struct StreamStatus {
    bool is_live;
    String stream_title;
    String game_name;
    int viewer_count;
};

class TwitchAPI {
public:
    TwitchAPI(const char* client_id, const char* client_secret);

    // Token Management
    bool acquireToken();
    bool isTokenValid();
    bool needsRefresh();

    // Stream Status
    bool checkStreamStatus(const char* streamer_name, StreamStatus& status);

    // Error Information
    const char* getLastError();

private:
    const char* client_id;
    const char* client_secret;
    TwitchToken token;
    String last_error;

    WiFiClientSecure wifi_client;

    bool makeTokenRequest();
    bool makeStreamRequest(const char* streamer_name, StreamStatus& status);
};

#endif
