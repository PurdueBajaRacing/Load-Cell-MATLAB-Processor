#include "HX711.h"
#include <Arduino.h>

/**
Essentially the simplest possible code for interfacing with an HX711.
Use the hx711_gui.m for interfacing with this (or don't, serial monitor works too)
*/

HX711 scale;

//  adjust pins if needed
uint8_t dataPin = 20;
uint8_t clockPin = 21;

void setup() {
  Serial.begin(115200);
  scale.begin(dataPin, clockPin);

  //  reset the scale to zero = 0
  scale.tare(160);
}

void loop() {
  if (scale.is_ready()) {
    float value = scale.get_value(1);
    Serial.println(value);
  }
}