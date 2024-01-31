ifeq ($(ISA), native)
build/native.so: src/native.cpp
	mkdir -p build/
	g++ $(shell sdl2-config --cflags) -std=c++11 -O1 -fPIC -shared -o build/native.so src/native.cpp -ldl $(shell sdl2-config --cflags)

else
NAME = libos
SRCS = src/syscall.c src/crt0/crt0.c src/crt0/start.S
include $(NAVY_HOME)/Makefile
endif
