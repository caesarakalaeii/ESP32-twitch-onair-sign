#include "led_controller.h"
#include "config.h"

LEDController::LEDController(uint8_t pin)
    : led_pin(pin), current_pattern(LED_OFF), last_toggle_ms(0), led_state(false), blink_interval_ms(0) {
}

void LEDController::begin() {
    pinMode(led_pin, OUTPUT);
    digitalWrite(led_pin, LOW);
}

void LEDController::updateBlinkInterval() {
    switch (current_pattern) {
        case LED_BLINK_SLOW:
            blink_interval_ms = LED_BLINK_CONNECTING;
            break;
        case LED_BLINK_FAST:
            blink_interval_ms = LED_BLINK_ERROR;
            break;
        case LED_FLASH_QUICK:
            blink_interval_ms = LED_BLINK_API_CALL;
            break;
        default:
            blink_interval_ms = 0;
            break;
    }
}

void LEDController::setPattern(LEDPattern pattern) {
    current_pattern = pattern;
    updateBlinkInterval();

    // Set immediate state for static patterns
    if (pattern == LED_OFF) {
        digitalWrite(led_pin, LOW);
        led_state = false;
    } else if (pattern == LED_ON) {
        digitalWrite(led_pin, HIGH);
        led_state = true;
    } else {
        // For blinking patterns, reset timer
        last_toggle_ms = millis();
    }
}

void LEDController::update() {
    // Skip if not a blinking pattern
    if (current_pattern == LED_OFF || current_pattern == LED_ON) {
        return;
    }

    unsigned long now = millis();
    if (now - last_toggle_ms >= blink_interval_ms) {
        led_state = !led_state;
        digitalWrite(led_pin, led_state ? HIGH : LOW);
        last_toggle_ms = now;
    }
}

void LEDController::setCustom(bool state) {
    current_pattern = state ? LED_ON : LED_OFF;
    led_state = state;
    digitalWrite(led_pin, state ? HIGH : LOW);
}
