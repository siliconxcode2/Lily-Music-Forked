import Foundation
import Testing
@testable import YTMCore

@Suite struct JSONTests {
    private let json = (try? JSON(data: Data(#"""
    {"a":{"b":[1,{"c":"x"},null]},"one":{"r":{"k":true}},"runs":{"runs":[{"text":"Hi "},{"text":"there"}]},"two":{"x":1,"y":2}}
    """#.utf8))) ?? .missing

    @Test func walksFoundationContainers() {
        #expect(json["a", "b"][0].int == 1)
        #expect(json["a", "b"][1]["c"].string == "x")
        #expect(!json["a", "b"][2].exists, "null reads as missing")
        #expect(!json["a", "b"][3].exists && !json["a", "b"][-1].exists, "out of bounds")
        #expect(json["a", "b"].array.count == 3)
        #expect(json["runs", "runs"].last["text"].string == "there")
        #expect(!json["a"].last.exists, "an object has no last element")
        #expect(json["a"].isObject && !json["a"].isArray && json["a", "b"].isArray)
    }

    @Test func readsWrappersAndText() {
        #expect(json["one"].onlyValue?.key == "r")
        #expect(json["one"].onlyValue?.value["k"].bool == true)
        #expect(json["two"].onlyValue == nil, "two keys aren't a wrapper")
        #expect(json["runs"].text == "Hi there")
        #expect(json["a", "b"][1]["c"].text == "x", "a plain string is its own text")
        #expect(json.first("missing", "two")["y"].int == 2)
    }
}
