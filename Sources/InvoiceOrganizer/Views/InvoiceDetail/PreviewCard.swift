import SwiftUI

struct PreviewCard: View {
    @ObservedObject var previewState: PreviewViewState
    let invoice: PhysicalArtifact

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preview")
                    .font(.title2.bold())
            }

            InvoicePreviewView(
                invoice: invoice,
                previewState: previewState
            )
        }
    }
}
