#ifndef LED_CONTROLLER_H
#define LED_CONTROLLER_H

#include <Arduino.h>

enum LEDPattern {
    LED_OFF,
    LED_ON,
    LED_BLINK_SLOW,
    LED_BLINK_FAST,
    LED_FLASH_QUICK
};

class LEDController {
public:
    LEDController(uint8_t pin);
    void begin();
    void setPattern(LEDPattern pattern);
    void update();  // Call in loop() to handle blinking
    void setCustom(bool state);

private:
    uint8_t led_pin;
    LEDPattern current_pattern;
    unsigned long last_toggle_ms;
    bool led_state;
    uint16_t blink_interval_ms;

    void updateBlinkInterval();
};

#endif
