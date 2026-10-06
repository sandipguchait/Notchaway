import SwiftUI

/// A tap counter (e.g. 108 for a mala) with glowing orbs, and a paced 4-in / 6-out breathing guide.
struct MindfulCard: View {
    @AppStorage("mindful.count") private var count = 0
    @AppStorage("mindful.goal") private var goal = 108
    @State private var breathing = false
    @State private var breathStart = Date()

    var body: some View {
        LiveCard(glow: .orange) {
            VStack(spacing: 4) {
                HStack {
                    Button {
                        breathing.toggle()
                        breathStart = Date()
                    } label: {
                        Label(breathing ? "Breathing" : "Breathe", systemImage: breathing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("\(count)")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(.orange)
                    ZStack {
                        Circle().stroke(Color.orange.opacity(0.25), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: CGFloat(count % goal) / CGFloat(max(goal, 1)))
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 12, height: 12)
                }

                if breathing {
                    TimelineView(.animation) { context in
                        let phase = breathPhase(at: context.date)
                        VStack(spacing: 2) {
                            orbs(scale: 0.75 + 0.4 * phase.amount)
                            Text(phase.inhale ? "Breathe in" : "Breathe out")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    orbs(scale: 1)
                        .onTapGesture {
                            count += 1
                            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                        }
                        .contextMenu {
                            Button("Reset Count") { count = 0 }
                            Picker("Goal", selection: $goal) {
                                Text("27").tag(27)
                                Text("54").tag(54)
                                Text("108").tag(108)
                            }
                        }
                        .help("Tap to count · right-click to reset")
                }
            }
        }
    }

    private func orbs(scale: Double) -> some View {
        HStack(spacing: -8) {
            ForEach(0..<2, id: \.self) { _ in sideOrb(size: 30) }
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 92, height: 92)
                Circle()
                    .fill(Color.orange)
                    .frame(width: 46, height: 46)
            }
            .scaleEffect(scale)
            .frame(width: 70, height: 70)
            ForEach(0..<2, id: \.self) { _ in sideOrb(size: 30) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private func sideOrb(size: CGFloat) -> some View {
        Circle()
            .fill(Color.orange.opacity(0.28))
            .frame(width: size, height: size)
    }

    private func breathPhase(at date: Date) -> (inhale: Bool, amount: Double) {
        let cycle = 10.0
        let t = date.timeIntervalSince(breathStart).truncatingRemainder(dividingBy: cycle)
        if t < 4 {
            return (true, (1 - cos(t / 4 * .pi)) / 2)
        }
        return (false, (1 + cos((t - 4) / 6 * .pi)) / 2)
    }
}
