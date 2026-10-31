/// 框选时选择集合的合并方式，与 Finder 一致 / How a marquee combines with the existing selection, as in Finder.
public enum MarqueeMode: Sendable, Equatable {
    /// 普通拖动：只选框内的 / Plain drag: select only what is inside the box.
    case replace
    /// ⇧ 拖动：加到原有选择上 / ⇧-drag: add to the existing selection.
    case add
    /// ⌘ 拖动：框内的项目反选 / ⌘-drag: toggle the items inside the box.
    case toggle

    /// 由拖动开始时的选择 `base` 和框住的项目 `hits` 得到新的选择
    /// The new selection from the selection at drag start (`base`) and the items under the box (`hits`).
    ///
    /// # Examples
    /// ```
    /// MarqueeMode.toggle.apply(base: [1, 2], hits: [2, 3])   // [1, 3]
    /// ```
    public func apply<T: Hashable>(base: Set<T>, hits: Set<T>) -> Set<T> {
        switch self {
        case .replace: hits
        case .add: base.union(hits)
        case .toggle: base.symmetricDifference(hits)
        }
    }
}
