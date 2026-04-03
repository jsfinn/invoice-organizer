import SwiftUI

struct PreviewCard: View {
    @ObservedObject var model: AppModel
    let rotationCoordinator: PreviewRotationCoordinator
    let invoice: InvoiceItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preview")
                    .font(.title2.bold())
            }

            InvoicePreviewView(
                invoice: invoice,
                rotationCoordinator: rotationCoordinator
            )
        }
    }
}
