# Include after the repository Makefile. Uses its normal Swift/native flags.
AUDIT_MODEL_SWIFT := $(addprefix tools/notebook-macos/,NotebookModel.swift NotebookLibrary.swift NotebookRemote.swift NotebookBoard.swift NotebookP1Settings.swift NotebookPeriodicWork.swift NotebookTextVariable.swift NotebookFigure.swift NotebookAudio.swift NotebookRunHistory.swift NotebookResourcePolicy.swift NotebookRuntimeTelemetry.swift NotebookSelection.swift NotebookAudioAnnotations.swift NotebookPlasma.swift NotebookPlotScene.swift)
.build/remote-action-audit-probe: docs/evidence/2026-11-01/remote-action-audit/probe.swift $(AUDIT_MODEL_SWIFT) $(NOTEBOOK_CORE_LIBRARY)
	@mkdir -p .build
	xcrun swiftc -swift-version 5 -Onone -target $(MAC_NOTEBOOK_TARGET) -module-cache-path $(BUILD_DIR)/notebook-macos/swift-cache -import-objc-header packages/notebook-core/include/notebook/core/notebook.h $< $(AUDIT_MODEL_SWIFT) $(NOTEBOOK_CORE_LIBRARY) -framework AppKit -framework SwiftUI -lc++ $(LDFLAGS) -o $@
