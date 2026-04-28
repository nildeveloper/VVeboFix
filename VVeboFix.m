#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 调试开关 - 发布时设为 NO
static BOOL const kDebugEnabled = YES;

// 持久化存储键名
static NSString * const kVVeboUIDKey = @"vvebo_uid";

// 日志宏
#define VVeboLog(fmt, ...) if (kDebugEnabled) NSLog(@"[VVeboFix] " fmt, ##__VA_ARGS__)

#pragma mark - 工具函数

static BOOL IsWeiboAPIRequest(NSString *urlString) {
    if (!urlString) return NO;
    return [urlString containsString:@"api.weibo.cn"];
}

static NSString * ExtractUIDFromURL(NSString *urlString) {
    if (!urlString || ![urlString containsString:@"uid"]) {
        return nil;
    }
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"uid=(\\d+)"
                                                                           options:0
                                                                             error:&error];
    if (error) return nil;
    NSTextCheckingResult *match = [regex firstMatchInString:urlString
                                                    options:0
                                                      range:NSMakeRange(0, urlString.length)];
    if (match && match.numberOfRanges > 1) {
        return [urlString substringWithRange:[match rangeAtIndex:1]];
    }
    return nil;
}

static void SaveUID(NSString *uid) {
    if (uid) {
        [[NSUserDefaults standardUserDefaults] setObject:uid forKey:kVVeboUIDKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        VVeboLog(@"Saved UID: %@", uid);
    }
}

static NSString * ReadUID(void) {
    NSString *uid = [[NSUserDefaults standardUserDefaults] objectForKey:kVVeboUIDKey];
    VVeboLog(@"Read UID: %@", uid);
    return uid;
}

static NSData * ProcessProfileStatusesResponse(NSData *originalData, NSString *urlString) {
    @try {
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:originalData options:0 error:nil];
        if (!json || ![json isKindOfClass:[NSDictionary class]]) return originalData;

        NSArray *cards = json[@"cards"];
        if (!cards || ![cards isKindOfClass:[NSArray class]]) return originalData;

        NSMutableArray *statuses = [NSMutableArray array];
        for (id card in cards) {
            id target = card;
            if ([card isKindOfClass:[NSDictionary class]]) {
                NSDictionary *cardDict = (NSDictionary *)card;
                id cardGroup = cardDict[@"card_group"];
                if (cardGroup && [cardGroup isKindOfClass:[NSArray class]]) {
                    target = cardGroup;
                } else {
                    target = @[card];
                }
            }
            if ([target isKindOfClass:[NSArray class]]) {
                for (id item in target) {
                    if ([item isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *itemDict = (NSDictionary *)item;
                        NSNumber *cardType = itemDict[@"card_type"];
                        if (cardType && cardType.integerValue == 9) {
                            NSMutableDictionary *mblog = [itemDict[@"mblog"] mutableCopy];
                            if (mblog) {
                                if (mblog[@"isTop"] && [mblog[@"isTop"] boolValue]) {
                                    mblog[@"label"] = @"置顶";
                                }
                                [statuses addObject:mblog];
                            }
                        }
                    }
                }
            }
        }

        NSDictionary *cardlistInfo = json[@"cardlistInfo"];
        NSString *sinceId = cardlistInfo[@"since_id"];
        NSDictionary *newBody = @{
            @"statuses": statuses,
            @"since_id": sinceId ?: @"",
            @"total_number": @100
        };
        VVeboLog(@"Converted %lu statuses from profile/statuses/tab", (unsigned long)statuses.count);
        return [NSJSONSerialization dataWithJSONObject:newBody options:0 error:nil];
    } @catch (NSException *exception) {
        VVeboLog(@"Error processing profile/statuses/tab: %@", exception);
        return originalData;
    }
}

static NSData * ProcessCardlistResponse(NSData *originalData, NSString *urlString) {
    @try {
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:originalData options:0 error:nil];
        if (!json || ![json isKindOfClass:[NSDictionary class]]) return originalData;

        NSArray *cards = json[@"cards"];
        if (!cards || ![cards isKindOfClass:[NSArray class]]) return originalData;

        BOOL isFansList = NO;
        for (id card in cards) {
            if ([card isKindOfClass:[NSDictionary class]]) {
                NSDictionary *cardDict = (NSDictionary *)card;
                if ([cardDict[@"itemid"] isEqualToString:@"selffans"]) {
                    isFansList = YES;
                    break;
                }
            }
        }
        if (!isFansList) return originalData;

        NSMutableArray *filteredCards = [NSMutableArray array];
        for (id card in cards) {
            if ([card isKindOfClass:[NSDictionary class]]) {
                NSDictionary *cardDict = (NSDictionary *)card;
                if (![cardDict[@"itemid"] isEqualToString:@"INTEREST_PEOPLE2"]) {
                    [filteredCards addObject:card];
                }
            } else {
                [filteredCards addObject:card];
            }
        }

        VVeboLog(@"Filtered fans list: %lu -> %lu cards", (unsigned long)cards.count, (unsigned long)filteredCards.count);
        NSMutableDictionary *newJson = [json mutableCopy];
        newJson[@"cards"] = filteredCards;
        return [NSJSONSerialization dataWithJSONObject:newJson options:0 error:nil];
    } @catch (NSException *exception) {
        VVeboLog(@"Error processing cardlist: %@", exception);
        return originalData;
    }
}

