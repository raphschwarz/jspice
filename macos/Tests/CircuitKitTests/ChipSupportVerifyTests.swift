@testable import CircuitKit
import XCTest

/// A downloaded toolchain is installed only when its checksum in the package index says it is the archive the index
/// names: anything that cannot be checked is refused, as is an archive not served over https.
final class ChipSupportVerifyTests: XCTestCase {
    let data = Data("abc".utf8)
    /// SHA-256 of "abc"
    let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func archive(_ checksum: String, url: String = "https://downloads.arduino.cc/tools/avr-gcc.tar.bz2") -> ChipSupport.Archive {
        ChipSupport.Archive(name: "avr-gcc", version: "7.3.0", url: URL(string: url)!, checksum: checksum, size: 3)
    }

    func testAnArchiveMatchingItsSHA256IsTaken() throws {
        XCTAssertNoThrow(try ChipSupport.verify(data, archive("SHA-256:" + digest)))
        XCTAssertNoThrow(try ChipSupport.verify(data, archive("sha-256:" + digest.uppercased())))
    }

    func testAnArchiveThatDiffersIsRefused() {
        XCTAssertThrowsError(try ChipSupport.verify(Data("abd".utf8), archive("SHA-256:" + digest))) { error in
            guard case .checksum = error as? ChipSupport.InstallError else { return XCTFail("\(error)") }
        }
    }

    /// These were taken unchecked
    func testAnArchiveWhoseChecksumCannotBeCheckedIsRefused() {
        for checksum in ["MD5:900150983cd24fb0d6963f7d28e17f72", "SHA-1:a9993e364706816aba3e25717850c26c9cd0d89d", "", digest,
                         "SHA-256:", "SHA-256:" + String(digest.dropLast()), "SHA-256:" + String(digest.dropLast()) + "g", "SHA-256:" + digest + "00"] {
            XCTAssertThrowsError(try ChipSupport.verify(data, archive(checksum)), checksum) { error in
                guard case .unverifiable = error as? ChipSupport.InstallError else { return XCTFail("\(checksum): \(error)") }
                XCTAssertTrue("\(error)".contains("not installed"), "\(error)")
            }
        }
    }

    func testAnArchiveNotServedOverHTTPSIsRefused() throws {
        let entry: [String: Any] = ["url": "http://downloads.arduino.cc/tools/avr-gcc.tar.bz2", "checksum": "SHA-256:" + digest,
                                    "size": "3"]
        XCTAssertThrowsError(try ChipSupport.archive(entry, name: "avr-gcc")) { error in
            XCTAssertTrue("\(error)".contains("https"), "\(error)")
        }
        var secure = entry
        secure["url"] = "https://downloads.arduino.cc/tools/avr-gcc.tar.bz2"
        XCTAssertEqual(try ChipSupport.archive(secure, name: "avr-gcc")?.size, 3)
    }
}
