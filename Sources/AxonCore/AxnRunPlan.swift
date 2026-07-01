import Foundation

struct PreparedAxnRun {
    let axn: Axn
    let actions: [PreparedAxnAction]
}

struct PreparedAxnAction {
    let index: Int
    let action: AxnAction
    let secretTaintedFields: Set<String>
}
