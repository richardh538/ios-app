//
//  LibraryTableViewController.swift
//  ownCloud
//
//  Created by Matthias Hühne on 12.05.19.
//  Copyright © 2019 ownCloud GmbH. All rights reserved.
//

/*
 * Copyright (C) 2019, ownCloud GmbH.
 *
 * This code is covered by the GNU Public License Version 3.
 *
 * For distribution utilizing Apple mechanisms please see https://owncloud.org/contribute/iOS-license-exception/
 * You should have received a copy of this license along with this program. If not, see <http://www.gnu.org/licenses/gpl-3.0.en.html>.
 *
 */

import UIKit
import ownCloudSDK
import ownCloudAppShared

protocol LibraryShareList: UIViewController {
	func updateWith(shares: [OCShare])
}

struct QuickAccessQuery {
	var name : String
	var mimeType : [String]
	var imageName : String
}

class LibraryShareView {
	enum Identifier : String {
		case sharedWithYou
		case sharedWithOthers
		case publicLinks
		case pending
	}

	var identifier : Identifier

	var title : String
	var image : UIImage

	var showBadge : Bool {
		return identifier == .pending
	}

	var viewController : LibraryShareList?

	var row : StaticTableViewRow?

	var shares : [OCShare]?

	init(identifier: LibraryShareView.Identifier, title: String, image: UIImage) {
		self.identifier = identifier

		self.title = title
		self.image = image
	}
}

class LibraryTableViewController: StaticTableViewController {

	weak var core : OCCore?

	deinit {
		for applierToken in applierTokens {
			Theme.shared.remove(applierForToken: applierToken)
		}

		self.stopQueries()
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		self.title = "Quick Access".localized
		self.navigationController?.navigationBar.prefersLargeTitles = true
		self.tableView.contentInset.bottom = self.tabBarController?.tabBar.frame.height ?? 0

		Theme.shared.add(tvgResourceFor: "icon-available-offline")

		shareSection = StaticTableViewSection(headerTitle: "Shares".localized, footerTitle: nil, identifier: "share-section")
		self.addThemableBackgroundView()
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		self.navigationController?.navigationBar.prefersLargeTitles = true
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		self.navigationController?.navigationBar.prefersLargeTitles = false
	}

	// MARK: - Share setup
	var startedQueries : [OCCoreQuery] = []

	var shareQueryWithUser : OCShareQuery?
	var shareQueryByUser : OCShareQuery?
	var shareQueryAcceptedCloudShares : OCShareQuery?
	var shareQueryPendingCloudShares : OCShareQuery?
	private var applierTokens : [ThemeApplierToken] = []

	private func start(query: OCCoreQuery) {
		core?.start(query)
		startedQueries.append(query)
	}

	func reloadQueries() {
		for query in startedQueries {
			core?.reload(query)
		}
	}

	private func stopQueries() {
		for query in startedQueries {
			core?.stop(query)
		}
		startedQueries.removeAll()
	}

