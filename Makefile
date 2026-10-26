.DEFAULT_GOAL := all
SPUTNIK_DIR ?= ../sputnik-lang
SPUTNIK_BUILD_DIR ?= $(SPUTNIK_DIR)/build
include $(SPUTNIK_DIR)/mk/config.mk
include $(SPUTNIK_DIR)/mk/isputnik-sources.mk
CPPFLAGS += -I$(SPUTNIK_DIR) '-DSPUTNIK_SOURCE_ROOT="$(abspath $(SPUTNIK_DIR))"'
SPUTNIK_LIBRARY := $(abspath $(SPUTNIK_BUILD_DIR)/libsputnik.a)
# Match paths in the runtime's compiler-generated dependency files when sharing
# its normal in-repository build directory; absolute targets bypass relative .d
# targets and can silently miss changes to included runtime headers.
SPUTNIK_RUNTIME_BUILD_DIR := $(patsubst $(abspath $(SPUTNIK_DIR))/%,%,$(abspath $(SPUTNIK_BUILD_DIR)))
LDFLAGS := $(SPUTNIK_LIBRARY) $(LDFLAGS)
.PHONY: all build runtime clean test
ifeq ($(UNAME_S),Darwin)
all: notebook-macos
else
all: $(BUILD_DIR)/sputnik-notebook-worker
endif
build: all
runtime:
	$(MAKE) -C $(SPUTNIK_DIR) BUILD_DIR="$(SPUTNIK_RUNTIME_BUILD_DIR)" runtime
$(SPUTNIK_LIBRARY): runtime
	@test -f "$@"
$(BUILD_DIR)/.dir:
	@mkdir -p $(BUILD_DIR)
	@touch $@
