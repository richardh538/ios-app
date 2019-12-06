//
//  OCLicenseAppStoreProvider.m
//  ownCloud
//
//  Created by Felix Schwarz on 24.11.19.
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

#import <StoreKit/StoreKit.h>

#import "OCLicenseAppStoreProvider.h"
#import "OCLicenseManager.h"
#import "OCLicenseAppStoreReceipt.h"
#import "OCLicenseEntitlement.h"
#import "OCLicenseProduct.h"
#import "OCLicenseTransaction.h"

@interface OCLicenseAppStoreProvider () <SKProductsRequestDelegate, SKPaymentTransactionObserver>
{
	OCLicenseProviderCompletionHandler _startCompletionHandler;
	BOOL _setupTransactionObserver;

	NSMutableDictionary<OCLicenseAppStoreProductIdentifier, NSNumber *> *_offerStateByAppStoreProductIdentifier;

	OCLicenseAppStoreRestorePurchasesCompletionHandler _restorePurchasesCompletionHandler;
}

@property(nullable,strong) SKProductsRequest *request;
@property(nullable,strong) SKProductsResponse *response;

@end

@implementation OCLicenseAppStoreProvider

#pragma mark - Init
- (instancetype)initWithItems:(NSArray<OCLicenseAppStoreItem *> *)items
{
	if ((self = [super initWithIdentifier:OCLicenseProviderIdentifierAppStore]) != nil)
	{
		_items = items;
		_offerStateByAppStoreProductIdentifier = [NSMutableDictionary new];

		self.localizedName = OCLocalized(@"App Store");
	}

	return (self);
}

#pragma mark - Mapping
- (nullable OCLicenseProductIdentifier)productIdentifierForAppStoreIdentifier:(OCLicenseAppStoreProductIdentifier)identifier
{
	return ([self itemForAppStoreIdentifier:identifier].productIdentifier);
}

- (nullable OCLicenseAppStoreItem *)itemForAppStoreIdentifier:(OCLicenseAppStoreProductIdentifier)identifier
{
	if (identifier == nil)
	{
		return (nil);
	}

	for (OCLicenseAppStoreItem *item in _items)
	{
		if ([item.identifier isEqual:identifier])
		{
			return (item);
		}
	}

	return (nil);
}

#pragma mark - Transaction access
- (void)retrieveTransactionsWithCompletionHandler:(void (^)(NSError * _Nullable, NSArray<OCLicenseTransaction *> * _Nullable))completionHandler
{
	if (self.receipt == nil)
	{
		[self restorePurchasesWithCompletionHandler:^(NSError * _Nullable error) {
			completionHandler(error, [self _transactionsFromReceipt:self.receipt]);
		}];
	}
	else
	{
		completionHandler(nil, [self _transactionsFromReceipt:self.receipt]);
	}
}

- (NSArray<OCLicenseTransaction *> *)_transactionsFromReceipt:(OCLicenseAppStoreReceipt *)receipt
{
	NSMutableArray <OCLicenseTransaction *> *transactions = nil;

	if (receipt != nil)
	{
		transactions = [NSMutableArray new];

		if (receipt.originalAppVersion != nil)
		{
			[transactions addObject:[OCLicenseTransaction transactionWithProvider:self tableRows:@[
				@{ OCLocalized(@"Purchased App Version") : receipt.originalAppVersion },
				@{ OCLocalized(@"Receipt Date") : (receipt.creationDate != nil) ? receipt.creationDate : @"-" }
			]]];
		}

		for (OCLicenseAppStoreReceiptInAppPurchase *iap in receipt.inAppPurchases)
		{
			OCLicenseProductIdentifier productID = [self productIdentifierForAppStoreIdentifier:iap.productID];
			OCLicenseProduct *product = [self.manager productWithIdentifier:productID];
			OCLicenseAppStoreItem *item = [self itemForAppStoreIdentifier:iap.productID];

			[transactions addObject:[OCLicenseTransaction transactionWithProvider:self
										   identifier:iap.webOrderLineItemID.stringValue
											 type:item.type
										     quantity:iap.quantity.integerValue
											 name:((item.storeProduct.localizedTitle != nil) ? item.storeProduct.localizedTitle : ((product != nil) ? product.localizedName : iap.productID))
									    productIdentifier:product.identifier
											 date:iap.purchaseDate
										      endDate:iap.subscriptionExpirationDate
									     cancellationDate:iap.cancellationDate]
			];
		}
	}

	return (transactions);
}

