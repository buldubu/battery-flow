.PHONY: build test test-tools check hooks app install run clean

build:
	python3 Scripts/swift-tool.py build

test:
	./Scripts/test.sh

test-tools:
	python3 -m unittest discover -s Tests/RepositoryTools -p 'test_*.py'

check:
	python3 Scripts/check-repository.py

hooks:
	./Scripts/install-hooks.sh

app:
	./Scripts/package-app.sh

install:
	./Scripts/install-app.sh

run: install

clean:
	python3 Scripts/swift-tool.py package clean
	rm -rf build/BatteryFlow.app
