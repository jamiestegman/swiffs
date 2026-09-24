import Testing
@testable import SwiffsCore

struct LineHelpersTests {
    @Test func parsesLineTypes() {
        #expect(parseLineType("+a") == ParsedLine(line: "a", type: .addition))
        #expect(parseLineType("-a") == ParsedLine(line: "a", type: .deletion))
        #expect(parseLineType(" a") == ParsedLine(line: "a", type: .context))
        #expect(parseLineType("\\ No newline at end of file") == ParsedLine(line: " No newline at end of file", type: .metadata))
        #expect(parseLineType("+") == ParsedLine(line: "\n", type: .addition))
        #expect(parseLineType("x") == nil)
        #expect(parseLineType("") == nil)
    }

    @Test func annotationNames() {
        #expect(getLineAnnotationName(LineAnnotation(lineNumber: 4, metadata: ())) == "annotation-4")
        #expect(getLineAnnotationName(DiffLineAnnotation(side: .deletions, lineNumber: 2, metadata: ())) == "annotation-deletions-2")
    }
}
