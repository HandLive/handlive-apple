import Foundation
import Testing
@testable import HLDesignSystem

@Suite("Brand mark (welcome screen)")
struct BrandMarkTests {
    @Test("brand-mark, behind HLBrandMark, is a vector imageset with a light and a dark PDF, both present")
    func imageset() throws {
        let set = RepositoryPaths.imageCatalog.appendingPathComponent("brand-mark.imageset")
        let data = try Data(contentsOf: set.appendingPathComponent("Contents.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let images = try #require(json["images"] as? [[String: Any]])
        let files = images.compactMap { $0["filename"] as? String }
        #expect(files.count == 2 && files.allSatisfy { $0.hasSuffix(".pdf") })
        for file in files {
            #expect(FileManager.default.fileExists(atPath: set.appendingPathComponent(file).path))
        }
        let dark = images.filter { image in
            (image["appearances"] as? [[String: String]])?.contains { $0["value"] == "dark" } == true
        }
        #expect(dark.count == 1)
        let properties = json["properties"] as? [String: Any]
        #expect(properties?["preserves-vector-representation"] as? Bool == true)
    }
}
