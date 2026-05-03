import XCTest
import SwiftUI
@testable import Keepur

final class KeepurFoundationDataDisplayTests: XCTestCase {
    func testChipClusterAcrossOverflowModes() {
        let cases: [KeepurChipCluster] = [
            KeepurChipCluster([]),
            KeepurChipCluster(["swift"]),
            KeepurChipCluster(["swift", "ruby", "python", "go", "rust"]),
            KeepurChipCluster(["swift", "ruby", "python", "go", "rust"], maxVisible: 3),
            KeepurChipCluster(["swift", "ruby"], maxVisible: 5),
            KeepurChipCluster(["swift", "ruby", "python"], maxVisible: 0),
        ]
        for cluster in cases {
            _ = cluster.body
        }
    }

    func testMetricGridAcrossSizes() {
        let one = KeepurMetricGrid([.init(label: "MODEL", value: "claude-sonnet-4")])
        let three = KeepurMetricGrid([
            .init(label: "MODEL",       value: "claude-sonnet-4"),
            .init(label: "MESSAGES",    value: "1,234"),
            .init(label: "LAST ACTIVE", value: "2m ago"),
        ])
        let four = KeepurMetricGrid([
            .init(label: "MODEL",       value: "claude-sonnet-4"),
            .init(label: "MESSAGES",    value: "1,234"),
            .init(label: "LAST ACTIVE", value: "2m ago"),
            .init(label: "OWNER",       value: "may"),
        ])
        let longValue = KeepurMetricGrid([
            .init(label: "MODEL", value: String(repeating: "claude-sonnet-4-very-long-id-", count: 5)),
        ])
        let empty = KeepurMetricGrid([])
        for grid in [one, three, four, longValue, empty] {
            _ = grid.body
        }
    }

    func testCardBorderedAndUnbordered() {
        _ = KeepurCard { Text("hello") }.body
        _ = KeepurCard(bordered: true) { Text("hello") }.body
        _ = KeepurCard { EmptyView() }.body
        _ = KeepurCard { KeepurCard { Text("nested") } }.body
    }
}
