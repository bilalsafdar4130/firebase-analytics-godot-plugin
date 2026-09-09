/**************************************************************************/
/*  ms_billing.mm                                                         */
/**************************************************************************/

#import "ms_billing.h"

#import <StoreKit/StoreKit.h>

MobileServicesBilling *MobileServicesBilling::instance = nullptr;

/** Play Billing's response codes, which this SDK uses on both platforms. */
static const int MS_BILLING_OK = 0;
static const int MS_BILLING_USER_CANCELLED = 1;
static const int MS_BILLING_UNAVAILABLE = 3;
static const int MS_BILLING_ITEM_UNAVAILABLE = 4;
static const int MS_BILLING_NETWORK = 12;

@interface MSStoreKitBridge : NSObject <SKProductsRequestDelegate, SKPaymentTransactionObserver>
@property(nonatomic, strong) NSMutableDictionary<NSString *, SKProduct *> *products;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *types;
@property(nonatomic, strong) NSMutableDictionary<NSString *, SKPaymentTransaction *> *unfinished;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *restored;
@property(nonatomic, assign) BOOL restoring;
+ (instancetype)shared;
@end

/** One SKProduct in the shape the GDScript catalogue wants.
 * `localizedPrice` is built with an NSNumberFormatter set to the PRODUCT's
 * locale, not the device's: an App Store account in another country pays in that
 * country's currency, and formatting with the device locale shows the right
 * number with the wrong symbol. */
static NSDictionary *ms_describe_product(SKProduct *product) {
	NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
	formatter.numberStyle = NSNumberFormatterCurrencyStyle;
	formatter.locale = product.priceLocale;
	NSString *price = [formatter stringFromNumber:product.price] ?: @"";
	NSString *currency = @"";
	if (@available(iOS 10.0, *)) {
		currency = product.priceLocale.currencyCode ?: @"";
	}
	return @{
		@"id" : product.productIdentifier ?: @"",
		@"title" : product.localizedTitle ?: @"",
		@"name" : product.localizedTitle ?: @"",
		@"description" : product.localizedDescription ?: @"",
		@"price" : price,
		@"price_micros" : @((long long)([product.price doubleValue] * 1000000.0)),
		@"currency" : currency,
	};
}

static NSDictionary *ms_describe_transaction(SKPaymentTransaction *transaction) {
	NSString *state = @"unspecified";
	switch (transaction.transactionState) {
		case SKPaymentTransactionStatePurchased:
		case SKPaymentTransactionStateRestored:
			state = @"purchased";
			break;
		case SKPaymentTransactionStateDeferred:
			// Ask-to-Buy: a parent has to approve. Exactly Play's "pending".
			state = @"pending";
			break;
		default:
			break;
	}
	NSString *identifier = transaction.transactionIdentifier ?: @"";
	return @{
		@"product_id" : transaction.payment.productIdentifier ?: @"",
		@"state" : state,
		// StoreKit's transaction identifier stands in for Play's purchase token:
		// it is what `finishTransaction` is keyed on here and what a server
		// verifies against the App Store receipt.
		@"token" : identifier,
		@"order_id" : identifier,
		@"quantity" : @(transaction.payment.quantity),
		// StoreKit has no acknowledgement, so a delivered transaction is
		// reported as acknowledged and finished explicitly instead.
		@"acknowledged" : @YES,
		@"auto_renewing" : @NO,
	};
}

@implementation MSStoreKitBridge

+ (instancetype)shared {
	static MSStoreKitBridge *bridge = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		bridge = [[MSStoreKitBridge alloc] init];
		bridge.products = [NSMutableDictionary dictionary];
		bridge.types = [NSMutableDictionary dictionary];
		bridge.unfinished = [NSMutableDictionary dictionary];
		bridge.restored = [NSMutableArray array];
	});
	return bridge;
}