# The console and reusable notebook engine belong to the language checkout.
# The GUI compiles the shared sources with its optional PNG presentation backend.
APP_SESSION_SRCS := $(addprefix $(SPUTNIK_DIR)/,$(ISPUTNIK_SESSION_SRCS))
MAC_NOTEBOOK_SRCS := tools/notebook-macos/NotebookBridge.cpp tools/notebook-macos/NotebookExecution.cpp tools/notebook-worker/protocol.cpp tools/notebook-worker/process.cpp tools/notebook-worker/presentation.cpp
MAC_NOTEBOOK_OBJS := $(patsubst %.cpp,$(BUILD_DIR)/notebook-macos/obj/%.o,$(MAC_NOTEBOOK_SRCS)) $(patsubst $(SPUTNIK_DIR)/%.cpp,$(BUILD_DIR)/notebook-macos/obj/sputnik/%.o,$(APP_SESSION_SRCS))
SPUTNIK_PLOT_DIR ?= ../plot
ifneq ($(wildcard $(SPUTNIK_PLOT_DIR)/native/plot_png.c),)
MAC_NOTEBOOK_OBJS += $(BUILD_DIR)/notebook-macos/plot_png.o
$(BUILD_DIR)/notebook-macos/obj/sputnik/notebook/renderers.o: CPPFLAGS += -DSPUTNIK_NOTEBOOK_PLOT
endif
MAC_NOTEBOOK_SWIFT := $(wildcard tools/notebook-macos/*.swift)
MAC_NOTEBOOK_ICON := tools/notebook-macos/Assets/AppIcon.icns
MAC_NOTEBOOK_TARGET ?= $(shell uname -m)-apple-macosx14.0
NOTEBOOK_WORKER_TRANSPORT := tools/notebook-worker/protocol.cpp tools/notebook-worker/process.cpp tools/notebook-worker/presentation.cpp
NOTEBOOK_WORKER_HEADERS := tools/notebook-worker/environment.h tools/notebook-worker/grants.h tools/notebook-worker/protocol.h tools/notebook-worker/process.h tools/notebook-worker/presentation.h $(SPUTNIK_DIR)/runtime/context.h $(SPUTNIK_DIR)/tools/isputnik/session.h $(SPUTNIK_DIR)/tools/isputnik/project_session.h
ifeq ($(UNAME_S),Darwin)
NOTEBOOK_WORKER_BACKEND := $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
ifneq ($(wildcard $(SPUTNIK_PLOT_DIR)/native/plot_png.c),)
NOTEBOOK_WORKER_PLOT_TEST := "$(abspath $(SPUTNIK_PLOT_DIR)/src/plot.s)"
endif
else
NOTEBOOK_WORKER_BACKEND := $(APP_SESSION_SRCS)
endif

$(BUILD_DIR)/sputnik-notebook-worker: tools/notebook-worker/main.cpp tools/notebook-worker/protocol.cpp tools/notebook-worker/presentation.cpp $(NOTEBOOK_WORKER_BACKEND) $(NOTEBOOK_WORKER_HEADERS) $(SPUTNIK_LIBRARY)
	@mkdir -p "$(@D)"
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(filter-out $(SPUTNIK_LIBRARY),$(filter %.cpp %.a,$^)) $(LDFLAGS) $(SPUTNIK_DYNAMIC_EXPORT_FLAGS) $(SPUTNIK_DYNAMIC_LOADER_LIBS) -pthread -o $@.tmp
	mv -f $@.tmp $@

$(BUILD_DIR)/notebook_worker_tests: tests/notebook_worker_tests.cpp $(NOTEBOOK_WORKER_TRANSPORT) $(NOTEBOOK_WORKER_BACKEND) $(NOTEBOOK_WORKER_HEADERS) | $(BUILD_DIR)/sputnik-notebook-worker
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(filter-out $(SPUTNIK_LIBRARY),$(filter %.cpp %.a,$^)) $(LDFLAGS) -o $@

SPUTNIK_REMOTE_COMPILER := $(abspath $(SPUTNIK_BUILD_DIR)/sputnik)
REMOTE_NATIVE_DIR := $(abspath $(BUILD_DIR)/remote-native)
REMOTE_NATIVE_CXX ?= $(CXX)
REMOTE_NATIVE_HEADERS := $(SPUTNIK_DIR)/runtime/remote_io_native.inc $(SPUTNIK_DIR)/runtime/net_http_client_native.inc
REMOTE_GRANTS := --grant time.now --grant fs.read --grant fs.write --grant fs.metadata --grant net.listen --grant net.connect --grant random.secure --grant process.spawn
$(SPUTNIK_REMOTE_COMPILER): runtime
	$(MAKE) -C $(SPUTNIK_DIR) BUILD_DIR="$(SPUTNIK_RUNTIME_BUILD_DIR)" "$(SPUTNIK_RUNTIME_BUILD_DIR)/sputnik"

$(BUILD_DIR)/sputnik-notebook-remote: Makefile $(wildcard tools/notebook-remote/*.s) tools/notebook-remote/host.cpp tools/notebook-remote/sputnik.build.json $(REMOTE_NATIVE_HEADERS) $(NOTEBOOK_WORKER_TRANSPORT) $(NOTEBOOK_WORKER_HEADERS) $(SPUTNIK_REMOTE_COMPILER)
	@mkdir -p "$(@D)"
	SPUTNIK_NATIVE_CXX="$(REMOTE_NATIVE_CXX)" "$(SPUTNIK_REMOTE_COMPILER)" build tools/notebook-remote/sputnik.build.json --target native --require-full-native --out-dir "$(REMOTE_NATIVE_DIR)" $(REMOTE_GRANTS)
	cp "$(REMOTE_NATIVE_DIR)/notebook.remote.main" "$@.tmp"
	mv -f "$@.tmp" "$@"

.PHONY: remote-core test-notebook-remote test-notebook-remote-command test-notebook-remote-fsync
remote-core: $(BUILD_DIR)/sputnik-notebook-worker $(BUILD_DIR)/sputnik-notebook-remote
test-notebook-remote-command: $(SPUTNIK_REMOTE_COMPILER)
	python3 tests/notebook_remote_command_test.py "$(SPUTNIK_REMOTE_COMPILER)"
test-notebook-remote: remote-core test-notebook-remote-command
	python3 tests/notebook_remote_tests.py --worker "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)" --core "$(abspath $(BUILD_DIR)/sputnik-notebook-remote)"

# Linux only: inject an actual fsync EIO into the native agent with strace.
test-notebook-remote-fsync: remote-core
	python3 tests/notebook_remote_fsync_fault_test.py --worker "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)" --core "$(abspath $(BUILD_DIR)/sputnik-notebook-remote)"

$(BUILD_DIR)/notebook-mnist: tools/notebook-mnist/main.cpp $(NOTEBOOK_WORKER_BACKEND) $(NOTEBOOK_WORKER_HEADERS)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(filter-out $(SPUTNIK_LIBRARY),$(filter %.cpp %.a,$^)) $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook-mnist-benchmark: tools/notebook-mnist/benchmark.cpp $(NOTEBOOK_WORKER_BACKEND) $(NOTEBOOK_WORKER_HEADERS)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(filter-out $(SPUTNIK_LIBRARY),$(filter %.cpp %.a,$^)) $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook_progress_tests: tests/notebook_progress_tests.cpp $(NOTEBOOK_WORKER_BACKEND) $(NOTEBOOK_WORKER_HEADERS)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(filter-out $(SPUTNIK_LIBRARY),$(filter %.cpp %.a,$^)) $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook_live_tests: tests/notebook_live_tests.cpp $(SPUTNIK_DIR)/runtime/notebook_live.h $(SPUTNIK_DIR)/runtime/notebook_display.h | $(BUILD_DIR)/.dir
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $< $(LDFLAGS) -o $@

.PHONY: test-notebook-progress
test-notebook-progress: $(BUILD_DIR)/notebook_progress_tests $(BUILD_DIR)/notebook_live_tests
	$(BUILD_DIR)/notebook_progress_tests
	$(BUILD_DIR)/notebook_live_tests

.PHONY: test-notebook-images
ifeq ($(UNAME_S),Darwin)
test-notebook-images: $(BUILD_DIR)/notebook-macos/notebook_image_tests $(BUILD_DIR)/sputnik-notebook-worker $(BUILD_DIR)/notebook_macos_image_tests
	$(BUILD_DIR)/notebook-macos/notebook_image_tests "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)" "$(abspath $(BUILD_DIR))/image-components"
	$(BUILD_DIR)/notebook_macos_image_tests --output "$(abspath $(BUILD_DIR))/image-components"
else
test-notebook-images: $(BUILD_DIR)/core/notebook_image_tests $(BUILD_DIR)/sputnik-notebook-worker
	$(BUILD_DIR)/core/notebook_image_tests "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)"
endif

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
	python3 tests/notebook_macos_ui_smoke.py "$(BUILD_DIR)/Sputnik Notebook.app/Contents/MacOS/SputnikNotebook"
	python3 tests/notebook_macos_ui_smoke.py "$(BUILD_DIR)/notebook-macos/SputnikNotebook"
ifneq ($(wildcard $(SPUTNIK_PLOT_DIR)/native/plot_png.c),)
	python3 tests/notebook_macos_plot_ui_smoke.py "$(BUILD_DIR)/Sputnik Notebook.app/Contents/MacOS/SputnikNotebook" "$(SPUTNIK_PLOT_DIR)/src/plot.s"
endif
endif
# The native UI never adds Swift/AppKit dependencies to CLI or Linux builds. Its C++ backend shares exactly the isputnik Sessions, no curses.
.PHONY: notebook-macos test-notebook-macos
ifeq ($(UNAME_S),Darwin)
ifneq ($(wildcard $(SPUTNIK_PLOT_DIR)/native/plot_png.c),)
.PHONY: test-notebook-plots
test-notebook-macos: test-notebook-plots
test-notebook-plots: notebook-macos $(BUILD_DIR)/notebook_plot_tests $(BUILD_DIR)/notebook_macos_plot_tests $(BUILD_DIR)/notebook_live_tests
	$(BUILD_DIR)/notebook_plot_tests "$(SPUTNIK_PLOT_DIR)/src/plot.s" "$(BUILD_DIR)/notebook-plot-view-snapshot.json"
	$(BUILD_DIR)/notebook_live_tests "$(BUILD_DIR)/chart-stream-scene.json"
	$(BUILD_DIR)/notebook_macos_plot_tests "$(BUILD_DIR)/notebook-plot-view-snapshot.json"
	python3 tests/notebook_macos_plot_ui_smoke.py "$(BUILD_DIR)/Sputnik Notebook.app/Contents/MacOS/SputnikNotebook" "$(SPUTNIK_PLOT_DIR)/src/plot.s"
endif
$(BUILD_DIR)/notebook-macos/obj/%.o: %.cpp
	@mkdir -p "$(@D)"
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -mmacosx-version-min=14.0 -MMD -MP -c $< -o $@

$(BUILD_DIR)/notebook-macos/obj/sputnik/%.o: $(SPUTNIK_DIR)/%.cpp
	@mkdir -p "$(@D)"
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -mmacosx-version-min=14.0 -MMD -MP -c $< -o $@

-include $(MAC_NOTEBOOK_OBJS:.o=.d)

$(BUILD_DIR)/notebook-macos/plot_png.o: $(SPUTNIK_PLOT_DIR)/native/plot_png.c $(SPUTNIK_DIR)/runtime/sputnik_ext.h
	@mkdir -p "$(@D)"
	$(CC) -I$(SPUTNIK_DIR) -std=c11 -O2 -mmacosx-version-min=14.0 -c $< -o $@

$(BUILD_DIR)/notebook-macos/libNotebookBackend.a: $(MAC_NOTEBOOK_OBJS) $(SPUTNIK_LIBRARY)
	xcrun libtool -static -o $@ $(MAC_NOTEBOOK_OBJS)

# Direct development launches resolve the helper beside the UI executable,
# just like the packaged app. Keep that layout even when only this target is built.
$(BUILD_DIR)/notebook-macos/sputnik-notebook-worker: $(BUILD_DIR)/sputnik-notebook-worker
	@mkdir -p "$(@D)"
	ln -sf ../sputnik-notebook-worker "$@"

$(BUILD_DIR)/notebook-macos/sputnik-notebook-remote: $(BUILD_DIR)/sputnik-notebook-remote
	@mkdir -p "$(@D)"
	ln -sf ../sputnik-notebook-remote "$@"

$(BUILD_DIR)/notebook-macos/sputnik: $(SPUTNIK_REMOTE_COMPILER)
	@mkdir -p "$(@D)"
	ln -sf "$(SPUTNIK_REMOTE_COMPILER)" "$@"

$(BUILD_DIR)/notebook-macos/AppIcon.icns: $(MAC_NOTEBOOK_ICON)
	@mkdir -p "$(@D)"
	cp "$<" "$@"

$(BUILD_DIR)/notebook-macos/SputnikNotebook: $(MAC_NOTEBOOK_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a | $(BUILD_DIR)/notebook-macos/sputnik-notebook-worker $(BUILD_DIR)/notebook-macos/sputnik-notebook-remote $(BUILD_DIR)/notebook-macos/sputnik $(BUILD_DIR)/notebook-macos/AppIcon.icns
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h $(MAC_NOTEBOOK_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o $@

notebook-macos: $(BUILD_DIR)/notebook-macos/SputnikNotebook $(BUILD_DIR)/sputnik-notebook-worker $(BUILD_DIR)/sputnik-notebook-remote $(MAC_NOTEBOOK_ICON) tools/notebook-macos/Info.plist tools/notebook-macos/package-app.sh
	bash tools/notebook-macos/package-app.sh "$(BUILD_DIR)/notebook-macos/SputnikNotebook" "$(BUILD_DIR)/Sputnik Notebook.app" "$(OPENSSL_LIB_DIR)" "$(BUILD_DIR)/sputnik-notebook-worker" "$(BUILD_DIR)/sputnik-notebook-remote" "$(SPUTNIK_REMOTE_COMPILER)" "$(SPUTNIK_DIR)"

$(BUILD_DIR)/notebook_macos_bridge_tests: tests/notebook_macos_bridge_tests.cpp $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $< $(SPUTNIK_DIR)/tools/isputnik/terminal_wait.cpp $(BUILD_DIR)/notebook-macos/libNotebookBackend.a $(LDFLAGS) $(SPUTNIK_DYNAMIC_EXPORT_FLAGS) -o $@

$(BUILD_DIR)/notebook_plot_tests: tests/notebook_plot_tests.cpp $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $< $(SPUTNIK_DIR)/tools/isputnik/terminal_wait.cpp $(BUILD_DIR)/notebook-macos/libNotebookBackend.a $(LDFLAGS) $(SPUTNIK_DYNAMIC_EXPORT_FLAGS) -o $@

$(BUILD_DIR)/notebook_table_tests: tests/notebook_table_tests.cpp $(NOTEBOOK_WORKER_TRANSPORT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $< $(NOTEBOOK_WORKER_TRANSPORT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a $(LDFLAGS) $(SPUTNIK_DYNAMIC_EXPORT_FLAGS) -o $@

.PHONY: test-notebook-table
$(BUILD_DIR)/notebook_audio_tests: tests/notebook_audio_tests.cpp $(NOTEBOOK_WORKER_TRANSPORT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $< $(NOTEBOOK_WORKER_TRANSPORT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a $(LDFLAGS) $(SPUTNIK_DYNAMIC_EXPORT_FLAGS) -o $@

.PHONY: test-notebook-audio
test-notebook-audio: $(BUILD_DIR)/notebook_audio_tests
	$(BUILD_DIR)/notebook_audio_tests

test-notebook-table: $(BUILD_DIR)/notebook_table_tests $(BUILD_DIR)/sputnik-notebook-worker
	$(BUILD_DIR)/notebook_table_tests "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)"

$(BUILD_DIR)/notebook_macos_model_tests: tests/notebook_macos_model_tests.swift tools/notebook-macos/NotebookModel.swift tools/notebook-macos/NotebookRemote.swift tools/notebook-macos/NotebookBoard.swift tools/notebook-macos/NotebookP1Settings.swift tools/notebook-macos/NotebookPeriodicWork.swift tools/notebook-macos/NotebookTextVariable.swift tools/notebook-macos/NotebookFigure.swift tools/notebook-macos/NotebookAudio.swift tools/notebook-macos/NotebookRunHistory.swift tools/notebook-macos/NotebookRuntimeTelemetry.swift tools/notebook-macos/NotebookSelection.swift tools/notebook-macos/NotebookAudioAnnotations.swift tools/notebook-macos/NotebookPlasma.swift tools/notebook-macos/NotebookPlotScene.swift tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h tests/notebook_macos_model_tests.swift tools/notebook-macos/NotebookModel.swift tools/notebook-macos/NotebookRemote.swift tools/notebook-macos/NotebookBoard.swift tools/notebook-macos/NotebookP1Settings.swift tools/notebook-macos/NotebookPeriodicWork.swift tools/notebook-macos/NotebookTextVariable.swift tools/notebook-macos/NotebookFigure.swift tools/notebook-macos/NotebookAudio.swift tools/notebook-macos/NotebookRunHistory.swift tools/notebook-macos/NotebookRuntimeTelemetry.swift tools/notebook-macos/NotebookSelection.swift tools/notebook-macos/NotebookAudioAnnotations.swift tools/notebook-macos/NotebookPlasma.swift tools/notebook-macos/NotebookPlotScene.swift $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -lc++ $(LDFLAGS) -o $@

BOARD_LAYOUT_TEST_SWIFT := $(filter-out tools/notebook-macos/NotebookApp.swift,$(MAC_NOTEBOOK_SWIFT))

$(BUILD_DIR)/notebook_dependencies_tests: tests/notebook_dependencies_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -Onone -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h $< $(BOARD_LAYOUT_TEST_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@

.PHONY: test-notebook-dependencies
test-notebook-dependencies: $(BUILD_DIR)/notebook_dependencies_tests remote-core
	$(BUILD_DIR)/notebook_dependencies_tests "$(abspath $(BUILD_DIR)/sputnik-notebook-remote)"
.PHONY: test-notebook-package-catalog
test-notebook-package-catalog: $(BUILD_DIR)/notebook_dependencies_tests remote-core
	python3 tests/notebook_package_catalog_test.py "$(SPUTNIK_REMOTE_COMPILER)" "$(abspath $(BUILD_DIR)/notebook_dependencies_tests)" "$(abspath $(BUILD_DIR)/sputnik-notebook-remote)"
	python3 tests/notebook_remote_tests.py --core "$(abspath $(BUILD_DIR)/sputnik-notebook-remote)" --worker "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)" --test RemoteTests.test_package_catalog_uses_execution_host_without_retiring_workers

$(BUILD_DIR)/notebook_macos_audio_tests: tests/notebook_macos_audio_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -Onone -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h tests/notebook_macos_audio_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@

.PHONY: test-notebook-audio-ui
test-notebook-audio-ui: $(BUILD_DIR)/notebook_macos_audio_tests $(BUILD_DIR)/sputnik-notebook-worker
	$(BUILD_DIR)/notebook_macos_audio_tests --worker "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)" --output "$(abspath $(BUILD_DIR)/audio)"

$(BUILD_DIR)/notebook_macos_table_tests: tests/notebook_macos_table_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -Onone -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h tests/notebook_macos_table_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@

.PHONY: test-notebook-table-ui
test-notebook-table-ui: $(BUILD_DIR)/notebook_macos_table_tests $(BUILD_DIR)/sputnik-notebook-worker
	$(BUILD_DIR)/notebook_macos_table_tests --worker "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)" --output "$(abspath $(BUILD_DIR)/datatable-view)"

test-notebook-macos: test-notebook-table test-notebook-table-ui

$(BUILD_DIR)/notebook_macos_sqlite_tests: tests/notebook_macos_sqlite_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -Onone -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h tests/notebook_macos_sqlite_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook_macos_remote_tests: tests/notebook_macos_remote_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h tests/notebook_macos_remote_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@

.PHONY: test-notebook-remote-ui
test-notebook-remote-ui: remote-core $(BUILD_DIR)/notebook_macos_remote_tests
	python3 tests/notebook_remote_ui_tests.py --test "$(abspath $(BUILD_DIR)/notebook_macos_remote_tests)" --core "$(abspath $(BUILD_DIR)/sputnik-notebook-remote)" --worker "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)" --keep

$(BUILD_DIR)/notebook_macos_p0_tests: tests/notebook_macos_p0_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h tests/notebook_macos_p0_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook_macos_p1_tests: tests/notebook_macos_p1_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h tests/notebook_macos_p1_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@

.PHONY: test-notebook-p1
test-notebook-p1: $(BUILD_DIR)/notebook_macos_p1_tests $(BUILD_DIR)/notebook-macos/notebook_board_tests $(BUILD_DIR)/sputnik-notebook-worker
	$(BUILD_DIR)/notebook-macos/notebook_board_tests
	$(BUILD_DIR)/notebook_macos_p1_tests --worker "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)" --output "$(abspath $(BUILD_DIR))/p1-components"
test-notebook-macos: test-notebook-p1

.PHONY: test-notebook-p0
test-notebook-p0: $(BUILD_DIR)/notebook_macos_p0_tests $(BUILD_DIR)/notebook-macos/notebook_board_tests $(BUILD_DIR)/sputnik-notebook-worker
	$(BUILD_DIR)/notebook-macos/notebook_board_tests
	$(BUILD_DIR)/notebook_macos_p0_tests --worker "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)" --output "$(abspath $(BUILD_DIR))/p0-components"
test-notebook-macos: test-notebook-p0

$(BUILD_DIR)/notebook_macos_periodic_tests: tests/notebook_macos_periodic_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h tests/notebook_macos_periodic_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@

.PHONY: test-notebook-periodic
test-notebook-periodic: $(BUILD_DIR)/notebook-macos/notebook_periodic_tests $(BUILD_DIR)/notebook_macos_periodic_tests $(BUILD_DIR)/sputnik-notebook-worker
	$(BUILD_DIR)/notebook-macos/notebook_periodic_tests "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)"
	$(BUILD_DIR)/notebook_macos_periodic_tests --worker "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)" --output "$(abspath $(BUILD_DIR))/periodic-work"
test-notebook-macos: test-notebook-periodic

$(BUILD_DIR)/notebook_macos_image_tests: tests/notebook_macos_image_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h tests/notebook_macos_image_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook_macos_board_layout_tests: tests/notebook_macos_board_layout_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h tests/notebook_macos_board_layout_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@

.PHONY: test-notebook-board-layout
test-notebook-board-layout: $(BUILD_DIR)/notebook-macos/notebook_board_tests $(BUILD_DIR)/notebook_macos_model_tests $(BUILD_DIR)/notebook_macos_board_layout_tests
	$(BUILD_DIR)/notebook-macos/notebook_board_tests
	$(BUILD_DIR)/notebook_macos_model_tests
	$(BUILD_DIR)/notebook_macos_board_layout_tests --output "$(abspath $(BUILD_DIR))/board-layout"
test-notebook-macos: $(BUILD_DIR)/notebook_macos_board_layout_tests

$(BUILD_DIR)/notebook_macos_syntax_tests: tests/notebook_macos_syntax_tests.swift tools/notebook-macos/SputnikSyntax.swift tools/notebook-macos/SputnikGreekLetters.swift tools/notebook-macos/CodeEditor.swift tools/notebook-macos/NotebookPalette.swift
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache $^ -framework AppKit -framework SwiftUI -o $@

LIVE_CHART_TEST_SWIFT := tools/notebook-macos/NotebookModel.swift tools/notebook-macos/NotebookRemote.swift tools/notebook-macos/NotebookBoard.swift tools/notebook-macos/NotebookP1Settings.swift tools/notebook-macos/NotebookPeriodicWork.swift tools/notebook-macos/NotebookTextVariable.swift tools/notebook-macos/NotebookFigure.swift tools/notebook-macos/NotebookAudio.swift tools/notebook-macos/NotebookRunHistory.swift tools/notebook-macos/NotebookRuntimeTelemetry.swift tools/notebook-macos/NotebookSelection.swift tools/notebook-macos/NotebookAudioAnnotations.swift tools/notebook-macos/NotebookPlasma.swift tools/notebook-macos/NotebookPlotScene.swift tools/notebook-macos/NotebookPlotView.swift tools/notebook-macos/NotebookLiveChartView.swift tools/notebook-macos/NotebookObjectMenu.swift tools/notebook-macos/NotebookPalette.swift tools/notebook-macos/NotebookProgressView.swift
$(BUILD_DIR)/notebook_macos_live_chart_tests: tests/notebook_macos_live_chart_tests.swift $(LIVE_CHART_TEST_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h tests/notebook_macos_live_chart_tests.swift $(LIVE_CHART_TEST_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@

$(BUILD_DIR)/notebook_macos_theme_tests: tests/notebook_macos_theme_tests.swift tools/notebook-macos/NotebookPreferences.swift tools/notebook-macos/NotebookPalette.swift tools/notebook-macos/SputnikSyntax.swift
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache $^ -framework AppKit -framework SwiftUI -o $@

.PHONY: test-notebook-themes
test-notebook-themes: notebook-macos $(BUILD_DIR)/notebook_macos_theme_tests
	$(BUILD_DIR)/notebook_macos_theme_tests
	python3 tests/notebook_macos_ui_smoke.py "$(BUILD_DIR)/Sputnik Notebook.app/Contents/MacOS/SputnikNotebook" --theme-smoke-test

$(BUILD_DIR)/notebook_macos_result_tests: tests/notebook_macos_result_tests.swift tools/notebook-macos/NotebookResultView.swift tools/notebook-macos/NotebookObjectMenu.swift tools/notebook-macos/NotebookPalette.swift
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache $^ -framework AppKit -framework SwiftUI -o $@

$(BUILD_DIR)/notebook_macos_plot_tests: tests/notebook_macos_plot_tests.swift tools/notebook-macos/NotebookPlotScene.swift tools/notebook-macos/NotebookPlotView.swift tools/notebook-macos/NotebookFigure.swift tools/notebook-macos/NotebookAudio.swift tools/notebook-macos/NotebookRunHistory.swift tools/notebook-macos/NotebookRuntimeTelemetry.swift tools/notebook-macos/NotebookFigureView.swift tools/notebook-macos/NotebookObjectMenu.swift tools/notebook-macos/NotebookPalette.swift
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache $^ -framework AppKit -framework SwiftUI -o $@

test-notebook-results: $(BUILD_DIR)/notebook_macos_result_tests $(BUILD_DIR)/notebook-macos/notebook_result_tests
	$(BUILD_DIR)/notebook_macos_result_tests
	$(BUILD_DIR)/notebook-macos/notebook_result_tests

$(BUILD_DIR)/notebook_macos_richtext_tests: tests/notebook_macos_richtext_tests.swift tools/notebook-macos/RichTextEditor.swift tools/notebook-macos/RichTextStructure.swift tools/notebook-macos/RichTextEditing.swift tools/notebook-macos/RichTextInterpolation.swift tools/notebook-macos/NotebookTextVariable.swift tools/notebook-macos/NotebookPalette.swift
	xcrun swiftc -swift-version 5 -O -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache $^ -framework AppKit -framework SwiftUI -o $@

# Reuse the same backend archive for cross-host regressions instead of
# recompiling the VM separately for each Session/project test executable.
$(BUILD_DIR)/notebook-macos/%_tests: tests/%_tests.cpp $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $< $(SPUTNIK_DIR)/tools/isputnik/terminal_wait.cpp $(BUILD_DIR)/notebook-macos/libNotebookBackend.a $(LDFLAGS) $(SPUTNIK_DYNAMIC_EXPORT_FLAGS) -o $@

# Exercise the shared language sessions against the GUI's compiled backend too.
$(BUILD_DIR)/notebook-macos/%_tests: $(SPUTNIK_DIR)/tests/%_tests.cpp $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $< $(SPUTNIK_DIR)/tools/isputnik/terminal_wait.cpp $(BUILD_DIR)/notebook-macos/libNotebookBackend.a $(LDFLAGS) $(SPUTNIK_DYNAMIC_EXPORT_FLAGS) -o $@

test-notebook-macos: notebook-macos $(BUILD_DIR)/notebook_macos_bridge_tests $(BUILD_DIR)/notebook_macos_model_tests $(BUILD_DIR)/notebook_macos_syntax_tests $(BUILD_DIR)/notebook_macos_richtext_tests $(BUILD_DIR)/notebook-macos/isputnik_tests $(BUILD_DIR)/notebook-macos/isputnik_project_tests $(BUILD_DIR)/notebook-macos/isputnik_tabs_tests $(BUILD_DIR)/notebook-macos/notebook_project_tests
	$(BUILD_DIR)/notebook_macos_bridge_tests
	$(BUILD_DIR)/notebook_macos_model_tests
	$(BUILD_DIR)/notebook_macos_board_layout_tests
	$(BUILD_DIR)/notebook_macos_live_chart_tests
	$(BUILD_DIR)/notebook_macos_syntax_tests
	$(BUILD_DIR)/notebook_macos_richtext_tests
	$(BUILD_DIR)/notebook_macos_theme_tests
	$(BUILD_DIR)/notebook-macos/notebook_project_tests
	$(BUILD_DIR)/notebook-macos/isputnik_tests
	$(BUILD_DIR)/notebook-macos/isputnik_project_tests
	$(BUILD_DIR)/notebook-macos/isputnik_tabs_tests
	$(BUILD_DIR)/notebook-macos/notebook_board_tests
	$(BUILD_DIR)/notebook-macos/notebook_dependency_tests
	python3 tests/notebook_macos_ui_smoke.py "$(BUILD_DIR)/Sputnik Notebook.app/Contents/MacOS/SputnikNotebook" --theme-smoke-test
test-notebook-macos: $(BUILD_DIR)/notebook-macos/notebook_board_tests
test-notebook-macos: $(BUILD_DIR)/notebook-macos/notebook_dependency_tests
test-notebook-macos: test-notebook-results $(BUILD_DIR)/notebook_macos_theme_tests $(BUILD_DIR)/notebook_macos_live_chart_tests
test-notebook-macos: test-notebook-images
else
notebook-macos test-notebook-macos:
	@echo "The native notebook requires macOS 14+ and Xcode Command Line Tools."
	@exit 1
endif

# Check the language runtime before compiling either local or shared sources.
$(MAC_NOTEBOOK_OBJS) $(BUILD_DIR)/sputnik-notebook-worker: | runtime
$(BUILD_DIR)/notebook-macos/SputnikNotebook $(BUILD_DIR)/sputnik-notebook-worker: $(SPUTNIK_LIBRARY)
TEST_NAMES := $(notdir $(basename $(wildcard tests/*_tests.cpp))) $(ISPUTNIK_TEST_NAMES)
.PHONY: test-core
test: test-core
ifeq ($(UNAME_S),Darwin)
CORE_TEST_DIR := $(BUILD_DIR)/notebook-macos
CORE_TEST_NAMES := $(filter-out notebook_worker_tests notebook_worker_host_tests notebook_plot_tests,$(TEST_NAMES))
else
CORE_TEST_DIR := $(BUILD_DIR)/core
CORE_TEST_NAMES := $(filter-out notebook_worker_tests notebook_worker_host_tests notebook_plot_tests notebook_macos_bridge_tests notebook_board_tests notebook_periodic_tests notebook_cell_component_tests,$(TEST_NAMES))
$(CORE_TEST_DIR)/%_tests: tests/%_tests.cpp $(APP_SESSION_SRCS) $(SPUTNIK_DIR)/tools/isputnik/terminal_wait.cpp $(NOTEBOOK_WORKER_TRANSPORT)
	@mkdir -p "$(@D)"
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(filter %.cpp,$^) $(LDFLAGS) $(SPUTNIK_DYNAMIC_EXPORT_FLAGS) $(SPUTNIK_DYNAMIC_LOADER_LIBS) -o $@
$(CORE_TEST_DIR)/%_tests: $(SPUTNIK_DIR)/tests/%_tests.cpp $(APP_SESSION_SRCS) $(SPUTNIK_DIR)/tools/isputnik/terminal_wait.cpp $(NOTEBOOK_WORKER_TRANSPORT)
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

ifeq ($(UNAME_S),Darwin)
$(BUILD_DIR)/notebook_macos_cell_component_tests: tests/notebook_macos_cell_component_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -Onone -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h tests/notebook_macos_cell_component_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@

.PHONY: test-notebook-cell-components
test-notebook-cell-components: $(BUILD_DIR)/notebook-macos/notebook_cell_component_tests $(BUILD_DIR)/notebook_macos_cell_component_tests $(BUILD_DIR)/sputnik-notebook-worker
	$(BUILD_DIR)/notebook-macos/notebook_cell_component_tests "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)"
	$(BUILD_DIR)/notebook_macos_cell_component_tests --worker "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)" --output "$(abspath $(BUILD_DIR))/cell-components"
test-notebook-macos: test-notebook-cell-components

$(BUILD_DIR)/notebook_macos_config_tests: tests/notebook_macos_config_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -Onone -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/config-swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h tests/notebook_macos_config_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@

.PHONY: test-notebook-config
test-notebook-config: $(BUILD_DIR)/notebook_macos_config_tests $(BUILD_DIR)/sputnik-notebook-worker
	$(BUILD_DIR)/notebook_macos_config_tests --worker "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)" --output "$(abspath $(BUILD_DIR))/config-editor"
	python3 tests/notebook_config_remote_inputs_tests.py "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)"
test-notebook-macos: test-notebook-config
endif

ifeq ($(UNAME_S),Darwin)
$(BUILD_DIR)/notebook_macos_remote_cell_tests: tests/notebook_macos_remote_cell_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -Onone -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h tests/notebook_macos_remote_cell_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@

.PHONY: test-notebook-remote-cell-components
test-notebook-remote-cell-components: remote-core $(BUILD_DIR)/notebook_macos_remote_cell_tests
	python3 tests/notebook_remote_ui_tests.py --test "$(abspath $(BUILD_DIR)/notebook_macos_remote_cell_tests)" --core "$(abspath $(BUILD_DIR)/sputnik-notebook-remote)" --worker "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)"
test-notebook-macos: test-notebook-remote-cell-components
endif

$(BUILD_DIR)/notebook_macos_history_tests: tests/notebook_macos_history_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -Onone -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h $< $(BOARD_LAYOUT_TEST_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@

.PHONY: test-notebook-history
test-notebook-history: $(BUILD_DIR)/notebook_macos_history_tests $(BUILD_DIR)/sputnik-notebook-worker
	$(BUILD_DIR)/notebook_macos_history_tests --worker "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)" --output "$(abspath $(BUILD_DIR)/history)"

$(BUILD_DIR)/notebook_runtime_telemetry_tests: tests/notebook_runtime_telemetry_tests.cpp $(NOTEBOOK_WORKER_TRANSPORT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $< $(NOTEBOOK_WORKER_TRANSPORT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a $(LDFLAGS) $(SPUTNIK_DYNAMIC_EXPORT_FLAGS) -o $@

.PHONY: test-notebook-runtime-telemetry
test-notebook-runtime-telemetry: $(BUILD_DIR)/notebook_runtime_telemetry_tests
	$(BUILD_DIR)/notebook_runtime_telemetry_tests

$(BUILD_DIR)/notebook_component_data_tests: tests/notebook_component_data_tests.cpp $(NOTEBOOK_WORKER_TRANSPORT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $< $(NOTEBOOK_WORKER_TRANSPORT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a $(LDFLAGS) $(SPUTNIK_DYNAMIC_EXPORT_FLAGS) -o $@

$(BUILD_DIR)/notebook_macos_component_data_tests: tests/notebook_macos_component_data_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) tests/notebook_annotation_sheet_test_support.swift tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -Onone -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h $< $(BOARD_LAYOUT_TEST_SWIFT) tests/notebook_annotation_sheet_test_support.swift $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@

.PHONY: test-notebook-component-data
test-notebook-component-data: $(BUILD_DIR)/notebook_component_data_tests $(BUILD_DIR)/notebook_macos_component_data_tests $(BUILD_DIR)/sputnik-notebook-worker
	$(BUILD_DIR)/notebook_component_data_tests
	$(BUILD_DIR)/notebook_macos_component_data_tests --worker "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)" --output "$(abspath $(BUILD_DIR)/component-data)"

ifeq ($(UNAME_S),Darwin)
test-notebook-macos: test-notebook-history test-notebook-runtime-telemetry test-notebook-component-data
endif

$(BUILD_DIR)/notebook_audio_annotation_tests: tests/notebook_audio_annotation_tests.cpp $(NOTEBOOK_WORKER_TRANSPORT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $< $(NOTEBOOK_WORKER_TRANSPORT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a $(LDFLAGS) $(SPUTNIK_DYNAMIC_EXPORT_FLAGS) -o $@

$(BUILD_DIR)/notebook_macos_audio_annotation_tests: tests/notebook_macos_audio_annotation_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) tests/notebook_annotation_sheet_test_support.swift tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -Onone -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h $< $(BOARD_LAYOUT_TEST_SWIFT) tests/notebook_annotation_sheet_test_support.swift $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@

.PHONY: test-notebook-audio-annotations
test-notebook-audio-annotations: $(BUILD_DIR)/notebook_audio_annotation_tests $(BUILD_DIR)/notebook_macos_audio_annotation_tests $(BUILD_DIR)/sputnik-notebook-worker
	$(BUILD_DIR)/notebook_audio_annotation_tests
	$(BUILD_DIR)/notebook_macos_audio_annotation_tests --worker "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)" --output "$(abspath $(BUILD_DIR)/audio-annotations)"
ifeq ($(UNAME_S),Darwin)
test-notebook-macos: test-notebook-audio-annotations
endif

ifeq ($(UNAME_S),Darwin)
$(BUILD_DIR)/notebook_macos_remote_work_tests: tests/notebook_macos_remote_work_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) tools/notebook-macos/NotebookBridge.h $(BUILD_DIR)/notebook-macos/libNotebookBackend.a
	xcrun swiftc -swift-version 5 -Onone -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header tools/notebook-macos/NotebookBridge.h tests/notebook_macos_remote_work_tests.swift $(BOARD_LAYOUT_TEST_SWIFT) $(BUILD_DIR)/notebook-macos/libNotebookBackend.a -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@
.PHONY: test-notebook-remote-work
test-notebook-remote-work: remote-core $(BUILD_DIR)/notebook_macos_remote_work_tests
	python3 tests/notebook_remote_ui_tests.py --test "$(abspath $(BUILD_DIR)/notebook_macos_remote_work_tests)" --core "$(abspath $(BUILD_DIR)/sputnik-notebook-remote)" --worker "$(abspath $(BUILD_DIR)/sputnik-notebook-worker)"
endif
