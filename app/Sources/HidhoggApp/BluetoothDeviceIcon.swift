import HidhoggDomain
import SwiftUI

struct BluetoothDeviceIcon: View {
    let kind: BluetoothDeviceKind

    var body: some View {
        Group {
            if let systemSymbol = kind.optionalSystemSymbol {
                Image(systemName: systemSymbol)
            } else {
                bluetoothRune
            }
        }
        .accessibilityHidden(true)
    }

    private var bluetoothRune: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let centerX = width / 2
            let centerY = height / 2
            let left = width * 0.14
            let right = width * 0.86
            let top = height * 0.06
            let upper = height * 0.25
            let lower = height * 0.75
            let bottom = height * 0.94

            Path { path in
                path.move(to: CGPoint(x: centerX, y: top))
                path.addLine(to: CGPoint(x: centerX, y: bottom))
                path.move(to: CGPoint(x: centerX, y: top))
                path.addLine(to: CGPoint(x: right, y: upper))
                path.addLine(to: CGPoint(x: centerX, y: centerY))
                path.addLine(to: CGPoint(x: right, y: lower))
                path.addLine(to: CGPoint(x: centerX, y: bottom))
                path.move(to: CGPoint(x: left, y: upper))
                path.addLine(to: CGPoint(x: centerX, y: centerY))
                path.move(to: CGPoint(x: left, y: lower))
                path.addLine(to: CGPoint(x: centerX, y: centerY))
            }
            .stroke(
                .primary,
                style: StrokeStyle(lineWidth: max(1.5, min(width, height) * 0.1), lineCap: .round, lineJoin: .round)
            )
        }
        .accessibilityHidden(true)
    }
}