	func setupQueries() {
		// Shared with user
		shareQueryWithUser = OCShareQuery(scope: .sharedWithUser, item: nil)

		if let shareQueryWithUser = shareQueryWithUser {
			shareQueryWithUser.refreshInterval = 60

			shareQueryWithUser.initialPopulationHandler = { [weak self] (_) in
				self?.updateSharedWithYouResult()
				self?.updatePendingSharesResult()
			}
			shareQueryWithUser.changesAvailableNotificationHandler = shareQueryWithUser.initialPopulationHandler

			start(query: shareQueryWithUser)
		}

		// Accepted cloud shares
		shareQueryAcceptedCloudShares = OCShareQuery(scope: .acceptedCloudShares, item: nil)

		if let shareQueryAcceptedCloudShares = shareQueryAcceptedCloudShares {
			shareQueryAcceptedCloudShares.refreshInterval = 60

			shareQueryAcceptedCloudShares.initialPopulationHandler = { [weak self] (_) in
				self?.updateSharedWithYouResult()
				self?.updatePendingSharesResult()
			}
			shareQueryAcceptedCloudShares.changesAvailableNotificationHandler = shareQueryAcceptedCloudShares.initialPopulationHandler

			start(query: shareQueryAcceptedCloudShares)
		}

		// Pending cloud shares
		shareQueryPendingCloudShares = OCShareQuery(scope: .pendingCloudShares, item: nil)

		if let shareQueryPendingCloudShares = shareQueryPendingCloudShares {
			shareQueryPendingCloudShares.refreshInterval = 60

			shareQueryPendingCloudShares.initialPopulationHandler = { [weak self] (query) in
				if let library = self {
					library.pendingCloudSharesCounter = query.queryResults.count
					self?.updatePendingSharesResult()
				}
			}
			shareQueryPendingCloudShares.changesAvailableNotificationHandler = shareQueryPendingCloudShares.initialPopulationHandler

			start(query: shareQueryPendingCloudShares)
		}

		// Shared by user
		shareQueryByUser = OCShareQuery(scope: .sharedByUser, item: nil)

		if let shareQueryByUser = shareQueryByUser {
			shareQueryByUser.refreshInterval = 60

			shareQueryByUser.initialPopulationHandler = { [weak self] (_) in
				self?.updateSharedByUserResults()
			}
			shareQueryByUser.changesAvailableNotificationHandler = shareQueryByUser.initialPopulationHandler

			start(query: shareQueryByUser)
		}

		setupViews()
		setupCollectionSection()
	}

	// MARK: - Share views
	var viewsByIdentifier : [LibraryShareView.Identifier : LibraryShareView] = [ : ]

	func add(view: LibraryShareView) {
		viewsByIdentifier[view.identifier] = view
	}

	func setupViews() {
		self.add(view: LibraryShareView(identifier: .sharedWithOthers, title: "Shared with others".localized, image: UIImage(named: "group")!))
		self.add(view: LibraryShareView(identifier: .sharedWithYou, title: "Shared with you".localized, image: UIImage(named: "group")!))
		self.add(view: LibraryShareView(identifier: .publicLinks, title: "Public Links".localized, image: UIImage(named: "link")!))
		self.add(view: LibraryShareView(identifier: .pending, title: "Pending Invites".localized, image: UIImage(named: "group")!))
	}

	func updateView(identifier: LibraryShareView.Identifier, with shares: [OCShare]?, badge: Int? = 0) {
		if let view = viewsByIdentifier[identifier] {
			let shares = shares ?? []

			view.shares = shares
			view.viewController?.updateWith(shares: shares)

			if shares.count > 0 {
				if view.row == nil, let core = core {
					var badgeLabel : RoundedLabel?

					if view.showBadge, let badge = badge {
						badgeLabel = RoundedLabel(text: "\(badge)", style: .token)
						badgeLabel?.isHidden = (badge == 0)
					}

					view.row = StaticTableViewRow(rowWithAction: { [weak self, weak view] (_, _) in
						guard let view = view else { return }

						var viewController : LibraryShareList? = view.viewController

						if viewController == nil {
							if view.identifier == .pending {
								let pendingSharesController = PendingSharesTableViewController(style: .grouped)

								pendingSharesController.title = view.title
								pendingSharesController.core = core
								pendingSharesController.libraryViewController = self

								viewController = pendingSharesController
							} else {
								let sharesFileListController = LibrarySharesTableViewController(core: core)

								sharesFileListController.title = view.title

								viewController = sharesFileListController
							}

							view.viewController = viewController
						}

						if let viewController = viewController {
							viewController.updateWith(shares: view.shares ?? [])

							self?.navigationController?.pushViewController(viewController, animated: true)
						}
					}, title: view.title, image: view.image, accessoryType: .disclosureIndicator, accessoryView: badgeLabel, identifier: identifier.rawValue)

					if let row = view.row {
						shareSection?.add(row: row, animated: true)
					}
				} else if view.showBadge, let badge = badge {
					guard let accessoryView = view.row?.additionalAccessoryView as? RoundedLabel else { return }

					accessoryView.labelText = "\(badge)"
					accessoryView.isHidden = (badge == 0)
				}
			} else {
				if let row = view.row {
					shareSection?.remove(rows: [row], animated: true)
					view.row = nil
				}
			}

			self.updateShareSectionVisibility()
		}
	}

