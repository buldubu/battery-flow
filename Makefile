.PHONY: build test check app install run clean

build:
	swift build

test:
	./Scripts/test.sh

check:
	python3 Scripts/check-repository.py

app:
	./Scripts/package-app.sh

install:
	./Scripts/install-app.sh

run: install

clean:
	swift package clean
	rm -rf build/BatteryFlow.app
