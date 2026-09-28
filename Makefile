CC = clang
CFLAGS = -std=c11 -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations
ARCH_FLAGS = -arch arm64
SETUP_BIN = build/QL-580N\ macOS\ Driver\ Setup.app/Contents/MacOS/QL580NSetup

.PHONY: all clean test setup package check-ppd
all: build/rastertoql580n setup

build/rastertoql580n: src/rastertoql580n.c src/ql_status.c src/ql_status.h
	mkdir -p build
	$(CC) $(CFLAGS) $(ARCH_FLAGS) src/rastertoql580n.c src/ql_status.c -o $@ -lcups
	codesign --force --sign - $@

setup: $(SETUP_BIN)

$(SETUP_BIN): installer/App.swift installer/PrinterDiscovery.swift scripts/build_setup.sh \
		scripts/install.sh scripts/uninstall.sh ppd/Brother-QL-580N-Native.ppd assets/ql580n-native.icns VERSION \
		LICENSE build/rastertoql580n
	scripts/build_setup.sh

package: setup check-ppd
	scripts/package.sh
	python3 scripts/check_release.py --archives

check-ppd:
	python3 scripts/check_release.py --ppd

build/test-label-62x50.pdf: tests/make_test_label.py
	python3 tests/make_test_label.py

test: check-ppd build/rastertoql580n build/test-label-62x50.pdf
	python3 -m unittest discover -s tests -v

clean:
	rm -f build/rastertoql580n
	rm -rf 'build/QL-580N macOS Driver Setup.app' 'build/Brother QL-580N Setup.app'
