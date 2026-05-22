//
//  AppSettingsDirectoryTreeTests.swift
//  LineyTests
//
//  Author: everettjf
//

import XCTest
@testable import Liney

final class AppSettingsDirectoryTreeTests: XCTestCase {
    func testDefaultsToEnabled() {
        XCTAssertTrue(AppSettings().directoryTreeEnabled)
    }

    func testRoundTrips() throws {
        var settings = AppSettings()
        settings.directoryTreeEnabled = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(decoded.directoryTreeEnabled)
    }

    func testLegacySettingsWithoutKeyDefaultToEnabled() throws {
        // Settings persisted before this flag existed must default to on.
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(decoded.directoryTreeEnabled)
    }
}