#pragma mark - Start providing
- (void)startProvidingWithCompletionHandler:(OCLicenseProviderCompletionHandler)completionHandler
{
	if (!SKPaymentQueue.canMakePayments)
	{
		OCLogWarning(@"SKPaymentQueue: can't make payments");
		completionHandler(self, nil);
		return;
	}

	if (_request == nil)
	{
		NSMutableSet<OCLicenseAppStoreProductIdentifier> *appStoreIdentifiers = [NSMutableSet new];

		// Build product request
		for (OCLicenseAppStoreItem *item in _items)
		{
			[appStoreIdentifiers addObject:item.identifier];
		}

		_startCompletionHandler = [completionHandler copy];

		_request = [[SKProductsRequest alloc] initWithProductIdentifiers:appStoreIdentifiers];
		_request.delegate = self;

		[_request start];
	}

	if (!_setupTransactionObserver)
	{
		// Did setup
		_setupTransactionObserver = YES;

		// Add the provider as transaction observer
		[SKPaymentQueue.defaultQueue addTransactionObserver:self]; // needs to be called in -[UIApplicationDelegate application:didFinishLaunchingWithOptions:] to not miss a transaction

		// Add termination notification observer
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_processWillTerminate) name:UIApplicationWillTerminateNotification object:nil];
	}

	// Load & refresh receipt as needed
	[self loadReceipt];
	[self reloadReceiptIfNeeded];
}

- (OCLicenseAppStoreReceipt *)receipt
{
	if (_receipt == nil)
	{
		[self loadReceipt];
	}

	return (_receipt);
}

- (void)loadReceipt
{
	OCLicenseAppStoreReceipt *receipt = OCLicenseAppStoreReceipt.defaultReceipt;
	OCLicenseAppStoreReceiptParseError parseError;

	if ((parseError = [receipt parse]) != OCLicenseAppStoreReceiptParseErrorNone)
	{
		OCLogError(@"Error %ld parsing App Store receipt.", (long)parseError);
	}

	[self willChangeValueForKey:@"receipt"];
	_receipt = receipt;
	[self didChangeValueForKey:@"receipt"];

	OCLogDebug(@"App Store Receipt loaded: %@", _receipt);

	[self recomputeEntitlements];
}

- (void)reloadReceiptIfNeeded
{
	OCLicenseAppStoreReceipt *receipt = self.receipt;
	BOOL needsReload = NO;

	if (receipt != nil)
	{
		if ((receipt.expirationDate != nil) && (receipt.expirationDate.timeIntervalSinceNow < 0))
		{
			// Receipt expired
			needsReload = YES;
		}
		else
		{
			for (OCLicenseAppStoreReceiptInAppPurchase *iap in receipt.inAppPurchases)
			{
				if ((iap.subscriptionExpirationDate != nil) && (iap.subscriptionExpirationDate.timeIntervalSinceNow < 0) && // IAP has expired
				   ([iap.subscriptionExpirationDate timeIntervalSinceDate:receipt.creationDate] > 0)) // The receipt was created before the IAP has expired
				{
					// Subscription expired
					needsReload = YES;
					break;
				}
			}
		}
	}

	if (needsReload)
	{
		OCLogDebug(@"App Store Receipt needs reload");

		[self restorePurchasesWithCompletionHandler:^(NSError * _Nullable error) {
			OCLogDebug(@"Restored purchases with error=%@", error);

			if (error != nil)
			{
				OCLogError(@"Error restoring purchases: %@", error);
				return;
			}

			[self loadReceipt];
		}];
	}
}

- (void)_processWillTerminate
{
	// Remove the provider on app termination
	[self.manager removeProvider:self];
}