- (void)productsRequest:(SKProductsRequest *)request
	 didReceiveResponse:(SKProductsResponse *)response {
	MobileServicesBilling *plugin = MobileServicesBilling::get_singleton();
	NSMutableArray *described = [NSMutableArray array];
	for (SKProduct *product in response.products) {
		self.products[product.productIdentifier] = product;
		[described addObject:ms_describe_product(product)];
	}
	for (NSString *invalid in response.invalidProductIdentifiers) {
		NSLog(@"[MobileServices] the App Store does not know product %@ — check the id in "
			   "mobile_services.cfg, that it is Ready to Submit, and that a paid-apps "
			   "agreement is in place.", invalid);
	}
	if (plugin) {
		plugin->report_products(ms_json_from_array(described));
	}
}

- (void)request:(SKRequest *)request didFailWithError:(NSError *)error {
	MobileServicesBilling *plugin = MobileServicesBilling::get_singleton();
	if (plugin) {
		plugin->report_products_failed(MS_BILLING_NETWORK, ms_str(error.localizedDescription));
	}
}

- (void)paymentQueue:(SKPaymentQueue *)queue
	updatedTransactions:(NSArray<SKPaymentTransaction *> *)transactions {
	MobileServicesBilling *plugin = MobileServicesBilling::get_singleton();
	if (!plugin) {
		return;
	}
	for (SKPaymentTransaction *transaction in transactions) {
		switch (transaction.transactionState) {
			case SKPaymentTransactionStatePurchasing:
				break;
			case SKPaymentTransactionStateDeferred:
				plugin->report_purchase(ms_json_from_dictionary(ms_describe_transaction(transaction)));
				break;
			case SKPaymentTransactionStateFailed: {
				NSInteger code = transaction.error.code;
				int translated = (code == SKErrorPaymentCancelled)
						? MS_BILLING_USER_CANCELLED
						: MS_BILLING_UNAVAILABLE;
				plugin->report_purchase_failed(
						ms_str(transaction.payment.productIdentifier), translated,
						ms_str(transaction.error.localizedDescription));
				// A failed transaction MUST be finished or it stays on the queue
				// and is redelivered on every launch.
				[[SKPaymentQueue defaultQueue] finishTransaction:transaction];
			} break;
			case SKPaymentTransactionStatePurchased:
			case SKPaymentTransactionStateRestored: {
				NSString *identifier = transaction.transactionIdentifier ?: @"";
				if (identifier.length > 0) {
					self.unfinished[identifier] = transaction;
				}
				NSDictionary *described = ms_describe_transaction(transaction);
				if (self.restoring) {
					[self.restored addObject:described];
				}
				plugin->report_purchase(ms_json_from_dictionary(described));
			} break;
		}
	}
}

- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue *)queue {
	MobileServicesBilling *plugin = MobileServicesBilling::get_singleton();
	self.restoring = NO;
	if (plugin) {
		plugin->report_purchases_queried(ms_json_from_array(self.restored));
	}
	[self.restored removeAllObjects];
}

- (void)paymentQueue:(SKPaymentQueue *)queue
	restoreCompletedTransactionsFailedWithError:(NSError *)error {
	MobileServicesBilling *plugin = MobileServicesBilling::get_singleton();
	self.restoring = NO;
	if (plugin) {
		// Not a purchase failure: nothing was bought. Report an empty restore so
		// the game stops waiting, and the error separately.
		plugin->report_purchases_queried(String("[]"));
		plugin->report_purchase_failed(String(),
				error.code == SKErrorPaymentCancelled ? MS_BILLING_USER_CANCELLED : MS_BILLING_NETWORK,
				ms_str(error.localizedDescription));
	}
	[self.restored removeAllObjects];
}

@end

MobileServicesBilling *MobileServicesBilling::get_singleton() {
	return instance;
}

