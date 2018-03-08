//
//  BookmarkManager.swift
//  ownCloud
//
//  Created by Felix Schwarz on 08.03.18.
//  Copyright © 2018 ownCloud. All rights reserved.
//

import UIKit
import ownCloudSDK

class BookmarkManager: NSObject
{
	public var bookmarks : NSMutableArray

	static var sharedBookmarkManager : BookmarkManager = {
		let sharedInstance = BookmarkManager()
		
		sharedInstance.loadBookmarks()
		
		return (sharedInstance)
	}()

	public override init() {
		bookmarks = NSMutableArray()

		super.init()
	}
	
	func bookmarkStoreURL() -> URL {
		return OCAppIdentity.shared().appGroupContainerURL.appendingPathComponent("bookmarks.dat")
	}
	
	func loadBookmarks() {
		var loadedBookmarks : NSMutableArray?

		do {
			loadedBookmarks = try NSKeyedUnarchiver.unarchiveObject(with: Data.init(contentsOf: self.bookmarkStoreURL())) as! NSMutableArray?
			
			if (loadedBookmarks != nil) {
				bookmarks = loadedBookmarks!
			}
		} catch {
			debugPrint("Loading bookmarks failed with \(error)")
		}
	}
	
	func saveBookmarks() {
		do {
			try NSKeyedArchiver.archivedData(withRootObject: bookmarks as Any).write(to: self.bookmarkStoreURL())
		} catch {
			debugPrint("Saving bookmarks failed with \(error)")
		}
	}
	
	func addBookmark(bookmark: OCBookmark) {
		bookmarks.add(bookmark)
	}
	
	func removeBookmark(bookmark: OCBookmark) {
		bookmarks.remove(bookmark)
	}
	
	func bookmark(at index: Int) -> OCBookmark {
		return (bookmarks.object(at: index) as! OCBookmark)
	}
}