static NSData * ProcessResponseData(NSData *data, NSString *urlString) {
    if (!data || !urlString) return data;
    if ([urlString containsString:@"/2/profile/statuses/tab"]) {
        return ProcessProfileStatusesResponse(data, urlString);
    }
    if ([urlString containsString:@"/2/cardlist"]) {
        return ProcessCardlistResponse(data, urlString);
    }
    return data;
}

#pragma mark - URL 重写辅助

static NSURLRequest * RewriteRequestIfNeeded(NSURLRequest *request) {
    NSString *urlString = request.URL.absoluteString;

    // 提取并保存 UID
    if ([urlString containsString:@"/2/remind/unread_count"] ||
        [urlString containsString:@"/2/users/show"]) {
        NSString *uid = ExtractUIDFromURL(urlString);
        if (uid) SaveUID(uid);
        return request;
    }

    // user_timeline -> profile/statuses/tab
    if ([urlString containsString:@"/2/statuses/user_timeline"]) {
        NSString *uid = ExtractUIDFromURL(urlString) ?: ReadUID();
        NSString *newURLString = [urlString stringByReplacingOccurrencesOfString:@"/2/statuses/user_timeline"
                                                                      withString:@"/2/profile/statuses/tab"];
        newURLString = [newURLString stringByReplacingOccurrencesOfString:@"max_id"
                                                               withString:@"since_id"];
        if (uid) {
            newURLString = [newURLString stringByAppendingFormat:@"&containerid=230413%@_-_WEIBO_SECOND_PROFILE_WEIBO", uid];
        }
        NSMutableURLRequest *newRequest = [request mutableCopy];
        newRequest.URL = [NSURL URLWithString:newURLString];
        VVeboLog(@"Rewrote URL: %@", newURLString);
        return newRequest;
    }

    return request;
}

#pragma mark - VVeboFixURLProtocol（拦截所有网络请求方式）

static NSString * const kVVeboFixHandledKey = @"VVeboFixHandled";

@interface VVeboFixURLProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSession *innerSession;
@property (nonatomic, strong) NSURLSessionDataTask *innerTask;
@property (nonatomic, strong) NSMutableData *receivedData;
@end

