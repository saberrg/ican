#include "wifi_stream.h"
#include <WiFi.h>
#include <WiFiUdp.h>

const char* ssid = "LiveX_Hotspot";
const char* password = "LiveX1234";
const int udpPort = 8080;

WiFiUDP udp;

void initWifiStream() {
    WiFi.mode(WIFI_STA);
    WiFi.begin(ssid, password);
}

bool isWifiConnected() {
    return WiFi.status() == WL_CONNECTED;
}

void sendFrame(uint8_t* fb, size_t len) {
    if (!isWifiConnected()) return;
    
    IPAddress gateway = WiFi.gatewayIP();
    if (gateway == IPAddress(0, 0, 0, 0)) return;

    const size_t MAX_UDP_PAYLOAD = 1436;
    size_t offset = 0;
    while (offset < len) {
        size_t chunk = len - offset;
        if (chunk > MAX_UDP_PAYLOAD) {
            chunk = MAX_UDP_PAYLOAD;
        }
        udp.beginPacket(gateway, udpPort);
        udp.write(fb + offset, chunk);
        udp.endPacket();
        offset += chunk;
    }
}