	// MARK: - Handle sharing updates
	var pendingSharesCounter : Int = 0 {
		didSet {
			OnMainThread {
				if self.pendingSharesCounter > 0 {
					self.navigationController?.tabBarItem.badgeValue = String(self.pendingSharesCounter)
				} else {
					self.navigationController?.tabBarItem.badgeValue = nil
				}
			}
		}
	}
	var pendingLocalSharesCounter : Int = 0 {
		didSet {
			pendingSharesCounter = pendingCloudSharesCounter + pendingLocalSharesCounter
		}
	}
	var pendingCloudSharesCounter : Int = 0 {
		didSet {
			pendingSharesCounter = pendingCloudSharesCounter + pendingLocalSharesCounter
		}
	}

	func updateSharedWithYouResult() {
		var shareResults : [OCShare] = []

		if let queryResults = shareQueryWithUser?.queryResults {
			shareResults.append(contentsOf: queryResults)
		}

		if let queryResults = shareQueryAcceptedCloudShares?.queryResults {
			shareResults.append(contentsOf: queryResults)
		}

		let uniqueShares = shareResults.unique { $0.itemPath }

		let sharedWithUserAccepted = uniqueShares.filter({ (share) -> Bool in
			return ((share.type == .remote) && (share.accepted == true)) ||
			       ((share.type != .remote) && (share.state == .accepted))
		})

		OnMainThread {
			self.updateView(identifier: .sharedWithYou, with: sharedWithUserAccepted)
		}
	}

	func updatePendingSharesResult() {
		var shareResults : [OCShare] = []

		if let queryResults = shareQueryWithUser?.queryResults {
			shareResults.append(contentsOf: queryResults)
		}
		if let queryResults = shareQueryPendingCloudShares?.queryResults {
			shareResults.append(contentsOf: queryResults)
		}

		let sharedWithUserPending = shareResults.filter({ (share) -> Bool in
			return ((share.type == .remote) && (share.accepted == false)) ||
			       ((share.type != .remote) && (share.state != .accepted))
		})
		pendingLocalSharesCounter = sharedWithUserPending.filter({ (share) -> Bool in
			return (share.type != .remote) && (share.state == .pending)
		}).count

		OnMainThread {
			self.updateView(identifier: .pending, with: sharedWithUserPending, badge: self.pendingSharesCounter)
		}
	}

	func updateSharedByUserResults() {
		guard let shares = shareQueryByUser?.queryResults else { return}

		let sharedByUserLinks = shares.filter({ (share) -> Bool in
			return share.type == .link
		})

		let sharedByUser = shares.filter({ (share) -> Bool in
			return share.type != .link
		})

		OnMainThread {
			self.updateView(identifier: .sharedWithOthers, with: sharedByUser.unique { $0.itemPath })
			self.updateView(identifier: .publicLinks, with: sharedByUserLinks.unique { $0.itemPath })
		}
	}

	// MARK: - Sharing Section Updates
	var shareSection : StaticTableViewSection?

	func updateShareSectionVisibility() {
		if let shareSection = shareSection {
			if shareSection.rows.count > 0 {
				if !shareSection.attached {
					self.insertSection(shareSection, at: 0, animated: false)
				}
			} else {
				if shareSection.attached {
					self.removeSection(shareSection, animated: false)
				}
			}
		}
	}

