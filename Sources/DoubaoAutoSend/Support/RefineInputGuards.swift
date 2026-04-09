import Foundation

func containsRefineAttachmentPlaceholder(_ text: String) -> Bool {
    text.range(
        of: #"\[Image #\d+\]"#,
        options: [.regularExpression, .caseInsensitive]
    ) != nil
}
