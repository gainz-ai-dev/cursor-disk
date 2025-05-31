import SwiftUI

struct ChartView: View {
    /// Progress value from 0 to 1.
    var progress: Double = 0.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.3), lineWidth: 20)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [.accentColor, .purple]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 20, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Text(percentText)
                .font(.title.bold())
        }
        .padding()
    }

    private var percentText: String {
        String(format: "%.0f%%", progress * 100)
    }
}

#Preview {
    ChartView(progress: 0.7)
        .frame(width: 200, height: 200)
        .padding()
}
