#import "InAppUtils.h"
#import <StoreKit/StoreKit.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>
#import "SKProduct+StringPrice.h"

@implementation InAppUtils
{
    NSArray *products;
    NSMutableDictionary *_promiseBlocks;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _promiseBlocks = [[NSMutableDictionary alloc] init];
        [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
    }
    return self;
}

+ (BOOL)requiresMainQueueSetup {
    return NO;
}

- (dispatch_queue_t)methodQueue
{
    return dispatch_get_main_queue();
}

RCT_EXPORT_MODULE()

- (void)paymentQueue:(SKPaymentQueue *)queue
 updatedTransactions:(NSArray *)transactions
{
    for (SKPaymentTransaction *transaction in transactions) {
        switch (transaction.transactionState) {
            case SKPaymentTransactionStateFailed: {
                NSString *key = RCTKeyForInstance(transaction.payment.productIdentifier);
                NSDictionary *promiseBlock = _promiseBlocks[key];
                if (promiseBlock) {
                    RCTPromiseRejectBlock reject = promiseBlock[@"reject"];
                    if (reject) {
                        reject(@"payment_failed", nil, transaction.error);
                    }
                    [_promiseBlocks removeObjectForKey:key];
                } else {
                    RCTLogWarn(@"No resolver registered for transaction with state failed.");
                }
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                break;
            }
            case SKPaymentTransactionStatePurchased: {
                NSString *key = RCTKeyForInstance(transaction.payment.productIdentifier);
                NSDictionary *promiseBlock = _promiseBlocks[key];
                if (promiseBlock) {
                    NSDictionary *purchase = [self getPurchaseData:transaction];
                    RCTPromiseResolveBlock resolve = promiseBlock[@"resolve"];
                    if (resolve) {
                        resolve(purchase);
                    }
                    [_promiseBlocks removeObjectForKey:key];
                } else {
                    RCTLogWarn(@"No resolver registered for transaction with state purchased.");
                }
                break;
            }
            case SKPaymentTransactionStateRestored:
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                break;
            case SKPaymentTransactionStatePurchasing:
                NSLog(@"purchasing");
                break;
            case SKPaymentTransactionStateDeferred:
                NSLog(@"deferred");
                break;
            default:
                break;
        }
    }
}

RCT_EXPORT_METHOD(getPendingPurchases:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    NSMutableArray *transactionsArrayForJS = [NSMutableArray array];
    for (SKPaymentTransaction *transaction in [SKPaymentQueue defaultQueue].transactions) {
        [transactionsArrayForJS addObject:[self getQueuedPurchaseData:transaction]];
    }
    resolve(transactionsArrayForJS);
}

RCT_EXPORT_METHOD(purchaseProductForUser:(NSString *)productIdentifier
                  username:(NSString *)username
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    [self doPurchaseProduct:productIdentifier username:username resolver:resolve rejecter:reject];
}

RCT_EXPORT_METHOD(purchaseProduct:(NSString *)productIdentifier
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    [self doPurchaseProduct:productIdentifier username:nil resolver:resolve rejecter:reject];
}

