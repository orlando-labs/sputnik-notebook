import SwiftUI

/// Only the board designer edits definitions and transcript requirements.
struct NotebookAnnotationSettingsView: View {
    @Binding var component: NotebookBoardComponent
    @State private var editingClasses = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Classes & attributes…") { editingClasses = true }.accessibilityIdentifier("board-annotation-classes")
            Text("\(component.annotationClasses.count) allowed classes · \(component.annotationClasses.reduce(0) { $0 + $1.attributes.count }) attributes")
                .font(.caption).foregroundStyle(NotebookPalette.muted)
            if component.kind == "audio_annotator" {
                Divider()
                Text("Whole-track transcript").font(.caption.bold())
                transcriptToggle("Allow transcript", allowed: true, segment: false)
                transcriptToggle("Require transcript", allowed: false, segment: false).disabled(!component.transcriptPolicy.trackAllowed)
                Text("Segment transcripts").font(.caption.bold())
                transcriptToggle("Allow segment transcripts", allowed: true, segment: true)
                transcriptToggle("Require every segment transcript", allowed: false, segment: true).disabled(!component.transcriptPolicy.segmentAllowed)
            }
            Text("Annotators choose from this schema. Definitions and requirements are saved with the board.").font(.caption).foregroundStyle(NotebookPalette.muted)
        }
        .sheet(isPresented: $editingClasses) {
            NotebookAnnotationClassesView(classes: component.annotationClasses) { component.annotation_classes = $0 }
        }
        .accessibilityIdentifier("board-annotation-settings")
    }
    private func transcriptToggle(_ title: String, allowed: Bool, segment: Bool) -> some View {
        Toggle(title, isOn: Binding(get: {
            let policy = component.transcriptPolicy
            return segment ? (allowed ? policy.segmentAllowed : policy.segmentRequired) : (allowed ? policy.trackAllowed : policy.trackRequired)
        }, set: { value in
            if segment {
                if allowed { component.audio_segment_transcript_allowed = value; if !value { component.audio_segment_transcript_required = false } }
                else { component.audio_segment_transcript_required = value }
            } else {
                if allowed { component.audio_transcript_allowed = value; if !value { component.audio_transcript_required = false } }
                else { component.audio_transcript_required = value }
            }
        })).accessibilityIdentifier("board-" + (segment ? "segment-" : "track-") + (allowed ? "transcript-allowed" : "transcript-required"))
    }
}
