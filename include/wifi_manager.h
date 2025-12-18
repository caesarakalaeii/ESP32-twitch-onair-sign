#ifndef WIFI_MANAGER_H
#define WIFI_MANAGER_H

#include <Arduino.h>
#include <WiFi.h>

enum WiFiStatus {
    WIFI_DISCONNECTED,
    WIFI_CONNECTING,
    WIFI_CONNECTED,
    WIFI_ERROR
};

class WiFiManager {
public:
    WiFiManager();
    WiFiStatus connect(const char* ssid, const char* password, uint32_t timeout_ms);
    bool isConnected();
    bool reconnect();
    void disconnect();
    int getSignalStrength();
    const char* getLocalIP();

private:
    unsigned long connection_start_time;
    String local_ip;
    const char* ssid;
    const char* password;
};

#endif
