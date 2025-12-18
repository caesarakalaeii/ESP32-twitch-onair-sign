#include "twitch_api.h"
#include "config.h"

TwitchAPI::TwitchAPI(const char* client_id, const char* client_secret)
    : client_id(client_id), client_secret(client_secret) {
    token.access_token = "";
    token.token_type = "";
    token.expires_at_ms = 0;

    // Use insecure mode for simplicity (skip certificate verification)
    wifi_client.setInsecure();
}

bool TwitchAPI::acquireToken() {
    Serial.println("Acquiring OAuth token from Twitch...");
    return makeTokenRequest();
}

bool TwitchAPI::isTokenValid() {
    return token.access_token.length() > 0 && millis() < token.expires_at_ms;
}

bool TwitchAPI::needsRefresh() {
    if (!isTokenValid()) {
        return true;
    }
    unsigned long time_remaining_ms = token.expires_at_ms - millis();
    return time_remaining_ms < TOKEN_REFRESH_MARGIN_MS;
}

bool TwitchAPI::checkStreamStatus(const char* streamer_name, StreamStatus& status) {
    if (!isTokenValid()) {
        last_error = "Token is invalid";
        return false;
    }

    return makeStreamRequest(streamer_name, status);
}

const char* TwitchAPI::getLastError() {
    return last_error.c_str();
}

bool TwitchAPI::makeTokenRequest() {
    HTTPClient http;

    // Build POST body
    String post_data = "client_id=";
    post_data += client_id;
    post_data += "&client_secret=";
    post_data += client_secret;
    post_data += "&grant_type=client_credentials";

    http.begin(wifi_client, TWITCH_TOKEN_URL);
    http.addHeader("Content-Type", "application/x-www-form-urlencoded");
    http.setTimeout(HTTP_TIMEOUT_MS);

    int http_code = http.POST(post_data);

    if (http_code != 200) {
        last_error = "Token request failed with HTTP code: ";
        last_error += String(http_code);
        http.end();
        return false;
    }

    String payload = http.getString();
    http.end();

    // Parse JSON response
    JsonDocument doc;
    DeserializationError error = deserializeJson(doc, payload);

    if (error) {
        last_error = "JSON parse failed: ";
        last_error += error.c_str();
        return false;
    }

    // Extract token information
    token.access_token = doc["access_token"].as<String>();
    token.token_type = doc["token_type"].as<String>();
    int expires_in = doc["expires_in"].as<int>();

    // Calculate absolute expiry time
    token.expires_at_ms = millis() + ((unsigned long)expires_in * 1000UL);

    Serial.println("OAuth token acquired successfully");
    Serial.print("Token expires in: ");
    Serial.print(expires_in);
    Serial.println(" seconds");

    return true;
}

bool TwitchAPI::makeStreamRequest(const char* streamer_name, StreamStatus& status) {
    HTTPClient http;

    // Build URL with query parameter
    String url = TWITCH_STREAMS_URL;
    url += "?user_login=";
    url += streamer_name;

    http.begin(wifi_client, url);
    http.addHeader("Authorization", "Bearer " + token.access_token);
    http.addHeader("Client-Id", client_id);
    http.setTimeout(HTTP_TIMEOUT_MS);

    int http_code = http.GET();

    if (http_code == 401) {
        last_error = "Unauthorized - token may be invalid";
        http.end();
        return false;
    }

    if (http_code == 404) {
        last_error = "Streamer not found";
        http.end();
        return false;
    }

    if (http_code == 429) {
        last_error = "Rate limited by Twitch API";
        http.end();
        return false;
    }

    if (http_code != 200) {
        last_error = "Stream request failed with HTTP code: ";
        last_error += String(http_code);
        http.end();
        return false;
    }

    String payload = http.getString();
    http.end();

    // Parse JSON response
    JsonDocument doc;
    DeserializationError error = deserializeJson(doc, payload);

    if (error) {
        last_error = "JSON parse failed: ";
        last_error += error.c_str();
        return false;
    }

    // Check if data array is empty (streamer offline) or has elements (streamer live)
    JsonArray data = doc["data"].as<JsonArray>();

    if (data.size() == 0) {
        // Streamer is offline
        status.is_live = false;
        status.stream_title = "";
        status.game_name = "";
        status.viewer_count = 0;
    } else {
        // Streamer is live
        status.is_live = true;
        status.stream_title = data[0]["title"].as<String>();
        status.game_name = data[0]["game_name"].as<String>();
        status.viewer_count = data[0]["viewer_count"].as<int>();
    }

    return true;
}
