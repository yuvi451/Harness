import XCTest
@testable import HarnessCore
@testable import HarnessEmitter
final class SettingsInputTests: XCTestCase {
    func testMaskInputIsStrictAndBounded() throws {
        XCTAssertEqual(try SettingsInputParser.masks("0.1, 0.2, 0.3, 0.4\n"), [.init(x:0.1,y:0.2,width:0.3,height:0.4)])
        XCTAssertEqual(try SettingsInputParser.masks(""), [])
        for text in ["nan,0,0.1,0.1", "0,0,-1,1", "0.9,0,0.2,0.1", "0,0,1", "0,0,1,1,1", String(repeating:"0,0,1,1\n",count:33)] {
            XCTAssertThrowsError(try SettingsInputParser.masks(text))
        }
    }
    func testNumericFieldsRejectNonIntegersAndWhitespaceSanitize() throws {
        XCTAssertEqual(try SettingsInputParser.integer(" 1568 ", range:64...1568),1568)
        for text in ["true","1.2","nan", "999999999999999999999999999"] {
            XCTAssertThrowsError(try SettingsInputParser.integer(text,range:64...1568))
        }
    }
}
