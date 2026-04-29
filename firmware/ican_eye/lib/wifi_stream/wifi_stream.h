#ifndef WIFI_STREAM_H
#define WIFI_STREAM_H

#include <Arduino.h>

void initWifiStream();
bool isWifiConnected();
void sendFrame(uint8_t* fb, size_t len);

#endif
