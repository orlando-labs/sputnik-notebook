.DEFAULT_GOAL := all
SPUTNIK_DIR ?= ../sputnik-lang
SPUTNIK_BUILD_DIR ?= $(SPUTNIK_DIR)/build
include $(SPUTNIK_DIR)/mk/config.mk
CPPFLAGS += -I$(SPUTNIK_DIR) '-DSPUTNIK_SOURCE_ROOT="$(abspath $(SPUTNIK_DIR))"'
SPUTNIK_LIBRARY := $(abspath $(SPUTNIK_BUILD_DIR)/libsputnik.a)
LDFLAGS := $(SPUTNIK_LIBRARY) $(LDFLAGS)
CORE_SRCS :=
RUNTIME_SRCS :=
PACKAGE_SRCS :=
.PHONY: all build runtime clean test
ifeq ($(UNAME_S),Darwin)
all: notebook-macos $(BUILD_DIR)/isputnik
else
all: $(BUILD_DIR)/isputnik $(BUILD_DIR)/sputnik-notebook-worker
endif
build: all
runtime:
	$(MAKE) -C $(SPUTNIK_DIR) BUILD_DIR=$(abspath $(SPUTNIK_BUILD_DIR)) runtime
$(SPUTNIK_LIBRARY): runtime
	@test -f "$@"
$(BUILD_DIR)/.dir:
	@mkdir -p $(BUILD_DIR)
	@touch $@
