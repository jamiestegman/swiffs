import Foundation
import Testing
@testable import SwiffsCore

struct MiscParityTests {
    struct Misc: Decodable {
        var filetypes: [[String]]
    }

    @Test func filetypesMatchUpstream() throws {
        let misc = try Fixtures.load("misc.json", as: Misc.self)
        #expect(misc.filetypes.count > 500)
        for entry in misc.filetypes {
            #expect(getFiletypeFromFileName(entry[0]) == entry[1], "\(entry[0])")
        }
    }
}
