//
//  PreviewViewController.swift
//  ownCloud
//
//  Created by Michael Neuwert on 27.08.2019.
//  Copyright © 2019 ownCloud GmbH. All rights reserved.
//

import UIKit
import ownCloudSDK
import QuickLook

class PreviewViewController : DisplayViewController, QLPreviewControllerDataSource, QLPreviewControllerDelegate {

	private var qlPreviewController: QLPreviewController?
	var tapToHideBarsGestureRecognizer: UITapGestureRecognizer!

	override func viewSafeAreaInsetsDidChange() {
		super.viewSafeAreaInsetsDidChange()

		if let qlPreviewController = self.qlPreviewController {
			qlPreviewController.view.translatesAutoresizingMaskIntoConstraints = false

			NSLayoutConstraint.activate([
				qlPreviewController.view.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor),
				qlPreviewController.view.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor),
				qlPreviewController.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
				qlPreviewController.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor)
				])
		}

		self.view.layoutIfNeeded()
	}

	override func renderSpecificView(completion: @escaping (Bool) -> Void) {
		if source != nil {
			qlPreviewController = QLPreviewController()
			addChild(qlPreviewController!)
			qlPreviewController!.view.frame = self.view.bounds
			self.view.addSubview(qlPreviewController!.view)
			qlPreviewController!.didMove(toParent: self)

			qlPreviewController?.dataSource = self

			qlPreviewController?.reloadData()

			self.tapToHideBarsGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.tapToHideBars))
			self.qlPreviewController?.view?.addGestureRecognizer(self.tapToHideBarsGestureRecognizer)

			completion(true)
		} else {
			completion(false)
		}
	}

	@objc func tapToHideBars() {
		guard let navigationController = navigationController else {
			return
		}

		if !navigationController.isNavigationBarHidden {
			navigationController.setNavigationBarHidden(true, animated: true)
		} else {
			navigationController.setNavigationBarHidden(false, animated: true)
		}

		setNeedsUpdateOfHomeIndicatorAutoHidden()
	}

	// MARK: - QLPreviewControllerDataSource
	func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
		return source != nil ? 1 : 0
	}

	// MARK: - QLPreviewControllerDelegate
	func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
		return source! as QLPreviewItem
	}

	@available(iOS 13.0, *)
	func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
		// Return .updateContents so QLPreviewController takes care of updating the contents of the provided QLPreviewItems whenever users save changes.
		return .updateContents
	}
}

// MARK: - Display Extension.
extension PreviewViewController: DisplayExtension {

	static var customMatcher: OCExtensionCustomContextMatcher? = { (context, defaultPriority) in
		do {
			if let mimeType = context.location?.identifier?.rawValue {
				let supportedFormatsRegex = try NSRegularExpression(pattern: "\\A((text/)|(application/octet-stream)|(model/(vnd|usd))|application/(rtf|x-rtf|doc)|(application/x-iwork*)|(image/(?!(gif|svg*)))|(application/(vnd.|ms))(?!(oasis|android))(ms|openxmlformats)?)", options: .caseInsensitive)
				let matches = supportedFormatsRegex.numberOfMatches(in: mimeType, options: .reportCompletion, range: NSRange(location: 0, length: mimeType.count))

				if matches > 0 {
					return OCExtensionPriority.locationMatch
				}
			}

			return OCExtensionPriority.noMatch
		} catch {
			return OCExtensionPriority.noMatch
		}
	}

	static var supportedMimeTypes: [String]?
	static var displayExtensionIdentifier: String = "org.owncloud.ql_preview"
	static var features: [String : Any]? = [FeatureKeys.canEdit : false]
}
