import SwiftUI

/// Branch lines, one animatable shape per edge (screen coordinates).
struct ConnectorsLayer: View {
    let connectors: [MapScene.StyledConnector]
    let viewport: Viewport

    var body: some View {
        ZStack {
            ForEach(connectors) { connector in
                ConnectorView(geometry: connector.geometry.transformed(by: viewport),
                              color: Color(hex: connector.colorHex))
                    .opacity(connector.isFading ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ConnectorView: View {
    let geometry: ConnectorGeometry
    let color: Color

    var body: some View {
        if geometry.isTapered {
            ConnectorShape(geometry: geometry).fill(color)
        } else {
            ConnectorShape(geometry: geometry).stroke(color, style: StrokeStyle(
                lineWidth: geometry.startWidth, lineCap: .round, lineJoin: .round,
                dash: ConnectorGeometry.dashPattern(geometry.dash, width: geometry.startWidth)
            ))
        }
    }
}
