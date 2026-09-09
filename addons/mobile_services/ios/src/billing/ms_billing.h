/**************************************************************************/
/*  ms_billing.h — MobileServicesBilling on iOS (StoreKit)                */
/**************************************************************************/
/*
 * The iOS half of the purchase bridge, over StoreKit's transaction queue.
 *
 * THE APP STORE IS NOT PLAY, and three differences shape this file.
 *
 * 1. THERE IS NO "ACKNOWLEDGE" AND NO "CONSUME" — there is `finishTransaction`,
 *    which is both. `consume()` and `acknowledge()` therefore do the same thing
 *    here, and they still must be called: an unfinished transaction is redelivered
 *    on every launch forever and StoreKit will not sell the product again.
 *
 * 2. THE QUEUE IS THE API. Purchases arrive on an observer, not as the result of
 *    the call that started them, and they arrive for purchases made on other
 *    devices, interrupted purchases from a previous launch, and Ask-to-Buy
 *    approvals. The observer is added at initialisation and never removed.
 *
 * 3. RESTORE IS EXPLICIT and Apple requires a button for it. `queryPurchases()`
 *    calls `restoreCompletedTransactions`, which replays non-consumables and
 *    subscriptions through the same observer.
 *
 * Response codes are translated to Play Billing's numbers before they leave, so
 * `MSIap._translate` on the GDScript side serves both stores.
 */

#ifndef MS_BILLING_H
#define MS_BILLING_H

#include "core/object/object.h"
#include "ms_common.h"

class MobileServicesBilling : public Object {
	GDCLASS(MobileServicesBilling, Object);

	static MobileServicesBilling *instance;
	bool ready = false;
	String last_error;

protected:
	static void _bind_methods();

public:
	static MobileServicesBilling *get_singleton();

	void initialize_billing(const String &p_products_json);
	bool is_ready() const { return ready; }
	String last_error_message() const { return last_error; }

	void query_products();
	void purchase(const String &p_store_id, const String &p_type, const String &p_offer_token);
	void query_purchases();
	void consume(const String &p_token);
	void acknowledge(const String &p_token);

	/** Called from the StoreKit delegates. Not bound to GDScript. */
	void report_ready();
	void report_failed(int p_code, const String &p_message);
	void report_products(const String &p_json);
	void report_products_failed(int p_code, const String &p_message);
	void report_purchase(const String &p_json);
	void report_purchase_failed(const String &p_product, int p_code, const String &p_message);
	void report_purchases_queried(const String &p_json);
	void report_finished(const String &p_token, const String &p_product);

	MobileServicesBilling();
	~MobileServicesBilling();
};

#endif // MS_BILLING_H