@implementation VVeboFixURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    // 避免递归拦截
    if ([NSURLProtocol propertyForKey:kVVeboFixHandledKey inRequest:request]) return NO;
    return IsWeiboAPIRequest(request.URL.absoluteString);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    VVeboLog(@"[Protocol] Intercepted: %@", self.request.URL.absoluteString);

    // 重写 URL（如需要）
    NSURLRequest *rewritten = RewriteRequestIfNeeded(self.request);
    NSMutableURLRequest *mutableRequest = [rewritten mutableCopy];
    // 标记已处理，防止内层 session 再次被拦截
    [NSURLProtocol setProperty:@YES forKey:kVVeboFixHandledKey inRequest:mutableRequest];

    self.receivedData = [NSMutableData data];
    // 内层 session 使用不含我们 protocol 的裸配置
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.protocolClasses = @[];
    self.innerSession = [NSURLSession sessionWithConfiguration:config
                                                      delegate:self
                                                 delegateQueue:nil];
    self.innerTask = [self.innerSession dataTaskWithRequest:mutableRequest];
    [self.innerTask resume];
}

- (void)stopLoading {
    [self.innerTask cancel];
    [self.innerSession invalidateAndCancel];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    [self.receivedData appendData:data];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (error) {
        [self.client URLProtocol:self didFailWithError:error];
    } else {
        NSString *urlString = task.currentRequest.URL.absoluteString;
        NSData *processed = ProcessResponseData(self.receivedData, urlString);
        [self.client URLProtocol:self didLoadData:processed];
        [self.client URLProtocolDidFinishLoading:self];
        VVeboLog(@"[Protocol] Done: %@", urlString);
    }
    [self.innerSession finishTasksAndInvalidate];
}

@end

#pragma mark - NSURLSessionConfiguration Swizzle（注入 Protocol 到所有 Session）

@interface NSURLSessionConfiguration (VVeboFix)
+ (instancetype)vvebo_defaultSessionConfiguration;
+ (instancetype)vvebo_ephemeralSessionConfiguration;
@end

@implementation NSURLSessionConfiguration (VVeboFix)

+ (void)vvebo_injectProtocolInto:(NSURLSessionConfiguration *)config {
    NSMutableArray *protocols = [NSMutableArray arrayWithArray:config.protocolClasses ?: @[]];
    if (![protocols containsObject:[VVeboFixURLProtocol class]]) {
        [protocols insertObject:[VVeboFixURLProtocol class] atIndex:0];
        config.protocolClasses = protocols;
    }
}

+ (instancetype)vvebo_defaultSessionConfiguration {
    NSURLSessionConfiguration *config = [self vvebo_defaultSessionConfiguration];
    [self vvebo_injectProtocolInto:config];
    return config;
}

+ (instancetype)vvebo_ephemeralSessionConfiguration {
    NSURLSessionConfiguration *config = [self vvebo_ephemeralSessionConfiguration];
    [self vvebo_injectProtocolInto:config];
    return config;
}

@end

#pragma mark - Method Swizzling 初始化

static void SwizzleClassMethod(Class cls, SEL originalSel, SEL swizzledSel) {
    Method originalMethod = class_getClassMethod(cls, originalSel);
    Method swizzledMethod = class_getClassMethod(cls, swizzledSel);
    if (!originalMethod || !swizzledMethod) {
        NSLog(@"[VVeboFix] Failed to swizzle class method %@ -> %@",
              NSStringFromSelector(originalSel), NSStringFromSelector(swizzledSel));
        return;
    }
    method_exchangeImplementations(originalMethod, swizzledMethod);
}

__attribute__((constructor))
static void VVeboFixInit(void) {
    VVeboLog(@"Tweak loaded - installing hooks");

    // 1. 全局注册 NSURLProtocol（覆盖 NSURLConnection 和 sharedSession）
    [NSURLProtocol registerClass:[VVeboFixURLProtocol class]];

    // 2. Swizzle NSURLSessionConfiguration，确保所有自定义 Session 也注入 Protocol
    SwizzleClassMethod(
        [NSURLSessionConfiguration class],
        @selector(defaultSessionConfiguration),
        @selector(vvebo_defaultSessionConfiguration)
    );
    SwizzleClassMethod(
        [NSURLSessionConfiguration class],
        @selector(ephemeralSessionConfiguration),
        @selector(vvebo_ephemeralSessionConfiguration)
    );

    VVeboLog(@"All hooks installed");
}