- (void) doPurchaseProduct:(NSString *)productIdentifier
                  username:(NSString *)username
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject
{
    SKProduct *product;
    for(SKProduct *p in products)
    {
        if([productIdentifier isEqualToString:p.productIdentifier]) {
            product = p;
            break;
        }
    }

    for (SKPaymentTransaction *transaction in [SKPaymentQueue defaultQueue].transactions) {
        if ([productIdentifier isEqualToString:transaction.payment.productIdentifier]) {
            switch (transaction.transactionState) {
                case SKPaymentTransactionStateFailed:
                    [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                    break;
                case SKPaymentTransactionStatePurchased:
                    resolve([self getQueuedPurchaseData:transaction]);
                    return;
                default:
                    RCTLogInfo(@"Transaction not failed nor purchased");
            }
        }
    }

    if(product) {
        SKMutablePayment *payment = [SKMutablePayment paymentWithProduct:product];
        if(username) {
            payment.applicationUsername = username;
        }
        _promiseBlocks[RCTKeyForInstance(payment.productIdentifier)] = @{
                                                                         @"resolve": resolve,
                                                                         @"reject": reject,
                                                                         };
        [[SKPaymentQueue defaultQueue] addPayment:payment];
    } else {
        reject(@"invalid_product", nil, nil);
    }
}

RCT_EXPORT_METHOD(finishPurchase:(NSString *)transactionIdentifier
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    for (SKPaymentTransaction *transaction in [SKPaymentQueue defaultQueue].transactions) {
        if ([transaction.transactionIdentifier isEqualToString:transactionIdentifier]) {
            if (transaction.transactionState == SKPaymentTransactionStatePurchased) {
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                resolve([NSNull null]);
            } else {
                reject(@"invalid_purchase", nil, nil);
            }
            return;
        }
    }
    reject(@"invalid_purchase", nil, nil);
}


- (void)paymentQueue:(SKPaymentQueue *)queue
restoreCompletedTransactionsFailedWithError:(NSError *)error
{
    NSString *key = RCTKeyForInstance(@"restoreRequest");
    NSDictionary *promiseBlock = _promiseBlocks[key];
    if (promiseBlock) {
        RCTPromiseRejectBlock reject = promiseBlock[@"reject"];
        if (reject) {
            switch (error.code)
            {
                case SKErrorPaymentCancelled:
                    reject(@"user_cancelled", nil, nil);
                    break;
                default:
                    reject(@"restore_failed", nil, nil);
                    break;
            }
        }
        [_promiseBlocks removeObjectForKey:key];
    } else {
        RCTLogWarn(@"No resolver registered for restore product request.");
    }
}

- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue *)queue
{
    NSString *key = RCTKeyForInstance(@"restoreRequest");
    NSDictionary *promiseBlock = _promiseBlocks[key];
    if (promiseBlock) {
        RCTPromiseResolveBlock resolve = promiseBlock[@"resolve"];
        if (resolve) {
            NSMutableArray *productsArrayForJS = [NSMutableArray array];
            for(SKPaymentTransaction *transaction in queue.transactions){
                if(transaction.transactionState == SKPaymentTransactionStateRestored) {

                    NSDictionary *purchase = [self getPurchaseData:transaction];

                    [productsArrayForJS addObject:purchase];
                    [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                }
            }
            resolve(productsArrayForJS);
        }
        [_promiseBlocks removeObjectForKey:key];
    } else {
        RCTLogWarn(@"No resolver registered for restore product request.");
    }
}

RCT_EXPORT_METHOD(restorePurchases:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    NSString *restoreRequest = @"restoreRequest";
    _promiseBlocks[RCTKeyForInstance(restoreRequest)] = @{
                                                          @"resolve": resolve,
                                                          @"reject": reject,
                                                          };
    [[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
}

RCT_EXPORT_METHOD(restorePurchasesForUser:(NSString *)username
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    NSString *restoreRequest = @"restoreRequest";
    if(!username) {
        reject(@"username_required", nil, nil);
        return;
    }
    _promiseBlocks[RCTKeyForInstance(restoreRequest)] = @{
                                                          @"resolve": resolve,
                                                          @"reject": reject,
                                                          };

    [[SKPaymentQueue defaultQueue] restoreCompletedTransactionsWithApplicationUsername:username];
}

RCT_EXPORT_METHOD(loadProducts:(NSArray *)productIdentifiers
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    SKProductsRequest *productsRequest = [[SKProductsRequest alloc]
                                          initWithProductIdentifiers:[NSSet setWithArray:productIdentifiers]];
    productsRequest.delegate = self;
    _promiseBlocks[RCTKeyForInstance(productsRequest)] = @{
                                                           @"resolve": resolve,
                                                           @"reject": reject,
                                                           };;
    [productsRequest start];
}

RCT_EXPORT_METHOD(canMakePayments:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    BOOL canMakePayments = [SKPaymentQueue canMakePayments];
    resolve(@(canMakePayments));
}

RCT_EXPORT_METHOD(receiptData:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    NSURL *receiptUrl = [[NSBundle mainBundle] appStoreReceiptURL];
    NSData *receiptData = [NSData dataWithContentsOfURL:receiptUrl];
    if (!receiptData) {
      reject(@"not_available", nil, nil);
    } else {
      resolve([receiptData base64EncodedStringWithOptions:0]);
    }
}

// SKProductsRequestDelegate protocol method
- (void)productsRequest:(SKProductsRequest *)request
     didReceiveResponse:(SKProductsResponse *)response
{
    NSString *key = RCTKeyForInstance(request);
    NSDictionary *promiseBlock = _promiseBlocks[key];
    if (promiseBlock) {
        RCTPromiseResolveBlock resolve = promiseBlock[@"resolve"];
        if (resolve) {
            products = [NSMutableArray arrayWithArray:response.products];
            NSMutableArray *productsArrayForJS = [NSMutableArray array];
            for(SKProduct *item in response.products) {
                NSDictionary *product = @{
                                          @"identifier": item.productIdentifier,
                                          @"price": item.price,
                                          @"currencySymbol": [item.priceLocale objectForKey:NSLocaleCurrencySymbol],
                                          @"currencyCode": [item.priceLocale objectForKey:NSLocaleCurrencyCode],
                                          @"priceString": item.priceString,
                                          @"countryCode": [item.priceLocale objectForKey: NSLocaleCountryCode],
                                          @"downloadable": item.downloadable ? @"true" : @"false" ,
                                          @"description": item.localizedDescription ? item.localizedDescription : @"",
                                          @"title": item.localizedTitle ? item.localizedTitle : @"",
                                          };
                [productsArrayForJS addObject:product];
            }
            resolve(productsArrayForJS);
        }
        [_promiseBlocks removeObjectForKey:key];
    } else {
        RCTLogWarn(@"No resolver registered for load product request.");
    }
}

// SKProductsRequestDelegate network error
- (void)request:(SKRequest *)request didFailWithError:(NSError *)error{
    NSString *key = RCTKeyForInstance(request);
    NSDictionary *promiseBlock = _promiseBlocks[key];
    if(promiseBlock) {
        RCTPromiseRejectBlock reject = promiseBlock[@"reject"];
        if (reject) {
            reject(@"request_failed", nil, error);
        }
        [_promiseBlocks removeObjectForKey:key];
    }
}

- (NSDictionary *)getPurchaseData:(SKPaymentTransaction *)transaction {
    NSMutableDictionary *purchase = [NSMutableDictionary dictionaryWithDictionary: @{
                                                                                     @"transactionDate": @(transaction.transactionDate.timeIntervalSince1970 * 1000),
                                                                                     @"transactionIdentifier": transaction.transactionIdentifier,
                                                                                     @"productIdentifier": transaction.payment.productIdentifier,
                                                                                     @"transactionReceipt": [[transaction transactionReceipt] base64EncodedStringWithOptions:0]
                                                                                     }];
    // originalTransaction is available for restore purchase and purchase of cancelled/expired subscriptions
    SKPaymentTransaction *originalTransaction = transaction.originalTransaction;
    if (originalTransaction) {
        purchase[@"originalTransactionDate"] = @(originalTransaction.transactionDate.timeIntervalSince1970 * 1000);
        purchase[@"originalTransactionIdentifier"] = originalTransaction.transactionIdentifier;
    }

    return purchase;
}


- (NSDictionary *)getQueuedPurchaseData:(SKPaymentTransaction *)transaction {
    NSMutableDictionary *purchase = [NSMutableDictionary new];
        purchase[@"transactionDate"] = @(transaction.transactionDate.timeIntervalSince1970 * 1000);
        purchase[@"productIdentifier"] = transaction.payment.productIdentifier;
        purchase[@"transactionState"] = StringForTransactionState(transaction.transactionState);

        if (transaction.transactionIdentifier != nil) {
                purchase[@"transactionIdentifier"] = transaction.transactionIdentifier;
        }

        NSString *receipt = [[transaction transactionReceipt] base64EncodedStringWithOptions:0];

        if (receipt != nil) {
            purchase[@"transactionReceipt"] = receipt;
        }

        SKPaymentTransaction *originalTransaction = transaction.originalTransaction;
        if (originalTransaction) {
            purchase[@"originalTransactionDate"] = @(originalTransaction.transactionDate.timeIntervalSince1970 * 1000);
            purchase[@"originalTransactionIdentifier"] = originalTransaction.transactionIdentifier;
        }

    return purchase;
}

- (void)dealloc
{
    [[SKPaymentQueue defaultQueue] removeTransactionObserver:self];
}

#pragma mark Private

static NSString *RCTKeyForInstance(id instance)
{
    return [NSString stringWithFormat:@"%p", instance];
}
    
static NSString *StringForTransactionState(SKPaymentTransactionState state)
{
    switch(state) {
        case SKPaymentTransactionStatePurchasing: return @"purchasing";
        case SKPaymentTransactionStatePurchased: return @"purchased";
        case SKPaymentTransactionStateFailed: return @"failed";
        case SKPaymentTransactionStateRestored: return @"restored";
        case SKPaymentTransactionStateDeferred: return @"deferred";
    }
    
    [NSException raise:NSGenericException format:@"Unexpected SKPaymentTransactionState."];
}

@end