- (void)stopProvidingWithCompletionHandler:(OCLicenseProviderCompletionHandler)completionHandler
{
	// Cancel product request if still ongoing
	if (_request != nil)
	{
		[_request cancel];
		_request = nil;
	}

	if (_setupTransactionObserver)
	{
		// Remove provider as transaction observer
		[SKPaymentQueue.defaultQueue removeTransactionObserver:self];

		// Remove termination notification observer
		[[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillTerminateNotification object:nil];
	}
}

#pragma mark - Entitlements & Offers
- (void)recomputeEntitlements
{
	OCLicenseAppStoreReceipt *receipt = _receipt;
	NSMutableArray<OCLicenseEntitlement *> *entitlements = [NSMutableArray new];

	for (OCLicenseAppStoreItem *item in self.items)
	{
		// Find corresponding IAPs
		NSMutableArray<OCLicenseAppStoreReceiptInAppPurchase *> *itemIAPs = nil;

		for (OCLicenseAppStoreReceiptInAppPurchase *iap in receipt.inAppPurchases)
		{
			if ([iap.productID isEqualToString:item.identifier])
			{
				if (itemIAPs == nil)
				{
					itemIAPs = [NSMutableArray new];
				}

				[itemIAPs addObject:iap];
			}
		}

		if (itemIAPs != nil)
		{
			// IAPs found => create entitlements
			OCLicenseEntitlement *entitlement;
			OCLicenseAppStoreReceiptInAppPurchase *iap = itemIAPs.lastObject; // If there's more than one IAP, assume the last to be the relevant one
			NSDate *expiryDate = nil;
			NSDate *purchaseDate = (iap.originalPurchaseDate != nil) ? iap.originalPurchaseDate : iap.purchaseDate;

			switch (item.type)
			{
				case OCLicenseTypeNone:
				break;

				case OCLicenseTypeTrial:
					expiryDate = [item.trialDuration dateWithDurationAddedTo:purchaseDate];
				break;

				case OCLicenseTypeSubscription:
					expiryDate = iap.subscriptionExpirationDate;
				break;

				case OCLicenseTypePurchase:
				break;
			}

			entitlement = [OCLicenseEntitlement entitlementWithIdentifier:nil forProduct:item.productIdentifier type:item.type valid:YES expiryDate:expiryDate applicability:nil];

			[entitlements addObject:entitlement];
		}
	}

	self.entitlements = (entitlements.count > 0) ? entitlements : nil;
}

- (void)recomputeOffers
{
	// Create offers from items
	NSMutableArray<OCLicenseOffer *> *offers = [NSMutableArray new];
	OCLicenseAppStoreReceipt *receipt = _receipt;

	for (OCLicenseAppStoreItem *item in _items)
	{
		SKProduct *storeProduct = nil;

		if ((storeProduct = item.storeProduct) != nil)
		{
			OCLicenseOffer *offer = nil;
			OCLicenseAppStoreProductIdentifier appStoreProductIdentifier = storeProduct.productIdentifier;

			offer = [OCLicenseOffer offerWithIdentifier:[@"appstore." stringByAppendingString:appStoreProductIdentifier] type:item.type product:item.productIdentifier];

			offer.price = storeProduct.price;
			offer.priceLocale = storeProduct.priceLocale;

			offer.localizedTitle = storeProduct.localizedTitle;
			offer.localizedDescription = storeProduct.localizedDescription;

			offer.commitHandler = ^(OCLicenseOffer * _Nonnull offer, OCLicenseOfferCommitOptions  _Nullable options) {
				OCLicenseAppStoreProvider *appStoreProvider = [offer.provider isKindOfClass:[OCLicenseAppStoreProvider class]] ? (OCLicenseAppStoreProvider *)offer.provider : nil;

				if (appStoreProvider != nil)
				{
					[appStoreProvider requestPaymentFor:storeProduct];
				}
			};

			// Subscription and trial properties
			offer.trialDuration = item.trialDuration;

			if (storeProduct.subscriptionPeriod != nil)
			{
				offer.subscriptionTermDuration = storeProduct.subscriptionPeriod.licenseDuration;
			}

			offer.groupIdentifier = storeProduct.subscriptionGroupIdentifier;

			// Derive state from payment queue
			if (_offerStateByAppStoreProductIdentifier[appStoreProductIdentifier] != nil)
			{
				offer.state = _offerStateByAppStoreProductIdentifier[appStoreProductIdentifier].unsignedIntegerValue;
			}

			// Derive state from receipt
			for (OCLicenseAppStoreReceiptInAppPurchase *iap in receipt.inAppPurchases)
			{
				if ([iap.productID isEqual:appStoreProductIdentifier])
				{
					offer.state = OCLicenseOfferStateCommitted;
				}
			}

			// Add offer
			if (offer != nil)
			{
				[offers addObject:offer];
			}
		}
	}

	self.offers = (offers.count > 0) ? offers : nil;

}

#pragma mark - Product request delegate
- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response
{
	// Called on success
	self.response = response;

	// Parse response
	for (SKProduct *product in response.products)
	{
		for (OCLicenseAppStoreItem *item in _items)
		{
			if ([item.identifier isEqual:product.productIdentifier])
			{
				item.storeProduct = product;
				break;
			}
		}
	}

	[self recomputeOffers];
}

- (void)requestDidFinish:(SKRequest *)request
{
	// Called last on success (not called on error)

	if (_startCompletionHandler != nil)
	{
		_startCompletionHandler(self, nil);
		_startCompletionHandler = nil;
	}
}

- (void)request:(SKRequest *)request didFailWithError:(NSError *)error
{
	// Called last on error
	if (_startCompletionHandler != nil)
	{
		_startCompletionHandler(self, error);
		_startCompletionHandler = nil;
	}
}

#pragma mark - Payment
- (void)requestPaymentFor:(SKProduct *)product
{
	SKPayment *payment;

	OCLogDebug(@"Requesting payment for %@ (productIdentifier=%@)", product, product.productIdentifier);

	if ((product != nil) && ((payment = [SKPayment paymentWithProduct:product]) != nil))
	{
		[SKPaymentQueue.defaultQueue addPayment:payment];
	}
}

#pragma mark - Payment transaction observation
// Sent when the transaction array has changed (additions or state changes).  Client should check state of transactions and finish as appropriate.
- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray<SKPaymentTransaction *> *)transactions
{
	OCLogDebug(@"Payment queue updated with transactions %@", transactions);

	for (SKPaymentTransaction *originalTransaction in transactions)
	{
		OCLicenseOfferState offerState = OCLicenseOfferStateUncommitted;
		SKPaymentTransaction *transaction = originalTransaction;
		BOOL finishTransaction = NO;

		// Restored transaction => use the original transaction if available
		if ((transaction.transactionState == SKPaymentTransactionStateRestored) && (transaction.originalTransaction != nil))
		{
			// Transaction has been restored
			transaction = transaction.originalTransaction;
			finishTransaction = YES;
		}

		// Fall back to any existing offer state
		OCLicenseAppStoreProductIdentifier appStoreProductIdentifier = transaction.payment.productIdentifier;

		if (appStoreProductIdentifier != nil)
		{
			@synchronized(self)
			{
				if (_offerStateByAppStoreProductIdentifier[appStoreProductIdentifier] != nil)
				{
					offerState = _offerStateByAppStoreProductIdentifier[appStoreProductIdentifier].unsignedIntegerValue;
				}
			}
		}

		// Translate transaction to offer state
		switch (transaction.transactionState)
		{
			case SKPaymentTransactionStatePurchasing:
				offerState = OCLicenseOfferStateInProgress;
				// Calling finishTransaction here throws an exception (via documentation)
			break;

			case SKPaymentTransactionStateDeferred:
				offerState = OCLicenseOfferStateInProgress;
			break;

			case SKPaymentTransactionStatePurchased:
				offerState = OCLicenseOfferStateCommitted;
				finishTransaction = YES;
			break;

			case SKPaymentTransactionStateFailed:
				OCLogError(@"Transaction failed with error=%@", transaction.error);

				offerState = OCLicenseOfferStateUncommitted;
				finishTransaction = YES;
			break;

			case SKPaymentTransactionStateRestored:
				OCLogWarning(@"Restored App Store transaction without original? %@ %@", transaction, transaction.originalTransaction);
			break;
		}

		// Store new offer state
		if (appStoreProductIdentifier != nil)
		{
			@synchronized(self)
			{
				_offerStateByAppStoreProductIdentifier[appStoreProductIdentifier] = @(offerState);
			}
		}

		// Finish transaction and remove it from the SKPaymentQueue
		if (finishTransaction)
		{
			[SKPaymentQueue.defaultQueue finishTransaction:originalTransaction];
		}
	}

	[self recomputeEntitlements];
}

