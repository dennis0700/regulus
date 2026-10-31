import Foundation

/// 带「固定位置」项的拖拽排序 / Drag reordering with items whose position is fixed.
public enum FixedPositions {
    /// 移动 source 里的项到 destination（与 `Array.move(fromOffsets:toOffset:)` 同义），固定的项留在原来的下标上，
    /// 不会被挤开；source 里的固定项不移动
    /// Move the items in source to destination (as `Array.move(fromOffsets:toOffset:)`), keeping fixed items at their
    /// original indices so nothing pushes them aside; fixed items in source are not moved.
    ///
    /// # Examples
    /// ```
    /// // B 固定在下标 1；把 D 拖到最前 / B is fixed at index 1; drag D to the front
    /// FixedPositions.move(["A", "B", "C", "D"], from: [3], to: 0) { $0 == "B" }   // ["D", "B", "A", "C"]
    /// ```
    public static func move<Item>(_ items: [Item], from source: IndexSet, to destination: Int,
                                  isFixed: (Item) -> Bool) -> [Item] {
        let fixed = items.indices.filter { isFixed(items[$0]) }
        let moving = source.filter { !isFixed(items[$0]) }
        // 同 Array.move(fromOffsets:toOffset:)（那是 SwiftUI 的，core 不依赖 SwiftUI）：先取出要移动的，
        // 插到 destination 之前剩下的那些后面 / as Array.move(fromOffsets:toOffset:) (a SwiftUI API; core doesn't
        // depend on SwiftUI): take the moved items out and insert them after the remaining ones before destination
        let remaining = items.indices.filter { !moving.contains($0) }
        let insertAt = remaining.filter { $0 < destination }.count
        var moved = remaining.map { items[$0] }
        moved.insert(contentsOf: moving.map { items[$0] }, at: insertAt)
        var result = moved.filter { !isFixed($0) }
        // 从小到大放回原下标，前面的放好后后面的下标仍然对 / reinsert in ascending order so later indices stay valid
        for index in fixed { result.insert(items[index], at: min(index, result.count)) }
        return result
    }
}
