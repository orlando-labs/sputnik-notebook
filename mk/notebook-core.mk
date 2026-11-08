# Platform-independent execution/document API. No Swift, AppKit, HTTP or CLI.
NOTEBOOK_CORE_DIR := packages/notebook-core
NOTEBOOK_CORE_INCLUDE := $(NOTEBOOK_CORE_DIR)/include
CPPFLAGS += -I. -I$(NOTEBOOK_CORE_INCLUDE)
NOTEBOOK_CORE_PLATFORM_FLAGS :=
ifeq ($(UNAME_S),Darwin)
NOTEBOOK_CORE_PLATFORM_FLAGS := -mmacosx-version-min=14.0
endif
APP_SESSION_SRCS := $(addprefix $(SPUTNIK_DIR)/,$(ISPUTNIK_SESSION_SRCS))
NOTEBOOK_WORKER_TRANSPORT := $(addprefix $(NOTEBOOK_CORE_DIR)/native/,protocol.cpp process.cpp presentation.cpp)
NOTEBOOK_CORE_SRCS := $(addprefix $(NOTEBOOK_CORE_DIR)/native/,notebook.cpp execution.cpp worker.cpp) $(NOTEBOOK_WORKER_TRANSPORT)
NOTEBOOK_CORE_OBJS := $(patsubst %.cpp,$(BUILD_DIR)/core/obj/%.o,$(NOTEBOOK_CORE_SRCS)) $(patsubst $(SPUTNIK_DIR)/%.cpp,$(BUILD_DIR)/core/obj/sputnik/%.o,$(APP_SESSION_SRCS))
NOTEBOOK_CORE_LIBRARY := $(BUILD_DIR)/core/libNotebookCore.a
$(BUILD_DIR)/core/obj/sputnik/tools/isputnik/essentials.o: CPPFLAGS += '-DSPUTNIK_NOTEBOOK_ESSENTIALS_DIR="$(abspath $(SPUTNIK_DIR)/packages/notebook_ui)"'
NOTEBOOK_CORE_HEADERS := $(wildcard $(NOTEBOOK_CORE_INCLUDE)/notebook/core/*.h) $(wildcard $(NOTEBOOK_CORE_INCLUDE)/notebook/core/worker/*.h)
SPUTNIK_PLOT_DIR ?= ../plot
ifneq ($(wildcard $(SPUTNIK_PLOT_DIR)/native/plot_png.c),)
NOTEBOOK_CORE_OBJS += $(BUILD_DIR)/core/plot_png.o
$(BUILD_DIR)/core/obj/sputnik/notebook/renderers.o: CPPFLAGS += -DSPUTNIK_NOTEBOOK_PLOT
endif

$(BUILD_DIR)/core/obj/%.o: %.cpp
	@mkdir -p "$(@D)"
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(NOTEBOOK_CORE_PLATFORM_FLAGS) -MMD -MP -c $< -o $@
$(BUILD_DIR)/core/obj/sputnik/%.o: $(SPUTNIK_DIR)/%.cpp
	@mkdir -p "$(@D)"
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(NOTEBOOK_CORE_PLATFORM_FLAGS) -MMD -MP -c $< -o $@
$(BUILD_DIR)/core/plot_png.o: $(SPUTNIK_PLOT_DIR)/native/plot_png.c $(SPUTNIK_DIR)/runtime/sputnik_ext.h
	@mkdir -p "$(@D)"
	$(CC) -I$(SPUTNIK_DIR) -std=c11 -O2 $(NOTEBOOK_CORE_PLATFORM_FLAGS) -MMD -MP -c $< -o $@
$(NOTEBOOK_CORE_LIBRARY): $(NOTEBOOK_CORE_OBJS) $(SPUTNIK_LIBRARY)
	$(AR) rcs $@ $(NOTEBOOK_CORE_OBJS)
$(NOTEBOOK_CORE_OBJS): mk/notebook-core.mk | runtime
-include $(NOTEBOOK_CORE_OBJS:.o=.d)

.PHONY: notebook-core
notebook-core: $(NOTEBOOK_CORE_LIBRARY)