#pragma mark - Restore IAPs
- (void)restorePurchasesWithCompletionHandler:(OCLicenseAppStoreRestorePurchasesCompletionHandler)completionHandler
{
	OCLogDebug(@"Restoring purchases");

	@synchronized(self)
	{
		OCLicenseAppStoreRestorePurchasesCompletionHandler existingCompletionHandler = nil;

		if ((existingCompletionHandler = _restorePurchasesCompletionHandler) != nil)
		{
			completionHandler = [completionHandler copy];

			_restorePurchasesCompletionHandler = [^(NSError *error) {
				existingCompletionHandler(error);
				completionHandler(error);
			} copy];
		}
		else
		{
			_restorePurchasesCompletionHandler = [completionHandler copy];
		}

		[SKPaymentQueue.defaultQueue restoreCompletedTransactions];
	}
}

- (void)paymentQueue:(SKPaymentQueue *)queue restoreCompletedTransactionsFailedWithError:(NSError *)error
{
	OCLogWarning(@"Payment queue restore failed with error %@", error);

	@synchronized(self)
	{
		[self loadReceipt];

		if (_restorePurchasesCompletionHandler != nil)
		{
			_restorePurchasesCompletionHandler(error);
			_restorePurchasesCompletionHandler = nil;
		}
	}
}

- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue *)queue
{
	OCLogDebug(@"Payment queue restore completed successfully");

	@synchronized(self)
	{
		[self loadReceipt];

		if (_restorePurchasesCompletionHandler != nil)
		{
			_restorePurchasesCompletionHandler(nil);
			_restorePurchasesCompletionHandler = nil;
		}
	}
}

+ (NSArray<OCLogTagName> *)logTags
{
	return (@[@"Licensing", @"AppStore"]);
}

- (NSArray<OCLogTagName> *)logTags
{
	return (@[@"Licensing", @"AppStore"]);
}

@end

@implementation OCLicenseManager (AppStore)

+ (OCLicenseAppStoreProvider *)appStoreProvider
{
	return ((OCLicenseAppStoreProvider *)[self.sharedLicenseManager providerForIdentifier:OCLicenseProviderIdentifierAppStore]);
}

@end
OCLicenseProviderIdentifier OCLicenseProviderIdentifierAppStore = @"app-store";