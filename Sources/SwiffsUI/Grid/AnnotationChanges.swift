import SwiffsCore

/// The annotation keys whose annotations differ between `old` and `new`, or
/// nil when annotations cannot be compared (their metadata is not
/// `Equatable`), so every annotation view is rebuilt.
func changedAnnotationKeys<Annotation>(_ old: [AnnotationKey: [Annotation]], _ new: [AnnotationKey: [Annotation]]) -> Set<AnnotationKey>? {
    var changed: Set<AnnotationKey> = []
    for key in Set(old.keys).union(new.keys) {
        guard let same = equal(old[key] ?? [], new[key] ?? []) else { return nil }
        if !same { changed.insert(key) }
    }
    return changed
}

private func equal<Annotation>(_ a: [Annotation], _ b: [Annotation]) -> Bool? {
    guard let a = a as? any Equatable else { return nil }
    return isEqual(a, b)
}

private func isEqual<T: Equatable>(_ a: T, _ b: Any) -> Bool {
    (b as? T) == a
}