NOTEBOOK_GRAPH_SRCS := notebook/model.cpp notebook/analysis.cpp notebook/dependency_graph.cpp notebook/scheduler.cpp
NOTEBOOK_SRCS := $(NOTEBOOK_GRAPH_SRCS) notebook/slot_table.cpp notebook/kernel.cpp notebook/vm_cell_executor.cpp notebook/compiler.cpp notebook/renderers.cpp
NOTEBOOK_PROJECT_SRCS := notebook/project.cpp notebook/project_json.cpp
NOTEBOOK_PROJECT_TEST_SRCS := tests/notebook_project_tests.cpp notebook/model.cpp $(NOTEBOOK_PROJECT_SRCS)
NOTEBOOK_SLOT_TEST_SRCS := tests/notebook_slot_tests.cpp notebook/slot_table.cpp notebook/model.cpp $(CORE_SRCS) $(RUNTIME_SRCS)
ISPUTNIK_ENVIRONMENT_SRCS := tools/isputnik/environment.cpp tools/isputnik/dependencies.cpp
ISPUTNIK_SRCS := tools/isputnik/main.cpp tools/isputnik/session.cpp tools/isputnik/project_session.cpp tools/isputnik/tabs.cpp $(ISPUTNIK_ENVIRONMENT_SRCS) tools/isputnik/activity.cpp tools/isputnik/dispatch.cpp tools/isputnik/terminal_wait.cpp $(NOTEBOOK_PROJECT_SRCS) $(NOTEBOOK_SRCS) $(CORE_SRCS) $(RUNTIME_SRCS) $(PACKAGE_SRCS)
ISPUTNIK_LDLIBS ?= -lncurses
ISPUTNIK_TEST_SRCS := tests/isputnik_tests.cpp tools/isputnik/session.cpp tools/isputnik/project_session.cpp $(ISPUTNIK_ENVIRONMENT_SRCS) tools/isputnik/activity.cpp $(NOTEBOOK_PROJECT_SRCS) $(NOTEBOOK_SRCS) $(CORE_SRCS) $(RUNTIME_SRCS) $(PACKAGE_SRCS)
ISPUTNIK_PROJECT_TEST_SRCS := tests/isputnik_project_tests.cpp $(filter-out tests/isputnik_tests.cpp,$(ISPUTNIK_TEST_SRCS))
ISPUTNIK_TABS_TEST_SRCS := tests/isputnik_tabs_tests.cpp tools/isputnik/tabs.cpp tools/isputnik/dispatch.cpp $(filter-out tests/isputnik_tests.cpp,$(ISPUTNIK_TEST_SRCS))
NOTEBOOK_DEPENDENCY_TEST_SRCS := tests/notebook_dependency_tests.cpp $(filter-out tests/isputnik_tabs_tests.cpp,$(ISPUTNIK_TABS_TEST_SRCS))
ISPUTNIK_ACTIVITY_TEST_SRCS := tests/isputnik_activity_tests.cpp tools/isputnik/activity.cpp
ISPUTNIK_POLL_TEST_SRCS := tests/isputnik_poll_tests.cpp tools/isputnik/activity.cpp
ISPUTNIK_DISPATCH_TEST_SRCS := tests/isputnik_dispatch_tests.cpp tools/isputnik/dispatch.cpp
ISPUTNIK_TERMINAL_WAIT_TEST_SRCS := tests/isputnik_terminal_wait_tests.cpp tools/isputnik/terminal_wait.cpp
MAC_NOTEBOOK_SRCS := tools/notebook-macos/NotebookBridge.cpp tools/notebook-macos/NotebookExecution.cpp tools/notebook-worker/protocol.cpp tools/notebook-worker/process.cpp tools/notebook-worker/presentation.cpp $(filter-out tools/isputnik/main.cpp tools/isputnik/terminal_wait.cpp,$(ISPUTNIK_SRCS))
MAC_NOTEBOOK_OBJS := $(patsubst %.cpp,$(BUILD_DIR)/notebook-macos/obj/%.o,$(MAC_NOTEBOOK_SRCS))
SPUTNIK_PLOT_DIR ?= ../sputnik-plot
ifneq ($(wildcard $(SPUTNIK_PLOT_DIR)/native/plot_png.c),)
MAC_NOTEBOOK_OBJS += $(BUILD_DIR)/notebook-macos/plot_png.o
$(BUILD_DIR)/notebook-macos/obj/notebook/renderers.o: CPPFLAGS += -DSPUTNIK_NOTEBOOK_PLOT
endif
MAC_NOTEBOOK_SWIFT := $(wildcard tools/notebook-macos/*.swift)
MAC_NOTEBOOK_TARGET ?= $(shell uname -m)-apple-macosx14.0
NOTEBOOK_WORKER_TRANSPORT := tools/notebook-worker/protocol.cpp tools/notebook-worker/process.cpp tools/notebook-worker/presentation.cpp
NOTEBOOK_WORKER_HEADERS := tools/notebook-worker/protocol.h tools/notebook-worker/process.h tools/notebook-worker/presentation.h $(SPUTNIK_DIR)/runtime/context.h tools/isputnik/session.h tools/isputnik/project_session.h
ifeq ($(UNAME_S),Darwin)
NOTEBOOK_WORKER_BACKEND := $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
ifneq ($(wildcard $(SPUTNIK_PLOT_DIR)/native/plot_png.c),)
NOTEBOOK_WORKER_PLOT_TEST := "$(abspath $(SPUTNIK_PLOT_DIR)/src/plot.s)"
endif
else
NOTEBOOK_WORKER_BACKEND := $(filter-out tools/isputnik/main.cpp tools/isputnik/terminal_wait.cpp,$(ISPUTNIK_SRCS))
endif

$(BUILD_DIR)/sputnik-notebook-worker: tools/notebook-worker/main.cpp tools/notebook-worker/protocol.cpp tools/notebook-worker/presentation.cpp $(NOTEBOOK_WORKER_BACKEND) $(NOTEBOOK_WORKER_HEADERS)
	@mkdir -p "$(@D)"
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(filter-out $(SPUTNIK_LIBRARY),$(filter %.cpp %.a,$^)) $(LDFLAGS) $(SPUTNIK_DYNAMIC_EXPORT_FLAGS) $(SPUTNIK_DYNAMIC_LOADER_LIBS) -o $@

$(BUILD_DIR)/notebook_worker_tests: tests/notebook_worker_tests.cpp $(NOTEBOOK_WORKER_TRANSPORT) $(NOTEBOOK_WORKER_BACKEND) $(NOTEBOOK_WORKER_HEADERS) | $(BUILD_DIR)/sputnik-notebook-worker
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(filter-out $(SPUTNIK_LIBRARY),$(filter %.cpp %.a,$^)) $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook-mnist: tools/notebook-mnist/main.cpp $(NOTEBOOK_WORKER_BACKEND) $(NOTEBOOK_WORKER_HEADERS)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(filter-out $(SPUTNIK_LIBRARY),$(filter %.cpp %.a,$^)) $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook_progress_tests: tests/notebook_progress_tests.cpp $(NOTEBOOK_WORKER_BACKEND) $(NOTEBOOK_WORKER_HEADERS)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(filter-out $(SPUTNIK_LIBRARY),$(filter %.cpp %.a,$^)) $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook_live_tests: tests/notebook_live_tests.cpp $(SPUTNIK_DIR)/runtime/notebook_live.h $(SPUTNIK_DIR)/runtime/notebook_display.h | $(BUILD_DIR)/.dir
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $< $(LDFLAGS) -o $@

.PHONY: test-notebook-progress
test-notebook-progress: $(BUILD_DIR)/notebook_progress_tests $(BUILD_DIR)/notebook_live_tests
	$(BUILD_DIR)/notebook_progress_tests
	$(BUILD_DIR)/notebook_live_tests

$(BUILD_DIR)/notebook_cancellation_tests: tests/notebook_cancellation_tests.cpp $(NOTEBOOK_WORKER_BACKEND) $(NOTEBOOK_WORKER_HEADERS)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(filter-out $(SPUTNIK_LIBRARY),$(filter %.cpp %.a,$^)) $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook_run_tasks_tests: tests/notebook_run_tasks_tests.cpp $(NOTEBOOK_WORKER_BACKEND) $(NOTEBOOK_WORKER_HEADERS) $(SPUTNIK_DIR)/runtime/system_native_task.inc
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(filter-out $(SPUTNIK_LIBRARY),$(filter %.cpp %.a,$^)) $(LDFLAGS) -o $@

.PHONY: test-notebook-worker
test-notebook-worker: $(BUILD_DIR)/notebook_worker_tests $(BUILD_DIR)/notebook_cancellation_tests $(BUILD_DIR)/notebook_run_tasks_tests
	$(BUILD_DIR)/notebook_worker_tests "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)" $(NOTEBOOK_WORKER_PLOT_TEST)
	$(BUILD_DIR)/notebook_cancellation_tests
	$(BUILD_DIR)/notebook_run_tasks_tests
ifeq ($(UNAME_S),Darwin)
test-notebook-worker: test-notebook-worker-host
.PHONY: test-notebook-worker-host
test-notebook-worker-host: $(BUILD_DIR)/notebook-macos/notebook_worker_host_tests $(BUILD_DIR)/sputnik-notebook-worker
	$(BUILD_DIR)/notebook-macos/notebook_worker_host_tests "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)"
.PHONY: test-notebook-worker-ui
test-notebook-worker-ui: notebook-macos $(BUILD_DIR)/notebook_macos_model_tests
	$(BUILD_DIR)/notebook_macos_model_tests "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)"
	python3 tests/notebook_macos_ui_smoke.py "$(BUILD_DIR)/Sputnik Notebook.app/Contents/MacOS/SputnikNotebook" --isolated-worker
ifneq ($(wildcard $(SPUTNIK_PLOT_DIR)/native/plot_png.c),)
	python3 tests/notebook_macos_plot_ui_smoke.py "$(BUILD_DIR)/Sputnik Notebook.app/Contents/MacOS/SputnikNotebook" "$(SPUTNIK_PLOT_DIR)/src/plot.s" --isolated-worker
endif
endif
NOTEBOOK_CORE_TEST_SRCS := tests/notebook_core_tests.cpp $(NOTEBOOK_GRAPH_SRCS) $(CORE_SRCS) $(RUNTIME_SRCS)
NOTEBOOK_COMPILER_TEST_SRCS := tests/notebook_compiler_tests.cpp $(NOTEBOOK_GRAPH_SRCS) notebook/compiler.cpp $(CORE_SRCS) $(RUNTIME_SRCS)
NOTEBOOK_KERNEL_TEST_SRCS := tests/notebook_kernel_tests.cpp $(NOTEBOOK_SRCS) $(CORE_SRCS) $(RUNTIME_SRCS)
NOTEBOOK_VM_INTEGRATION_TEST_SRCS := tests/notebook_vm_integration_tests.cpp $(NOTEBOOK_SRCS) $(CORE_SRCS) $(RUNTIME_SRCS)

# The native UI never adds Swift/AppKit dependencies to CLI or Linux builds. Its C++ backend shares exactly the isputnik Sessions, no curses.
.PHONY: notebook-macos test-notebook-macos
ifeq ($(UNAME_S),Darwin)
ifneq ($(wildcard $(SPUTNIK_PLOT_DIR)/native/plot_png.c),)
.PHONY: test-notebook-plots
test-notebook-macos: test-notebook-plots
test-notebook-plots: notebook-macos $(BUILD_DIR)/notebook_plot_tests $(BUILD_DIR)/notebook_macos_plot_tests
	$(BUILD_DIR)/notebook_plot_tests "$(SPUTNIK_PLOT_DIR)/src/plot.s" "$(BUILD_DIR)/notebook-plot-view-snapshot.json"
	$(BUILD_DIR)/notebook_macos_plot_tests "$(BUILD_DIR)/notebook-plot-view-snapshot.json"
	python3 tests/notebook_macos_plot_ui_smoke.py "$(BUILD_DIR)/Sputnik Notebook.app/Contents/MacOS/SputnikNotebook" "$(SPUTNIK_PLOT_DIR)/src/plot.s"
endif
$(BUILD_DIR)/notebook-macos/obj/%.o: %.cpp
	@mkdir -p "$(@D)"
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -mmacosx-version-min=14.0 -MMD -MP -c $< -o $@

-include $(MAC_NOTEBOOK_OBJS:.o=.d)

$(BUILD_DIR)/notebook-macos/plot_png.o: $(SPUTNIK_PLOT_DIR)/native/plot_png.c $(SPUTNIK_DIR)/runtime/sputnik_ext.h
	@mkdir -p "$(@D)"
	$(CC) -I$(SPUTNIK_DIR) -std=c11 -O2 -mmacosx-version-min=14.0 -c $< -o $@

$(BUILD_DIR)/notebook-macos/libNotebookBackend.a: $(MAC_NOTEBOOK_OBJS)
	xcrun libtool -static -o $@ $^

$(BUILD_DIR)/notebook-macos/SputnikNotebook: $(MAC_NOTEBOOK_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h $(MAC_NOTEBOOK_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o $@

notebook-macos: $(BUILD_DIR)/notebook-macos/SputnikNotebook $(BUILD_DIR)/sputnik-notebook-worker tools/notebook-macos/Info.plist tools/notebook-macos/package-app.sh
	bash tools/notebook-macos/package-app.sh "$(BUILD_DIR)/notebook-macos/SputnikNotebook" "$(BUILD_DIR)/Sputnik Notebook.app" "$(OPENSSL_LIB_DIR)" "$(BUILD_DIR)/sputnik-notebook-worker"

$(BUILD_DIR)/notebook_macos_bridge_tests: tests/notebook_macos_bridge_tests.cpp $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $< tools/isputnik/terminal_wait.cpp $(BUILD_DIR)/notebook-macos/libNotebookBackend.a $(LDFLAGS) $(SPUTNIK_DYNAMIC_EXPORT_FLAGS) -o $@

$(BUILD_DIR)/notebook_plot_tests: tests/notebook_plot_tests.cpp $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $< tools/isputnik/terminal_wait.cpp $(BUILD_DIR)/notebook-macos/libNotebookBackend.a $(LDFLAGS) $(SPUTNIK_DYNAMIC_EXPORT_FLAGS) -o $@

$(BUILD_DIR)/notebook_macos_model_tests: tests/notebook_macos_model_tests.swift tools/notebook-macos/NotebookModel.swift tools/notebook-macos/NotebookBoard.swift tools/notebook-macos/NotebookTextVariable.swift tools/notebook-macos/NotebookFigure.swift tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h tests/notebook_macos_model_tests.swift tools/notebook-macos/NotebookModel.swift tools/notebook-macos/NotebookBoard.swift tools/notebook-macos/NotebookTextVariable.swift tools/notebook-macos/NotebookFigure.swift $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -lc++ $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook_macos_syntax_tests: tests/notebook_macos_syntax_tests.swift tools/notebook-macos/SputnikSyntax.swift tools/notebook-macos/CodeEditor.swift
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache $^ -framework AppKit -framework SwiftUI -o $@

$(BUILD_DIR)/notebook_macos_result_tests: tests/notebook_macos_result_tests.swift tools/notebook-macos/NotebookResultView.swift tools/notebook-macos/NotebookObjectMenu.swift
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache $^ -framework AppKit -framework SwiftUI -o $@

$(BUILD_DIR)/notebook_macos_plot_tests: tests/notebook_macos_plot_tests.swift tools/notebook-macos/NotebookPlotScene.swift tools/notebook-macos/NotebookPlotView.swift tools/notebook-macos/NotebookFigure.swift tools/notebook-macos/NotebookFigureView.swift tools/notebook-macos/NotebookObjectMenu.swift
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache $^ -framework AppKit -framework SwiftUI -o $@

test-notebook-results: $(BUILD_DIR)/notebook_macos_result_tests $(BUILD_DIR)/notebook-macos/notebook_result_tests
	$(BUILD_DIR)/notebook_macos_result_tests
	$(BUILD_DIR)/notebook-macos/notebook_result_tests

$(BUILD_DIR)/notebook_macos_richtext_tests: tests/notebook_macos_richtext_tests.swift tools/notebook-macos/RichTextEditor.swift tools/notebook-macos/RichTextStructure.swift tools/notebook-macos/RichTextEditing.swift tools/notebook-macos/RichTextInterpolation.swift tools/notebook-macos/NotebookTextVariable.swift
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache $^ -framework AppKit -framework SwiftUI -o $@

# Reuse the same backend archive for cross-host regressions instead of
# recompiling the VM separately for each Session/project test executable.
$(BUILD_DIR)/notebook-macos/%_tests: tests/%_tests.cpp $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $< tools/isputnik/terminal_wait.cpp $(BUILD_DIR)/notebook-macos/libNotebookBackend.a $(LDFLAGS) $(SPUTNIK_DYNAMIC_EXPORT_FLAGS) -o $@

test-notebook-macos: notebook-macos $(BUILD_DIR)/notebook_macos_bridge_tests $(BUILD_DIR)/notebook_macos_model_tests $(BUILD_DIR)/notebook_macos_syntax_tests $(BUILD_DIR)/notebook_macos_richtext_tests $(BUILD_DIR)/notebook-macos/isputnik_tests $(BUILD_DIR)/notebook-macos/isputnik_project_tests $(BUILD_DIR)/notebook-macos/isputnik_tabs_tests $(BUILD_DIR)/notebook_project_tests
	$(BUILD_DIR)/notebook_macos_bridge_tests
	$(BUILD_DIR)/notebook_macos_model_tests
	$(BUILD_DIR)/notebook_macos_syntax_tests
	$(BUILD_DIR)/notebook_macos_richtext_tests
	$(BUILD_DIR)/notebook_project_tests
	$(BUILD_DIR)/notebook-macos/isputnik_tests
	$(BUILD_DIR)/notebook-macos/isputnik_project_tests
	$(BUILD_DIR)/notebook-macos/isputnik_tabs_tests
	$(BUILD_DIR)/notebook-macos/notebook_board_tests
	$(BUILD_DIR)/notebook-macos/notebook_dependency_tests
	python3 tests/notebook_macos_ui_smoke.py "$(BUILD_DIR)/Sputnik Notebook.app/Contents/MacOS/SputnikNotebook"
test-notebook-macos: $(BUILD_DIR)/notebook-macos/notebook_board_tests
test-notebook-macos: $(BUILD_DIR)/notebook-macos/notebook_dependency_tests
test-notebook-macos: test-notebook-results
else
notebook-macos test-notebook-macos:
	@echo "The native notebook requires macOS 14+ and Xcode Command Line Tools."
	@exit 1
endif

$(BUILD_DIR)/isputnik: $(ISPUTNIK_SRCS) tools/isputnik/session.h tools/isputnik/project_session.h tools/isputnik/tabs.h notebook/project.h notebook/model.h tools/isputnik/activity.h tools/isputnik/dispatch.h tools/isputnik/terminal_wait.h | $(BUILD_DIR)/.dir
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(ISPUTNIK_SRCS) $(LDFLAGS) $(ISPUTNIK_LDLIBS) -o $@

$(BUILD_DIR)/isputnik_tests: $(ISPUTNIK_TEST_SRCS) tools/isputnik/session.h tools/isputnik/project_session.h notebook/project.h notebook/model.h tools/isputnik/activity.h | $(BUILD_DIR)/.dir
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(ISPUTNIK_TEST_SRCS) $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook_project_tests: $(NOTEBOOK_PROJECT_TEST_SRCS) notebook/project.h notebook/model.h | $(BUILD_DIR)/.dir
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(NOTEBOOK_PROJECT_TEST_SRCS) $(LDFLAGS) -o $@

$(BUILD_DIR)/isputnik_project_tests: $(ISPUTNIK_PROJECT_TEST_SRCS) tools/isputnik/project_session.h tools/isputnik/session.h notebook/project.h notebook/model.h tools/isputnik/activity.h | $(BUILD_DIR)/.dir
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(ISPUTNIK_PROJECT_TEST_SRCS) $(LDFLAGS) -o $@

$(BUILD_DIR)/isputnik_tabs_tests: $(ISPUTNIK_TABS_TEST_SRCS) tools/isputnik/tabs.h tools/isputnik/project_session.h tools/isputnik/session.h notebook/project.h notebook/model.h tools/isputnik/activity.h tools/isputnik/dispatch.h | $(BUILD_DIR)/.dir
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(ISPUTNIK_TABS_TEST_SRCS) $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook_dependency_tests: $(NOTEBOOK_DEPENDENCY_TEST_SRCS) tools/isputnik/dependencies.h tools/isputnik/tabs.h tools/isputnik/project_session.h tools/isputnik/session.h notebook/project.h notebook/model.h $(SPUTNIK_DIR)/runtime/vm_notebook.inc $(SPUTNIK_DIR)/runtime/notebook_display.h $(SPUTNIK_DIR)/runtime/notebook_inputs.h | $(BUILD_DIR)/.dir
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(NOTEBOOK_DEPENDENCY_TEST_SRCS) $(LDFLAGS) -o $@

$(BUILD_DIR)/isputnik_activity_tests: $(ISPUTNIK_ACTIVITY_TEST_SRCS) tools/isputnik/activity.h | $(BUILD_DIR)/.dir
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(ISPUTNIK_ACTIVITY_TEST_SRCS) $(LDFLAGS) -o $@

$(BUILD_DIR)/isputnik_poll_tests: $(ISPUTNIK_POLL_TEST_SRCS) tools/isputnik/activity.h | $(BUILD_DIR)/.dir
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(ISPUTNIK_POLL_TEST_SRCS) $(LDFLAGS) -o $@

$(BUILD_DIR)/isputnik_dispatch_tests: $(ISPUTNIK_DISPATCH_TEST_SRCS) tools/isputnik/dispatch.h tools/isputnik/session.h | $(BUILD_DIR)/.dir
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(ISPUTNIK_DISPATCH_TEST_SRCS) $(LDFLAGS) -o $@

$(BUILD_DIR)/isputnik_terminal_wait_tests: $(ISPUTNIK_TERMINAL_WAIT_TEST_SRCS) tools/isputnik/terminal_wait.h | $(BUILD_DIR)/.dir
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(ISPUTNIK_TERMINAL_WAIT_TEST_SRCS) $(LDFLAGS) -o $@

# Separate from the headless test suite: requires POSIX PTY allocation.
test-isputnik-tui: $(BUILD_DIR)/isputnik
	python3 tests/isputnik_tui_smoke.py $(BUILD_DIR)/isputnik
	python3 tests/isputnik_project_tui_smoke.py $(BUILD_DIR)/isputnik
	python3 tests/isputnik_tabs_tui_smoke.py $(BUILD_DIR)/isputnik
	python3 tests/isputnik_project_commands_tui_smoke.py $(BUILD_DIR)/isputnik

$(BUILD_DIR)/notebook_core_tests: $(NOTEBOOK_CORE_TEST_SRCS) | $(BUILD_DIR)/.dir
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(NOTEBOOK_CORE_TEST_SRCS) $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook_compiler_tests: $(NOTEBOOK_COMPILER_TEST_SRCS) | $(BUILD_DIR)/.dir
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(NOTEBOOK_COMPILER_TEST_SRCS) $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook_slot_tests: $(NOTEBOOK_SLOT_TEST_SRCS) | $(BUILD_DIR)/.dir
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(NOTEBOOK_SLOT_TEST_SRCS) $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook_kernel_tests: $(NOTEBOOK_KERNEL_TEST_SRCS) | $(BUILD_DIR)/.dir
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(NOTEBOOK_KERNEL_TEST_SRCS) $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook_vm_integration_tests: $(NOTEBOOK_VM_INTEGRATION_TEST_SRCS) | $(BUILD_DIR)/.dir
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(NOTEBOOK_VM_INTEGRATION_TEST_SRCS) $(LDFLAGS) -o $@


# Check the runtime first, including when an existing archive needs rebuilding.
$(MAC_NOTEBOOK_OBJS) $(BUILD_DIR)/isputnik $(BUILD_DIR)/sputnik-notebook-worker: | runtime
$(BUILD_DIR)/notebook-macos/SputnikNotebook $(BUILD_DIR)/sputnik-notebook-worker $(BUILD_DIR)/isputnik: $(SPUTNIK_LIBRARY)
TEST_NAMES := $(notdir $(basename $(wildcard tests/*_tests.cpp)))
.PHONY: test-core
test: test-core
ifeq ($(UNAME_S),Darwin)
CORE_TEST_DIR := $(BUILD_DIR)/notebook-macos
CORE_TEST_NAMES := $(filter-out notebook_worker_tests notebook_worker_host_tests notebook_plot_tests,$(TEST_NAMES))
else
CORE_TEST_DIR := $(BUILD_DIR)/core
CORE_TEST_NAMES := $(filter-out notebook_worker_tests notebook_worker_host_tests notebook_plot_tests notebook_macos_bridge_tests notebook_board_tests,$(TEST_NAMES))
$(CORE_TEST_DIR)/%_tests: tests/%_tests.cpp $(filter-out tools/isputnik/main.cpp,$(ISPUTNIK_SRCS)) $(NOTEBOOK_WORKER_TRANSPORT)
	@mkdir -p "$(@D)"
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(filter %.cpp,$^) $(LDFLAGS) $(SPUTNIK_DYNAMIC_EXPORT_FLAGS) $(SPUTNIK_DYNAMIC_LOADER_LIBS) -o $@
endif
CORE_TEST_BINS := $(addprefix $(CORE_TEST_DIR)/,$(CORE_TEST_NAMES))
$(CORE_TEST_BINS): $(SPUTNIK_LIBRARY)
$(addprefix $(BUILD_DIR)/,$(TEST_NAMES)): $(SPUTNIK_LIBRARY)
test-core: $(CORE_TEST_BINS)
	@set -e; $(foreach name,$(CORE_TEST_NAMES),"$(CORE_TEST_DIR)/$(name)";)
clean:
	rm -rf $(BUILD_DIR)
