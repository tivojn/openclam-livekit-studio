import SwiftUI
import UIKit

@MainActor
final class KeyboardViewController: UIInputViewController {
    override var hasDictationKey: Bool {
        get { true }
        set {}
    }

    private lazy var keyboardModel = OpenClamKeyboardViewModel(
        insertText: { [weak self] text in
            self?.textDocumentProxy.unmarkText()
            self?.textDocumentProxy.insertText(text)
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
            beginVoiceInput: { [weak self] in self?.beginVoiceInput() },
            advanceKeyboard: { [weak self] in self?.advanceToNextInputMode() },
            deleteBackward: { [weak self] in
                self?.textDocumentProxy.unmarkText()
                self?.textDocumentProxy.deleteBackward()
            },
            insertSpace: { [weak self] in
                self?.textDocumentProxy.unmarkText()
                self?.textDocumentProxy.insertText(" ")
            },
            insertReturn: { [weak self] in
                self?.textDocumentProxy.unmarkText()
                self?.textDocumentProxy.insertText("\n")
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

        let height = view.heightAnchor.constraint(equalToConstant: 248)
        height.priority = .defaultHigh
        height.isActive = true
        heightConstraint = height
        keyboardModel.updateFullAccess(hasFullAccess)
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
    }

    private func beginVoiceInput() {
        keyboardModel.beginVoiceInput()
    }
}