void MobileServicesBilling::_bind_methods() {
	ClassDB::bind_method(D_METHOD("initializeBilling", "products"), &MobileServicesBilling::initialize_billing);
	ClassDB::bind_method(D_METHOD("isReady"), &MobileServicesBilling::is_ready);
	ClassDB::bind_method(D_METHOD("lastError"), &MobileServicesBilling::last_error_message);
	ClassDB::bind_method(D_METHOD("queryProducts"), &MobileServicesBilling::query_products);
	ClassDB::bind_method(D_METHOD("purchase", "store_id", "type", "offer_token"), &MobileServicesBilling::purchase);
	ClassDB::bind_method(D_METHOD("queryPurchases"), &MobileServicesBilling::query_purchases);
	ClassDB::bind_method(D_METHOD("consume", "token"), &MobileServicesBilling::consume);
	ClassDB::bind_method(D_METHOD("acknowledge", "token"), &MobileServicesBilling::acknowledge);

	ADD_SIGNAL(MethodInfo("billing_ready"));
	ADD_SIGNAL(MethodInfo("billing_failed", PropertyInfo(Variant::INT, "code"),
			PropertyInfo(Variant::STRING, "message")));
	ADD_SIGNAL(MethodInfo("products_loaded", PropertyInfo(Variant::STRING, "products")));
	ADD_SIGNAL(MethodInfo("products_load_failed", PropertyInfo(Variant::INT, "code"),
			PropertyInfo(Variant::STRING, "message")));
	ADD_SIGNAL(MethodInfo("purchase_updated", PropertyInfo(Variant::STRING, "purchase")));
	ADD_SIGNAL(MethodInfo("purchase_failed", PropertyInfo(Variant::STRING, "product"),
			PropertyInfo(Variant::INT, "code"), PropertyInfo(Variant::STRING, "message")));
	ADD_SIGNAL(MethodInfo("purchases_queried", PropertyInfo(Variant::STRING, "purchases")));
	ADD_SIGNAL(MethodInfo("purchase_consumed", PropertyInfo(Variant::STRING, "token"),
			PropertyInfo(Variant::STRING, "product")));
	ADD_SIGNAL(MethodInfo("purchase_acknowledged", PropertyInfo(Variant::STRING, "token"),
			PropertyInfo(Variant::STRING, "product")));
}

