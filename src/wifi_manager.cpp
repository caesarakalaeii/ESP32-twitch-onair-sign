#include "wifi_manager.h"

WiFiManager::WiFiManager() : connection_start_time(0), ssid(nullptr), password(nullptr) {
    local_ip = "";
}

WiFiStatus WiFiManager::connect(const char* ssid, const char* password, uint32_t timeout_ms) {
    this->ssid = ssid;
    this->password = password;

    Serial.print("Connecting to WiFi SSID: ");
    Serial.println(ssid);

    WiFi.mode(WIFI_STA);
    WiFi.begin(ssid, password);

    connection_start_time = millis();

    while (WiFi.status() != WL_CONNECTED) {
        if (millis() - connection_start_time >= timeout_ms) {
            Serial.println("WiFi connection timeout!");
            return WIFI_ERROR;
        }
        delay(500);
        Serial.print(".");
    }

    Serial.println();
    local_ip = WiFi.localIP().toString();
    Serial.print("WiFi connected! IP address: ");
    Serial.println(local_ip);

    return WIFI_CONNECTED;
}

bool WiFiManager::isConnected() {
    return WiFi.status() == WL_CONNECTED;
}

bool WiFiManager::reconnect() {
    if (ssid == nullptr || password == nullptr) {
        return false;
    }

    Serial.println("Attempting WiFi reconnection...");
    WiFi.disconnect();
    delay(100);

    WiFiStatus status = connect(ssid, password, 20000);
    return (status == WIFI_CONNECTED);
}

void WiFiManager::disconnect() {
    WiFi.disconnect();
    Serial.println("WiFi disconnected");
}

int WiFiManager::getSignalStrength() {
    return WiFi.RSSI();
}

const char* WiFiManager::getLocalIP() {
    return local_ip.c_str();
}
