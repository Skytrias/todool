OS=$(shell uname)

ifeq ($(OS), Darwin)
all: darwin
else
all: unix
endif

unix:
	$(CC) -c -O2 -Os -fPIC main.c
	$(AR) rcs main.a main.o
	rm *.o

darwin:
	$(CC) -arch x86_64 -c -O2 -Os -fPIC main.c -o main-x86_64.o -mmacosx-version-min=10.12
	$(CC) -arch arm64  -c -O2 -Os -fPIC main.c -o main-arm64.o -mmacosx-version-min=10.12
	lipo -create main-x86_64.o main-arm64.o -output main.a
	rm *.o
