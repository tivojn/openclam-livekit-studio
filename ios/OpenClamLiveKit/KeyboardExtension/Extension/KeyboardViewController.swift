import SwiftUI
import UIKit

@MainActor
final class KeyboardViewController: UIInputViewController {
    override var hasDictationKey: Bool {
        // OpenClam owns the visible voice action. iOS still prevents the extension itself from
        // recording; the foreground-started app lease performs provider recognition instead.
        get { true }
        set {}
    }

    private lazy var keyboardModel = OpenClamKeyboardViewModel(
        insertText: { [weak self] text in
            self?.commitMarkedTextThen {
                self?.textDocumentProxy.insertText(text)
            }
        },
        contextBeforeInput: { [weak self] in
            self?.textDocumentProxy.documentContextBeforeInput
        }
    )

    private var hostingController: UIHostingController<OpenClamKeyboardView>?
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()

        let keyboard = OpenClamKeyboardView(
            model: keyboardModel,
            performPrimaryAction: { [weak self] in
                self?.keyboardModel.performPrimaryAction()
            },
            showInputModeList: { [weak self] button, event in
                self?.handleInputModeList(from: button, with: event)
            },
            deleteBackward: { [weak self] in
                self?.commitMarkedTextThen {
                    self?.textDocumentProxy.deleteBackward()
                }
            },
            insertSpace: { [weak self] in
                self?.commitMarkedTextThen {
                    self?.textDocumentProxy.insertText(" ")
                }
            },
            insertReturn: { [weak self] in
                self?.commitMarkedTextThen {
                    self?.textDocumentProxy.insertText("\n")
                }
            }
        )
        let hostingController = UIHostingController(rootView: keyboard)
        self.hostingController = hostingController
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hostingController.didMove(toParent: self)

        let height = view.heightAnchor.constraint(equalToConstant: 232)
        height.priority = .defaultHigh
        height.isActive = true
        heightConstraint = height
        keyboardModel.updateFullAccess(hasFullAccess)
        updateKeyboardTraitsAndHeight()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keyboardModel.updateFullAccess(hasFullAccess)
        keyboardModel.startPolling()
    }

    override func viewDidDisappear(_ animated: Bool) {
        keyboardModel.stopPolling()
        super.viewDidDisappear(animated)
    }

    override func textWillChange(_ textInput: (any UITextInput)?) {
        super.textWillChange(textInput)
        keyboardModel.updateFullAccess(hasFullAccess)
        updateKeyboardTraitsAndHeight()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateKeyboardTraitsAndHeight()
    }

    private func updateKeyboardTraitsAndHeight() {
        let compact = traitCollection.verticalSizeClass == .compact
        let accessibilitySize = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        keyboardModel.updateKeyboardTraits(
            showsInputModeSwitchKey: needsInputModeSwitchKey,
            returnKeyLabel: Self.returnKeyLabel(for: textDocumentProxy.returnKeyType),
            compactLayout: compact
        )

        let targetHeight: CGFloat
        if compact {
            targetHeight = accessibilitySize ? 210 : 132
        } else {
            targetHeight = accessibilitySize ? 282 : 196
        }
        if let heightConstraint,
           abs(heightConstraint.constant - targetHeight) > 0.5 {
            heightConstraint.constant = targetHeight
        }
    }

    private static func returnKeyLabel(for keyType: UIReturnKeyType?) -> String {
        switch keyType {
        case .done: "Done"
        case .go: "Go"
        case .join: "Join"
        case .next: "Next"
        case .search, .google, .yahoo: "Search"
        case .send: "Send"
        case .continue: "Continue"
        case .route: "Route"
        case .emergencyCall: "Emergency"
        default: "Return"
        }
    }

    private func commitMarkedTextThen(_ mutation: () -> Void) {
        OpenClamKeyboardTextMutation.commitMarkedTextThen(
            mutation,
            unmarkText: { [weak self] in self?.textDocumentProxy.unmarkText() }
        )
    }
}
