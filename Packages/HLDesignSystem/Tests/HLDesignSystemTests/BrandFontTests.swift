import CoreText
import Foundation
import Testing
@testable import HLDesignSystem

@Suite("Font Be Vietnam Pro")
struct BrandFontTests {
    @Test("Đóng gói weight token dùng (600, 700) và bậc Chữ đậm (800)")
    func bundlesUsedWeightsAndBoldTextStep() {
        #expect(HLBrandFontFiles.postScriptNames
            == ["BeVietnamPro-Bold", "BeVietnamPro-ExtraBold", "BeVietnamPro-SemiBold"])
        #expect(HLBrandFonts.fontURLs.count == 3)
    }

    @Test("Chữ đậm tăng một bậc weight: SemiBold → Bold, Bold → ExtraBold")
    func boldTextStepsUpOneWeight() {
        #expect(HLTextStyle.brandTitle.spec.brandPostScriptName(boldText: false) == "BeVietnamPro-SemiBold")
        #expect(HLTextStyle.brandTitle.spec.brandPostScriptName(boldText: true) == "BeVietnamPro-Bold")
        #expect(HLTextStyle.brandLargeTitle.spec.brandPostScriptName(boldText: true) == "BeVietnamPro-ExtraBold")
        #expect(HLTextStyle.wordmark.spec.brandPostScriptName(boldText: true) == "BeVietnamPro-ExtraBold")
        #expect(HLTextStyle.macBody.spec.brandPostScriptName(boldText: true) == nil)
    }

    @Test("Tên PostScript trong file font khớp tên sinh ra")
    func fontFilesDeclareExpectedPostScriptNames() {
        for (url, expected) in zip(HLBrandFonts.fontURLs, HLBrandFontFiles.postScriptNames) {
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
            let names = descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
            #expect(names == [expected], "\(url.lastPathComponent)")
        }
    }

    @Test("Đăng ký được và CoreText tạo đúng font theo tên PostScript")
    func registersFontsWithCoreText() {
        #expect(HLBrandFonts.registerIfNeeded())
        #expect(HLBrandFonts.registerIfNeeded()) // gọi lại vẫn an toàn
        for name in HLBrandFontFiles.postScriptNames {
            let font = CTFontCreateWithName(name as CFString, 20, nil)
            #expect(CTFontCopyPostScriptName(font) as String == name)
            let family = CTFontCopyFamilyName(font) as String
            #expect(family == "Be Vietnam Pro")
        }
    }

    @Test("Giấy phép OFL đi kèm font trong bundle")
    func bundlesOpenFontLicense() throws {
        let url = try #require(Bundle.module.url(forResource: "OFL", withExtension: "txt", subdirectory: "Fonts"))
        let license = try String(contentsOf: url, encoding: .utf8)
        #expect(license.contains("SIL Open Font License, Version 1.1"))
    }
}
