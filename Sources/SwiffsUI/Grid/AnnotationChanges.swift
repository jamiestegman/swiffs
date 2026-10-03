import SwiffsCore

/// The annotation keys whose annotations differ between `old` and `new`, or
/// nil when annotations cannot be compared (their metadata is not
/// `Equatable`), so every annotation view is rebuilt.
func changedAnnotationKeys<Annotation>(_ old: [AnnotationKey: [Annotation]], _ new: [AnnotationKey: [Annotation]]) -> Set<AnnotationKey>? {
    guard let comparable = Annotation.self as? any Equatable.Type else { return nil }
    return changedKeys(as: comparable, old, new)
}

private func changedKeys<Comparable: Equatable, Annotation>(
    as _: Comparable.Type, _ old: [AnnotationKey: [Annotation]], _ new: [AnnotationKey: [Annotation]]
) -> Set<AnnotationKey> {
    Set(Set(old.keys).union(new.keys).filter { key in
        (old[key] ?? []) as! [Comparable] != (new[key] ?? []) as! [Comparable]
    })
}
