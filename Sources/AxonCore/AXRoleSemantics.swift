enum AXRoleSemantics {
    static let editableTextRoles: Set<String> = [
        "AXComboBox",
        "AXTextArea",
        "AXTextField"
    ]

    static func isEditableTextRole(_ role: String) -> Bool {
        editableTextRoles.contains(role)
    }
}