	// MARK: - Collection Section
	func setupCollectionSection() {
		if self.sectionForIdentifier("collection-section") == nil {
			let section = StaticTableViewSection(headerTitle: "Collection".localized, footerTitle: nil, identifier: "collection-section")
			self.addSection(section)

			addCollectionRow(to: section, title: "Recents".localized, image: UIImage(named: "recents")!, queryCreator: {
				let lastWeekDate = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: Date())!

				var recentsQuery = OCQuery(condition: .require([
					.where(.lastUsed, isGreaterThan: lastWeekDate),
					.where(.name, isNotEqualTo: "/")
				]), inputFilter:nil)

				if let condition = OCQueryCondition.fromSearchTerm(":1w :file") {
					recentsQuery = OCQuery(condition:condition, inputFilter: nil)
				}

				return recentsQuery
			}, actionHandler: nil)

			addCollectionRow(to: section, title: "Favorites".localized, image: UIImage(named: "star")!, queryCreator: {
				return OCQuery(condition: .where(.isFavorite, isEqualTo: true), inputFilter:nil)
			}, actionHandler: { [weak self] (completion) in
				self?.core?.refreshFavorites(completionHandler: { (_, _) in
					completion()
				})
			})

			addCollectionRow(to: section, title: "Available Offline".localized, image: UIImage(named: "cloud-available-offline")!, queryCreator: nil, actionHandler: { [weak self] (completion) in
				if let core = self?.core {
					let availableOfflineListController = ItemPolicyTableViewController(core: core, policyKind: .availableOffline)

					self?.navigationController?.pushViewController(availableOfflineListController, animated: true)
				}
				completion()
			})

			let queries = [
				QuickAccessQuery(name: "PDF Documents".localized, mimeType: ["pdf"], imageName: "application-pdf"),
				QuickAccessQuery(name: "Documents".localized, mimeType: ["doc", "application/vnd", "application/msword", "application/ms-doc", "text/rtf", "application/rtf", "application/mspowerpoint", "application/powerpoint", "application/x-mspowerpoint", "application/excel", "application/x-excel", "application/x-msexcel"], imageName: "x-office-document"),
				QuickAccessQuery(name: "Text".localized, mimeType: ["text/plain"], imageName: "text"),
				QuickAccessQuery(name: "Images".localized, mimeType: ["image"], imageName: "image"),
				QuickAccessQuery(name: "Videos".localized, mimeType: ["video"], imageName: "video"),
				QuickAccessQuery(name: "Audio".localized, mimeType: ["audio"], imageName: "audio")
			]

			for query in queries {
				addCollectionRow(to: section, title: query.name, image: Theme.shared.image(for: query.imageName, size: CGSize(width: 25, height: 25))!, queryCreator: {
					let conditions = query.mimeType.map { (mimeType) -> OCQueryCondition in
						return .where(.mimeType, contains: mimeType)
					}

					return OCQuery(condition: .any(of: conditions), inputFilter:nil)
				}, actionHandler: nil)
			}
		}
	}

	func addCollectionRow(to section: StaticTableViewSection, title: String, image: UIImage? = nil, themeImageName: String? = nil, queryCreator: (() -> OCQuery?)?, actionHandler: ((_ completion: @escaping () -> Void) -> Void)?) {
		let identifier = String(format:"%@-collection-row", title)
		if section.row(withIdentifier: identifier) == nil, let core = core {
			let row = StaticTableViewRow(rowWithAction: { [weak self] (_, _) in

				if let query = queryCreator?() {
					let customFileListController = QueryFileListTableViewController(core: core, query: query)
					customFileListController.title = title
					customFileListController.pullToRefreshAction = actionHandler
					self?.navigationController?.pushViewController(customFileListController, animated: true)
				}

				actionHandler?({})
			}, title: title, image: image, imageTintColorKey: "secondaryLabelColor", accessoryType: .disclosureIndicator, identifier: identifier)

			if themeImageName != nil {
				let themeApplierToken = Theme.shared.add(applier: { [weak row] (theme, _, _) in
					if let themeImageName = themeImageName {
						row?.cell?.imageView?.image = theme.image(for: themeImageName, size: CGSize(width: 25, height: 25))
					}
				}, applyImmediately: true)

				applierTokens.append(themeApplierToken)
			}

			section.add(row: row)
		}
	}

	// MARK: - Theming
	override func applyThemeCollection(theme: Theme, collection: ThemeCollection, event: ThemeEvent) {
		super.applyThemeCollection(theme: theme, collection: collection, event: event)

		self.navigationController?.view.backgroundColor = theme.activeCollection.navigationBarColors.backgroundColor
	}
}
