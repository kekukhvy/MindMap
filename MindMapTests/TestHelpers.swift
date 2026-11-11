import CoreGraphics
import Foundation
@testable import MindMap

enum TestTree {
    /// Builds a node with `count` leaf children named "<prefix>i".
    static func node(_ text: String, style: LayoutStyle? = nil, children: [Node] = []) -> Node {
        Node(text: text, layoutStyle: style, children: children)
    }

    static func leaves(_ count: Int, prefix: String = "c") -> [Node] {
        (0..<count).map { Node(text: "\(prefix)\($0)") }
    }

    /// Deterministic sizes varying by text hash-like rule.
    static func sizes(for root: Node, base: CGSize = CGSize(width: 80, height: 30)) -> [UUID: CGSize] {
        var result: [UUID: CGSize] = [:]
        var index = 0
        func visit(_ node: Node) {
            result[node.id] = CGSize(width: base.width + CGFloat(index % 4) * 25,
                                     height: base.height + CGFloat(index % 3) * 22)
            index += 1
            node.children.forEach(visit)
        }
        visit(root)
        return result
    }

    static func overlappingPairs(_ frames: [UUID: CGRect]) -> Int {
        let list = Array(frames.values)
        var count = 0
        for i in list.indices {
            for j in list.indices where j > i {
                if list[i].insetBy(dx: 0.01, dy: 0.01).intersects(list[j].insetBy(dx: 0.01, dy: 0.01)) {
                    count += 1
                }
            }
        }
        return count
    }

    /// Random-ish tree with given depth and branching (deterministic).
    static func bushy(depth: Int, branching: Int, styleAt: (Int) -> LayoutStyle? = { _ in nil }) -> Node {
        func make(_ level: Int, _ label: String) -> Node {
            let kids = level >= depth ? [] : (0..<(branching - level % 2)).map { make(level + 1, "\(label).\($0)") }
            return Node(text: label, layoutStyle: styleAt(level), children: kids)
        }
        return make(0, "r")
    }
}

func approx(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.001) -> Bool {
    abs(a - b) <= tolerance
}

/// Runs `body` on a thread with an 8 MB stack (same as the main thread).
func onLargeStack<T>(_ body: @escaping () -> T) -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.value = body()
        done.signal()
    }
    thread.stackSize = 8 << 20
    thread.start()
    done.wait()
    return box.value!
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
