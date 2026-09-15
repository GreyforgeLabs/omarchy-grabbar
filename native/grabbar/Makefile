# Grabbar native backend — builds against the installed Hyprland headers.
# The result is only valid for the exact Hyprland build whose headers were
# used; PLUGIN_INIT refuses to load into any other build.

ifeq ($(CXX),g++)
    EXTRA_FLAGS = --no-gnu-unique
else
    EXTRA_FLAGS =
endif

CXXFLAGS ?= -O2
CXXFLAGS += -shared -fPIC -std=c++2b -Wno-c++11-narrowing -Wall -Wno-unused-parameter
INCLUDES = `pkg-config --cflags pixman-1 libdrm hyprland libinput libudev wayland-server xkbcommon`
LIBS =

SRC = main.cpp backend.cpp bar.cpp pass.cpp
TARGET = grabbar.so

all: $(TARGET)

$(TARGET): $(SRC) globals.hpp backend.hpp bar.hpp pass.hpp
	$(CXX) $(CXXFLAGS) $(LDFLAGS) $(EXTRA_FLAGS) $(INCLUDES) $(SRC) -o $@ $(LIBS)

clean:
	rm -f ./$(TARGET)

.PHONY: all clean
