#!/bin/bash
# Setup Python virtual environment for PlatformIO

set -e

VENV_DIR=".venv"
CURRENT_USER=$(whoami)

echo "=========================================="
echo "ESP32 Development Environment Setup"
echo "=========================================="
echo ""

# Check if running on Arch-based system
if command -v pacman &> /dev/null; then
    SERIAL_GROUP="uucp"
else
    SERIAL_GROUP="dialout"
fi

# Setup Python venv
echo "[1/3] Setting up Python virtual environment..."
if [ -d "$VENV_DIR" ]; then
    echo "  ✓ Virtual environment already exists at $VENV_DIR"
else
    python -m venv "$VENV_DIR"
    echo "  ✓ Created virtual environment at $VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

echo "  Installing PlatformIO..."
pip install --upgrade pip -q
pip install platformio -q

echo "  ✓ PlatformIO installed"
echo ""

# Check and setup serial port permissions
echo "[2/3] Checking serial port permissions..."
if groups $CURRENT_USER | grep -q "\b$SERIAL_GROUP\b"; then
    echo "  ✓ User '$CURRENT_USER' is already in group '$SERIAL_GROUP'"
else
    echo "  ! User '$CURRENT_USER' is NOT in group '$SERIAL_GROUP'"
    echo ""
    echo "  To upload to ESP32, you need to be in the '$SERIAL_GROUP' group."
    echo "  Run this command and then LOG OUT and LOG BACK IN:"
    echo ""
    echo "    sudo usermod -a -G $SERIAL_GROUP $CURRENT_USER"
    echo ""
    read -p "  Add user to group now? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo usermod -a -G $SERIAL_GROUP $CURRENT_USER
        echo "  ✓ Added user to group '$SERIAL_GROUP'"
        echo "  ⚠ You MUST log out and log back in for this to take effect!"
        echo "  ⚠ After logging back in, run 'make flash' to upload."
    fi
fi
echo ""

# Setup udev rules for ESP32 (optional but helpful)
echo "[3/3] Checking udev rules for ESP32..."
UDEV_RULE="/etc/udev/rules.d/99-esp32.rules"
if [ -f "$UDEV_RULE" ]; then
    echo "  ✓ ESP32 udev rules already exist"
else
    echo "  Creating udev rules for ESP32 devices..."
    echo "  This allows non-root access to ESP32 USB devices."
    echo ""
    read -p "  Create udev rules? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo tee "$UDEV_RULE" > /dev/null << EOF
# ESP32 USB Serial devices
# CP210x UART Bridge (common on ESP32 dev boards)
SUBSYSTEMS=="usb", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", MODE="0666", GROUP="$SERIAL_GROUP"
# CH340 Serial Converter (alternative USB-to-serial chip)
SUBSYSTEMS=="usb", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE="0666", GROUP="$SERIAL_GROUP"
# FTDI chips
SUBSYSTEMS=="usb", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", MODE="0666", GROUP="$SERIAL_GROUP"
EOF
        sudo udevadm control --reload-rules
        sudo udevadm trigger
        echo "  ✓ Udev rules created and reloaded"
    fi
fi
echo ""

echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Copy include/secrets.example.h to include/secrets.h"
echo "  2. Fill in your WiFi and Twitch credentials"
echo "  3. Connect your ESP32 via USB"
if ! groups $CURRENT_USER | grep -q "\b$SERIAL_GROUP\b"; then
    echo "  4. LOG OUT and LOG BACK IN (to apply group membership)"
    echo "  5. Run 'make flash' to build and upload"
else
    echo "  4. Run 'make flash' to build and upload"
fi
echo ""
