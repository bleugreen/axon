import ApplicationServices
import Foundation
import Testing
@testable import AxonCore

@Test func bulkHierarchyParserReconstructsWindowTreeFromFlatResult() {
    let app = NSString(string: "app")
    let window = NSString(string: "window")
    let group = NSString(string: "group")
    let link = NSString(string: "link")
    let navOnly = NSString(string: "nav-only")

    let result: NSDictionary = [
        app: [
            "AXRole": slot("AXApplication"),
            "AXTitle": slot("Example"),
            "AXWindows": arraySlot([window])
        ],
        window: [
            "AXRole": slot("AXWindow"),
            "AXTitle": slot("Main"),
            "AXChildren": arraySlot([group])
        ],
        group: [
            "AXRole": slot("AXGroup"),
            "AXContents": arraySlot([link, link], count: 2),
            "AXChildrenInNavigationOrder": arraySlot([navOnly])
        ],
        link: [
            "AXRole": slot("AXLink"),
            "AXTitle": slot("Read more"),
            "AXEnabled": slot(true)
        ],
        navOnly: [
            "AXRole": slot("AXButton"),
            "AXTitle": slot("Nav only")
        ]
    ]

    let parsed = AXHierarchyBulkParser().parse(result)

    #expect(parsed.windows.count == 1)
    #expect(parsed.windows[0].role == "AXWindow")
    #expect(parsed.windows[0].title == "Main")
    #expect(parsed.windows[0].children.count == 1)
    #expect(parsed.windows[0].children[0].role == "AXGroup")
    #expect(parsed.windows[0].children[0].childCount == 3)
    #expect(parsed.windows[0].children[0].children.count == 2)
    #expect(parsed.windows[0].children[0].children[0].role == "AXLink")
    #expect(parsed.windows[0].children[0].children[0].title == "Read more")
    #expect(parsed.windows[0].children[0].children[0].enabled == true)
    #expect(parsed.windows[0].children[0].children[1].role == "AXButton")
    #expect(parsed.windows[0].children[0].children[1].title == "Nav only")
}

@Test func bulkHierarchyParserFallsBackToWindowRootsWhenApplicationRootIsAbsent() {
    let window = NSString(string: "window")
    let button = NSString(string: "button")

    let result: NSDictionary = [
        window: [
            "AXRole": slot("AXWindow"),
            "AXTitle": slot("Detached"),
            "AXChildren": arraySlot([button])
        ],
        button: [
            "AXRole": slot("AXButton"),
            "AXTitle": slot("OK")
        ]
    ]

    let parsed = AXHierarchyBulkParser().parse(result)

    #expect(parsed.windows.map(\.title) == ["Detached"])
    #expect(parsed.windows[0].children.map(\.title) == ["OK"])
}

@Test func bulkHierarchyParserReadsFrameFromPositionAndSizeSlots() {
    let window = NSString(string: "window")
    var point = CGPoint(x: 12.5, y: 24.25)
    var size = CGSize(width: 300.75, height: 180.5)

    let result: NSDictionary = [
        window: [
            "AXRole": slot("AXWindow"),
            "AXPosition": slot(AXValueCreate(.cgPoint, &point)!),
            "AXSize": slot(AXValueCreate(.cgSize, &size)!)
        ]
    ]

    let parsed = AXHierarchyBulkParser().parse(result)

    #expect(parsed.windows.first?.frame == AXFrame(x: 12.5, y: 24.25, width: 300.75, height: 180.5))
}

private func slot(_ value: Any) -> NSDictionary {
    ["value": value]
}

private func arraySlot(_ value: [Any], count: Int? = nil) -> NSDictionary {
    var slot: [String: Any] = ["value": value]
    if let count {
        slot["count"] = count
    }
    return slot as NSDictionary
}
