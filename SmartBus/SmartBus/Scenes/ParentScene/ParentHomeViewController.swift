//
//  ParentHomeViewController.swift
//  SmartBus
//
//  Màn tạm cho vai trò phụ huynh, để luồng đăng nhập chạy được trọn vẹn.
//  Sẽ thay bằng màn "Các con" (GET /parent/children) ở bước sau.
//

import UIKit

final class ParentHomeViewController: UIViewController {
    private let user: AppUser

    init(user: AppUser) {
        self.user = user
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        title = "Các con"

        let greeting = UILabel()
        greeting.text = "Xin chào, \(user.fullName)"
        greeting.font = .systemFont(ofSize: 22, weight: .bold)
        greeting.textColor = Theme.ink
        greeting.numberOfLines = 0

        let note = UILabel()
        note.text = "Màn danh sách các con đang được phát triển."
        note.font = .systemFont(ofSize: 15)
        note.textColor = Theme.muted
        note.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [greeting, note])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
    }
}