void MobileServicesBilling::initialize_billing(const String &p_products_json) {
	@autoreleasepool {
		MSStoreKitBridge *bridge = [MSStoreKitBridge shared];
		[bridge.types removeAllObjects];
		NSData *data = [ms_ns(p_products_json) dataUsingEncoding:NSUTF8StringEncoding];
		NSArray *entries = data == nil
				? @[]
				: [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
		if ([entries isKindOfClass:[NSArray class]]) {
			for (NSDictionary *entry in entries) {
				NSString *identifier = entry[@"id"];
				if ([identifier isKindOfClass:[NSString class]] && identifier.length > 0) {
					bridge.types[identifier] = entry[@"type"] ?: @"non_consumable";
				}
			}
		}
		if (![SKPaymentQueue canMakePayments]) {
			// Parental controls, or a managed device. Not an error the game can
			// fix, and worth saying plainly rather than failing every purchase.
			report_failed(MS_BILLING_UNAVAILABLE,
					String("this device is not allowed to make payments (Screen Time restrictions)"));
			return;
		}
		if (!ready) {
			// Added once and never removed: the queue delivers interrupted
			// purchases from previous launches, and an observer added late
			// misses them.
			[[SKPaymentQueue defaultQueue] addTransactionObserver:bridge];
		}
		report_ready();
	}
}

void MobileServicesBilling::query_products() {
	@autoreleasepool {
		MSStoreKitBridge *bridge = [MSStoreKitBridge shared];
		NSSet *identifiers = [NSSet setWithArray:bridge.types.allKeys];
		if (identifiers.count == 0) {
			report_products(String("[]"));
			return;
		}
		SKProductsRequest *request =
				[[SKProductsRequest alloc] initWithProductIdentifiers:identifiers];
		request.delegate = bridge;
		[request start];
	}
}

void MobileServicesBilling::purchase(const String &p_store_id, const String &p_type,
		const String &p_offer_token) {
	@autoreleasepool {
		MSStoreKitBridge *bridge = [MSStoreKitBridge shared];
		SKProduct *product = bridge.products[ms_ns(p_store_id)];
		if (product == nil) {
			report_purchase_failed(p_store_id, MS_BILLING_ITEM_UNAVAILABLE,
					String("the App Store has not returned this product yet — wait for "
						   "products_loaded, and check the id in mobile_services.cfg"));
			return;
		}
		SKMutablePayment *payment = [SKMutablePayment paymentWithProduct:product];
		[[SKPaymentQueue defaultQueue] addPayment:payment];
	}
}

void MobileServicesBilling::query_purchases() {
	@autoreleasepool {
		MSStoreKitBridge *bridge = [MSStoreKitBridge shared];
		bridge.restoring = YES;
		[bridge.restored removeAllObjects];
		[[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
	}
}

/** StoreKit has one operation for both: finishing the transaction. Doing it is
 * not optional — see the header. */
void MobileServicesBilling::consume(const String &p_token) {
	@autoreleasepool {
		MSStoreKitBridge *bridge = [MSStoreKitBridge shared];
		NSString *token = ms_ns(p_token);
		SKPaymentTransaction *transaction = bridge.unfinished[token];
		if (transaction == nil) {
			return;
		}
		String product = ms_str(transaction.payment.productIdentifier);
		[[SKPaymentQueue defaultQueue] finishTransaction:transaction];
		[bridge.unfinished removeObjectForKey:token];
		MS_EMIT("purchase_consumed", p_token, product);
	}
}

void MobileServicesBilling::acknowledge(const String &p_token) {
	@autoreleasepool {
		MSStoreKitBridge *bridge = [MSStoreKitBridge shared];
		NSString *token = ms_ns(p_token);
		SKPaymentTransaction *transaction = bridge.unfinished[token];
		if (transaction == nil) {
			return;
		}
		String product = ms_str(transaction.payment.productIdentifier);
		[[SKPaymentQueue defaultQueue] finishTransaction:transaction];
		[bridge.unfinished removeObjectForKey:token];
		MS_EMIT("purchase_acknowledged", p_token, product);
	}
}

void MobileServicesBilling::report_ready() {
	ready = true;
	last_error = String();
	MS_EMIT("billing_ready");
}

void MobileServicesBilling::report_failed(int p_code, const String &p_message) {
	ready = false;
	last_error = p_message;
	MS_EMIT("billing_failed", p_code, p_message);
}

void MobileServicesBilling::report_products(const String &p_json) {
	MS_EMIT("products_loaded", p_json);
}

void MobileServicesBilling::report_products_failed(int p_code, const String &p_message) {
	last_error = p_message;
	MS_EMIT("products_load_failed", p_code, p_message);
}

void MobileServicesBilling::report_purchase(const String &p_json) {
	MS_EMIT("purchase_updated", p_json);
}

void MobileServicesBilling::report_purchase_failed(const String &p_product, int p_code,
		const String &p_message) {
	last_error = p_message;
	MS_EMIT("purchase_failed", p_product, p_code, p_message);
}

void MobileServicesBilling::report_purchases_queried(const String &p_json) {
	MS_EMIT("purchases_queried", p_json);
}

void MobileServicesBilling::report_finished(const String &p_token, const String &p_product) {
	MS_EMIT("purchase_acknowledged", p_token, p_product);
}

MobileServicesBilling::MobileServicesBilling() {
	ERR_FAIL_COND(instance != nullptr);
	instance = this;
}

MobileServicesBilling::~MobileServicesBilling() {
	if (instance == this) {
		instance = nullptr;
	}
}
