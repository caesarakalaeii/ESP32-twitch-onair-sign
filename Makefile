.PHONY: help upload monitor clean build check-secrets flash update-deps setup check-port

# Use venv's PlatformIO if it exists, otherwise fall back to system
PIO := $(shell [ -f .venv/bin/pio ] && echo ".venv/bin/pio" || echo "pio")

help:
	@echo "ESP32 Twitch On-Air Sign - Makefile Commands"
	@echo "=============================================="
	@echo ""
	@echo "  make setup        - Setup Python venv and install PlatformIO"
	@echo "  make check-port   - Check serial port permissions"
	@echo "  make upload       - Build and upload to ESP32"
	@echo "  make monitor      - Open serial monitor"
	@echo "  make build        - Build without uploading"
	@echo "  make clean        - Clean build files"
	@echo "  make check-secrets - Verify secrets.h exists"
	@echo "  make flash        - Upload and monitor (combined)"
	@echo ""

setup:
	@bash setup-venv.sh

check-port:
	@echo "Checking serial port permissions..."
	@if command -v pacman > /dev/null 2>&1; then \
		SERIAL_GROUP="uucp"; \
	else \
		SERIAL_GROUP="dialout"; \
	fi; \
	if groups | grep -q "$$SERIAL_GROUP"; then \
		echo "✓ User is in group '$$SERIAL_GROUP'"; \
	else \
		echo "✗ User is NOT in group '$$SERIAL_GROUP'"; \
		echo ""; \
		echo "Run: sudo usermod -a -G $$SERIAL_GROUP $$USER"; \
		echo "Then log out and log back in."; \
		exit 1; \
	fi; \
	if [ -c /dev/ttyUSB0 ]; then \
		if [ -r /dev/ttyUSB0 ] && [ -w /dev/ttyUSB0 ]; then \
			echo "✓ Can access /dev/ttyUSB0"; \
		else \
			echo "✗ Cannot access /dev/ttyUSB0 (permission denied)"; \
			echo ""; \
			echo "Run 'make setup' to fix permissions"; \
			exit 1; \
		fi; \
	else \
		echo "⚠ /dev/ttyUSB0 not found (ESP32 not connected?)"; \
	fi

check-secrets:
	@if [ ! -f include/secrets.h ]; then \
		echo "Error: include/secrets.h not found!"; \
		echo "Copy include/secrets.example.h to include/secrets.h"; \
		echo "and fill in your credentials."; \
		exit 1; \
	fi

build: check-secrets
	$(PIO) run

upload: check-secrets
	$(PIO) run --target upload

monitor:
	$(PIO) device monitor

clean:
	$(PIO) run --target clean

flash: upload monitor

update-deps:
	$(PIO) pkg update
