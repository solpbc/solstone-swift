// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import UIKit
import UserNotifications
import UserNotificationsUI
import SwiftUI

final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let headerLabel = UILabel()
    private let heroLabel = UILabel()
    private let bodyLabel = UILabel()
    private let stackView = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()

        self.view.backgroundColor = .systemBackground
        self.stackView.axis = .vertical
        self.stackView.spacing = 10
        self.stackView.translatesAutoresizingMaskIntoConstraints = false

        self.headerLabel.font = .preferredFont(forTextStyle: .headline)
        self.headerLabel.textColor = UIColor(Color.solOrangeAccessible)
        self.headerLabel.numberOfLines = 2

        self.heroLabel.font = .preferredFont(forTextStyle: .title3)
        self.heroLabel.textColor = .label
        self.heroLabel.numberOfLines = 2

        self.bodyLabel.font = .preferredFont(forTextStyle: .body)
        self.bodyLabel.textColor = .secondaryLabel
        self.bodyLabel.numberOfLines = 0

        self.stackView.addArrangedSubview(self.headerLabel)
        self.stackView.addArrangedSubview(self.heroLabel)
        self.stackView.addArrangedSubview(self.bodyLabel)
        self.view.addSubview(self.stackView)

        NSLayoutConstraint.activate([
            self.stackView.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 16),
            self.stackView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 16),
            self.stackView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -16),
            self.stackView.bottomAnchor.constraint(lessThanOrEqualTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        let userInfo = content.userInfo
        let hero = userInfo["hero"] as? String
        let sensitive = userInfo["sensitive"] as? Bool ?? false
        let bodyText = content.body.trimmingCharacters(in: .whitespacesAndNewlines)

        self.headerLabel.text = content.title
        self.heroLabel.text = hero
        self.heroLabel.isHidden = hero?.isEmpty ?? true
        self.bodyLabel.text = sensitive || bodyText.isEmpty ? "Tap to view" : content.body
    }
}
