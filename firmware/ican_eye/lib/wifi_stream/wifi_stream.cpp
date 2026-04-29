#include <Arduino.h>
#include <WiFi.h>
#include <WiFiUdp.h>

#include "wifi_stream.h"

static String ssid = "";
static String password = "";
static const int udpPort = 8080;

static WiFiUDP udp;

void initWifiStream() {
    WiFi.mode(WIFI_STA);
}

bool isWifiConnected() {
    return WiFi.status() == WL_CONNECTED;
}

void setWifiCredentials(const String& newSsid, const String& newPassword) {
    ssid = newSsid;
    password = newPassword;
}

bool hasWifiCredentials() {
    return ssid.length() > 0;
}

void tryConnectWifi() {
    if (!hasWifiCredentials()) return;
    // Disconnect any prior session so WiFi.begin picks up new credentials.
    WiFi.disconnect(false, true);
    WiFi.begin(ssid.c_str(), password.c_str());
    Serial.printf("[WiFi] Connecting to '%s'...\n", ssid.c_str());
}

void sendFrame(uint8_t* fb, size_t len, uint16_t frameId) {
    IPAddress gateway = WiFi.gatewayIP();
    if (gateway == IPAddress(0, 0, 0, 0)) return;

    const size_t MAX_UDP_PAYLOAD = 1428;  // 1436 minus 8-byte header
    const uint16_t chunkCount =
        (uint16_t)((len + MAX_UDP_PAYLOAD - 1) / MAX_UDP_PAYLOAD);

    size_t offset = 0;
    uint16_t chunkIndex = 0;
    while (offset < len) {
        size_t remaining = len - offset;
        size_t payload = remaining > MAX_UDP_PAYLOAD ? MAX_UDP_PAYLOAD : remaining;

        uint8_t header[8];
        header[0] = (uint8_t)(frameId & 0xFF);
        header[1] = (uint8_t)((frameId >> 8) & 0xFF);
        header[2] = (uint8_t)(chunkIndex & 0xFF);
        header[3] = (uint8_t)((chunkIndex >> 8) & 0xFF);
        header[4] = (uint8_t)(chunkCount & 0xFF);
        header[5] = (uint8_t)((chunkCount >> 8) & 0xFF);
        header[6] = (uint8_t)(payload & 0xFF);
        header[7] = (uint8_t)((payload >> 8) & 0xFF);

        udp.beginPacket(gateway, udpPort);
        udp.write(header, sizeof(header));
        udp.write(fb + offset, payload);
        udp.endPacket();

        offset += payload;
        chunkIndex++;
    }
}
