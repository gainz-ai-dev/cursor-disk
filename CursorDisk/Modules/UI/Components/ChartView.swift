import SwiftUI

struct ChartView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.gray.opacity(0.2))
            Text("Chart Placeholder")
                .font(.title)
        }
        .padding()
    }
}

#Preview {
    ChartView()
        .frame(width: 400, height: 300)
} 