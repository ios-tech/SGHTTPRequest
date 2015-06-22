//
//  SGHTTPRequest.m
//  SeatGeek
//
//  Created by James Van-As on 31/07/13.
//  Copyright (c) 2013 SeatGeek. All rights reserved.
//

#import "SGHTTPRequest.h"
#import "AFNetworking.h"
#import "SGActivityIndicator.h"
#import "SGHTTPRequestDebug.h"

#define ETAG_CACHE_PATH @"SGHTTPRequestETagCache"

NSMutableDictionary *gReachabilityManagers;
SGActivityIndicator *gNetworkIndicator;
NSMutableDictionary *gRetryQueues;
SGHTTPLogging gLogging = SGHTTPLogNothing;

@interface SGHTTPRequest ()
@property (nonatomic, weak) AFHTTPRequestOperation *operation;
@property (nonatomic, strong) NSData *responseData;
@property (nonatomic, strong) NSString *responseString;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, assign) BOOL cancelled;
@end

void doOnMain(void(^block)()) {
    if (NSThread.isMainThread) { // we're on the main thread. yay
        block();
    } else { // we're off the main thread. Bump off.
        dispatch_async(dispatch_get_main_queue(), ^{
            block();
        });
    }
}

@implementation SGHTTPRequest

#pragma mark - Public

+ (SGHTTPRequest *)requestWithURL:(NSURL *)url {
    return [[self alloc] initWithURL:url method:SGHTTPRequestMethodGet];
}

+ (instancetype)postRequestWithURL:(NSURL *)url {
    return [[self alloc] initWithURL:url method:SGHTTPRequestMethodPost];
}

+ (instancetype)jsonPostRequestWithURL:(NSURL *)url {
    SGHTTPRequest *request = [[self alloc] initWithURL:url method:SGHTTPRequestMethodPost];
    request.requestFormat = SGHTTPDataTypeJSON;
    return request;
}

+ (instancetype)deleteRequestWithURL:(NSURL *)url {
    return [[self alloc] initWithURL:url method:SGHTTPRequestMethodDelete];
}

+ (instancetype)putRequestWithURL:(NSURL *)url {
    return [[self alloc] initWithURL:url method:SGHTTPRequestMethodPut];
}

+ (instancetype)patchRequestWithURL:(NSURL *)url {
    return [[self alloc] initWithURL:url method:SGHTTPRequestMethodPatch];
}

+ (instancetype)xmlPostRequestWithURL:(NSURL *)url {
    SGHTTPRequest *request =  [[self alloc] initWithURL:url method:SGHTTPRequestMethodPut];
    request.requestFormat = SGHTTPDataTypeXML;
    return request;
}

+ (instancetype)xmlRequestWithURL:(NSURL *)url {
    SGHTTPRequest *request =  [[self alloc] initWithURL:url method:SGHTTPRequestMethodGet];
    request.responseFormat = SGHTTPDataTypeXML;
    return request;
}

- (void)start {
    if (!self.url) {
        return;
    }

    NSString *baseURL = [SGHTTPRequest baseURLFrom:self.url];

    if (self.logRequests) {
        NSLog(@"%@", self.url);
    }

    AFHTTPRequestOperationManager *manager = [self.class managerForBaseURL:baseURL
          requestType:self.requestFormat responseType:self.responseFormat];

    if (!manager) {
        [self failedWithError:nil operation:nil retryURL:baseURL];
        return;
    }

    for (NSString *field in self.requestHeaders) {
        [manager.requestSerializer setValue:self.requestHeaders[field] forHTTPHeaderField:field];
    }

    if (self.eTag.length) {
        [manager.requestSerializer setValue:self.eTag forHTTPHeaderField:@"If-None-Match"];
    }

    id success = ^(AFHTTPRequestOperation *operation, id responseObject) {
        [self success:operation];
    };
    id failure = ^(AFHTTPRequestOperation *operation, NSError *error) {
        if (operation.response.statusCode == 304) { // not modified
            [self success:operation];
        } else {
            [self failedWithError:error operation:operation retryURL:baseURL];
        }
    };

    switch (self.method) {
        case SGHTTPRequestMethodGet:
            _operation = [manager GET:self.url.absoluteString parameters:self.parameters
                  success:success failure:failure];
            break;
        case SGHTTPRequestMethodPost:
            _operation = [manager POST:self.url.absoluteString parameters:self.parameters
                  success:success failure:failure];
            break;
        case SGHTTPRequestMethodDelete:
            _operation = [manager DELETE:self.url.absoluteString parameters:self.parameters
                  success:success failure:failure];
            break;
        case SGHTTPRequestMethodPut:
            _operation = [manager PUT:self.url.absoluteString parameters:self.parameters
                  success:success failure:failure];
            break;
        case SGHTTPRequestMethodPatch:
            _operation = [manager PATCH:self.url.absoluteString parameters:self.parameters
                  success:success failure:failure];
            break;
    }

    if (self.showActivityIndicator) {
        [SGHTTPRequest.networkIndicator incrementActivityCount];
    }
}

- (void)cancel {
    _cancelled = YES;

    doOnMain(^{
        if (self.onNetworkReachable) {
           [SGHTTPRequest removeRetryCompletion:self.onNetworkReachable forHost:self.url.host];
            self.onNetworkReachable = nil;
        }
        [_operation cancel]; // will call the failure block
    });
}

#pragma mark - Private

- (id)initWithURL:(NSURL *)url method:(SGHTTPRequestMethod)method {
    self = [super init];

    self.showActivityIndicator = YES;
    self.allowCacheToDisk = SGHTTPRequest.allowCacheToDisk;
    self.method = method;
    self.url = url;

    // by default, use the JSON response serialiser only for SeatGeek API requests
    if ([url.host isEqualToString:@"api.seatgeek.com"]) {
        self.responseFormat = SGHTTPDataTypeJSON;
    } else {
        self.responseFormat = SGHTTPDataTypeHTTP;
    }
    self.logging = gLogging;

    return self;
}

+ (AFHTTPRequestOperationManager *)managerForBaseURL:(NSString *)baseURL
                                         requestType:(SGHTTPDataType)requestType
                                        responseType:(SGHTTPDataType)responseType {
    static dispatch_once_t token = 0;
    dispatch_once(&token, ^{
        gReachabilityManagers = NSMutableDictionary.new;
    });

    NSURL *url = [NSURL URLWithString:baseURL];
    AFHTTPRequestOperationManager *manager = [[AFHTTPRequestOperationManager alloc] initWithBaseURL:url];
    if (!manager) {
        return nil;
    }

    //responses default to JSON
    if (responseType == SGHTTPDataTypeHTTP) {
        manager.responseSerializer = AFHTTPResponseSerializer.serializer;
    } else if (responseType == SGHTTPDataTypeXML) {
        manager.responseSerializer = AFXMLParserResponseSerializer.serializer;
    }

    if (requestType == SGHTTPDataTypeXML) {
        AFHTTPRequestSerializer *requestSerializer = manager.requestSerializer;
        [requestSerializer setValue:@"application/xml" forHTTPHeaderField:@"Content-Type"];
    } else if (requestType == SGHTTPDataTypeJSON) {
        manager.requestSerializer = AFJSONRequestSerializer.serializer;
    }

    if (url.host.length && !gReachabilityManagers[url.host]) {
        AFNetworkReachabilityManager *reacher = [AFNetworkReachabilityManager managerForDomain:url
              .host];
        if (reacher) {
            gReachabilityManagers[url.host] = reacher;

            reacher.reachabilityStatusChangeBlock = ^(AFNetworkReachabilityStatus status) {
                switch (status) {
                    case AFNetworkReachabilityStatusReachableViaWWAN:
                    case AFNetworkReachabilityStatusReachableViaWiFi:
                        [self.class runRetryQueueFor:url.host];
                        break;
                    case AFNetworkReachabilityStatusNotReachable:
                    default:
                        break;
                }
            };
            [reacher startMonitoring];
        }
    }

    return manager;
}

#pragma mark - Success / Fail Handlers

- (void)success:(AFHTTPRequestOperation *)operation {
    self.responseData = operation.responseData;
    self.responseString = operation.responseString;
    self.statusCode = operation.response.statusCode;
    if (!self.cancelled) {
        if (self.logResponses) {
            [self logResponse:operation error:nil];
        }
        NSString *eTag = operation.response.allHeaderFields[@"Etag"];
        if (eTag.length) {
            if (self.statusCode == 304) {
                if (!self.responseData.length && self.allowCacheToDisk) {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        // If we got a 304 and no respose from iOS level caching, check the disk.
                        NSData *cachedData = [self cachedDataForETag:eTag];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (cachedData) {
                                self.responseData = cachedData;
                                self.eTag = eTag;
                                if (self.onSuccess) {
                                    self.onSuccess(self);
                                }
                            } else {
                                self.eTag = nil;
                                [self removeCacheFiles];
                                [self start];   //cached data is missing. try again without eTag
                            }

                        });
                    });
                    return;
                }
            } else if (self.allowCacheToDisk) {
                // response has changed.  Let's cache the new version.
                [self cacheDataForETag:eTag];
            }
        }
        self.eTag = eTag;
        if (self.onSuccess) {
            self.onSuccess(self);
        }
    }
    if (self.showActivityIndicator) {
        [SGHTTPRequest.networkIndicator decrementActivityCount];
    }
}

- (void)failedWithError:(NSError *)error operation:(AFHTTPRequestOperation *)operation
      retryURL:(NSString *)retryURL {
    if (self.showActivityIndicator) {
        [SGHTTPRequest.networkIndicator decrementActivityCount];
    }

    if (self.cancelled) {
        return;
    }

    self.error = error;
    self.responseData = operation.responseData;
    self.responseString = operation.responseString;
    self.statusCode = operation.response.statusCode;

    if (self.logErrors) {
        [self logResponse:operation error:error];
    }

    if (self.onFailure) {
        self.onFailure(self);
    }
    self.error = nil;

    if (self.onNetworkReachable && retryURL) {
        NSURL *url = [NSURL URLWithString:retryURL];
        if (url.host) {
            [[SGHTTPRequest retryQueueFor:url.host] addObject:self.onNetworkReachable];
        }
    }
}

#pragma mark - Getters

- (id)responseJSON {
    return self.responseData
          ? [NSJSONSerialization JSONObjectWithData:self.responseData options:0 error:nil]
          : nil;
}

+ (NSMutableArray *)retryQueueFor:(NSString *)baseURL {
    if (!baseURL) {
        return nil;
    }

    static dispatch_once_t token = 0;
    dispatch_once(&token, ^{
        gRetryQueues = NSMutableDictionary.new;
    });

    NSMutableArray *queue = gRetryQueues[baseURL];
    if (!queue) {
        queue = NSMutableArray.new;
        gRetryQueues[baseURL] = queue;
    }

    return queue;
}

+ (void)runRetryQueueFor:(NSString *)host {
    NSMutableArray *retryQueue = [self retryQueueFor:host];

    NSArray *localCopy = retryQueue.copy;
    [retryQueue removeAllObjects];

    for (SGHTTPRetryBlock retryBlock in localCopy) {
        retryBlock();
    }
}

+ (void)removeRetryCompletion:(SGHTTPRetryBlock)onNetworkReachable forHost:(NSString *)host {
    doOnMain(^{
        if ([[SGHTTPRequest retryQueueFor:host] containsObject:onNetworkReachable]) {
            [[SGHTTPRequest retryQueueFor:host] removeObject:onNetworkReachable];
    }});
}

+ (NSString *)baseURLFrom:(NSURL *)url {
    return [NSString stringWithFormat:@"%@://%@/", url.scheme, url.host];
}

+ (SGActivityIndicator *)networkIndicator {
    if (gNetworkIndicator) {
        return gNetworkIndicator;
    }
    gNetworkIndicator = [[SGActivityIndicator alloc] init];
    return gNetworkIndicator;
}

#pragma mark ETag Caching

- (NSString *)eTag {
    if (_allowCacheToDisk && !_eTag) {
        NSString *indexPath = self.pathForCachedIndex;
        NSDictionary *index = [NSDictionary dictionaryWithContentsOfFile:indexPath];
        _eTag = index[@"eTag"];
    }
    return _eTag;
}

- (NSData *)cachedDataForETag:(NSString *)eTag {
    if (!self.url) {
        return nil;
    }
    NSString *indexPath = self.pathForCachedIndex;
    NSDictionary *index = [NSDictionary dictionaryWithContentsOfFile:indexPath];
    if (![index[@"eTag"] isEqualToString:eTag] || !index[@"dataPath"]) {
        return nil;
    }
    NSString *fullDataPath = [NSString stringWithFormat:@"%@/%@", SGHTTPRequest.cacheFolder, index[@"dataPath"]];
    if (![NSFileManager.defaultManager fileExistsAtPath:fullDataPath]) {
      return nil;
    }
    return [NSData dataWithContentsOfFile:fullDataPath];
}

- (void)cacheDataForETag:(NSString *)eTag {
    SGHTTPAssert([NSThread isMainThread], @"This must be run from the main thread");
    if (!self.url || !eTag.length) {
        return;
    }

    NSData *data = self.responseData;
    if (!data.length) {
        return;
    }

    if (SGHTTPRequest.maxDiskCacheSize) {
        if (data.length  > SGHTTPRequest.maxDiskCacheSizeBytes) {
            return;
        }
        [SGHTTPRequest purgeOldestCacheFilesLeaving:MAX(SGHTTPRequest.maxDiskCacheSizeBytes / 3, data.length * 2)];
    }

    NSString *indexPath = self.pathForCachedIndex;
    NSString *fullDataPath = nil;

    NSDictionary *index = [NSDictionary dictionaryWithContentsOfFile:indexPath];
    if (index[@"dataPath"]) {
        fullDataPath = [NSString stringWithFormat:@"%@/%@", SGHTTPRequest.cacheFolder, index[@"dataPath"]];
    }
    // delete the index file before the data file.  Noone should reference the data file without the index file.
    if ([NSFileManager.defaultManager fileExistsAtPath:indexPath]) {
        [NSFileManager.defaultManager removeItemAtPath:indexPath error:nil];
    }
    if (fullDataPath && [NSFileManager.defaultManager fileExistsAtPath:fullDataPath]) {
        [NSFileManager.defaultManager removeItemAtPath:fullDataPath error:nil];
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // We write the index file last, because noone will try to access the data file unless the
        // index file exists.  The index file gets written last atomically.
        NSCharacterSet *illegalFileNameChars = [NSCharacterSet characterSetWithCharactersInString:@":/"];
        NSString *fileSafeETag = [[eTag componentsSeparatedByCharactersInSet:illegalFileNameChars] componentsJoinedByString:@"-"];
        if (!fileSafeETag.length) {
            return ;
        }
        NSString *shortDataPath = [NSString stringWithFormat:@"Data/%@-%@",
                                   @(self.url.hash),
                                   fileSafeETag];
        NSString *fullDataPath = [NSString stringWithFormat:@"%@/%@", SGHTTPRequest.cacheFolder, shortDataPath];
        if (![data writeToFile:fullDataPath atomically:YES]) {
            return;
        }
        NSDictionary *newIndex = @{@"eTag"     : eTag,
                                   @"dataPath" : shortDataPath};
        [newIndex writeToFile:indexPath atomically:YES];
    });
}

- (void)removeCacheFiles {
    SGHTTPAssert([NSThread isMainThread], @"This must be run from the main thread");
    NSString *indexPath = self.pathForCachedIndex;
    NSDictionary *index = [NSDictionary dictionaryWithContentsOfFile:indexPath];
    if (index[@"dataPath"]) {
        NSString *fullDataPath = [NSString stringWithFormat:@"%@/%@", SGHTTPRequest.cacheFolder, index[@"dataPath"]];
        if ([NSFileManager.defaultManager fileExistsAtPath:fullDataPath]) {
            [NSFileManager.defaultManager removeItemAtPath:fullDataPath error:nil];
        }
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:indexPath]) {
        [NSFileManager.defaultManager removeItemAtPath:indexPath error:nil];
    }
}

- (NSString *)pathForCachedIndex {
    return [NSString stringWithFormat:@"%@/%@", SGHTTPRequest.cacheFolder, @(self.url.hash)];
}

+ (NSUInteger)totalDataCacheSize {
    NSString *dataFolder = [self.cacheFolder stringByAppendingString:@"/Data"];
    NSArray *filesArray = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dataFolder error:nil];
    unsigned long long int fileSize = 0;
    for (NSString *fileName in filesArray) {
        fileSize += [[NSFileManager defaultManager] attributesOfItemAtPath:[dataFolder stringByAppendingPathComponent:fileName]
                                                                                        error:nil].fileSize;
    }
    return fileSize;
}

+ (void)purgeOldestCacheFilesLeaving:(NSInteger)bytesFree {
    SGHTTPAssert([NSThread isMainThread], @"This must be run from the main thread");

    NSInteger existingCacheSize = SGHTTPRequest.totalDataCacheSize;
    if (existingCacheSize + bytesFree < SGHTTPRequest.maxDiskCacheSizeBytes) {
        return;     // we already have enough space thanks.
    }

    NSString *dataFolder = [self.cacheFolder stringByAppendingString:@"/Data"];
    NSArray *dataFilesNamesArray = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dataFolder error:nil];

    NSMutableArray *dataFilesArray = NSMutableArray.new;
    for (NSString *dataFileName in dataFilesNamesArray) {
        [dataFilesArray addObject:[dataFolder stringByAppendingPathComponent:dataFileName]];
    }
    [dataFilesArray sortUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        return [[NSFileManager.defaultManager attributesOfItemAtPath:obj1
                                                         error:nil].fileModificationDate compare:
                [NSFileManager.defaultManager attributesOfItemAtPath:obj2
                                                                 error:nil].fileModificationDate];
       
    }];

    NSInteger bytesToDelete = bytesFree - (SGHTTPRequest.maxDiskCacheSizeBytes - existingCacheSize);
    if (bytesToDelete <= 0) {
        return;
    }
    NSInteger bytesDeleted = 0;
    NSMutableArray *filesToDelete = NSMutableArray.new;

    for (NSString *filePath in dataFilesArray) {
        if (bytesToDelete <= 0) {
            break;
        }
        unsigned long long fileSize = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath
                                                                     error:nil].fileSize;
        [filesToDelete addObject:filePath];
        bytesToDelete -= fileSize;
        bytesDeleted += fileSize;
    }

    if (!filesToDelete.count) {
        return;
    }

    // sort the index files by date modified too for fast search.  Should be almost identical to the data order
    NSString *indexFolder = self.cacheFolder;
    NSMutableArray *indexFileNamesArray = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:indexFolder error:nil].mutableCopy;
    NSMutableArray *indexFilesArray = NSMutableArray.new;
    for (NSString *indexFileName in indexFileNamesArray) {
        [indexFilesArray addObject:[indexFolder stringByAppendingPathComponent:indexFileName]];
    }
    [indexFilesArray sortUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        return [[NSFileManager.defaultManager attributesOfItemAtPath:obj1
                                                               error:nil].fileModificationDate compare:
                [NSFileManager.defaultManager attributesOfItemAtPath:obj2
                                                               error:nil].fileModificationDate];

    }];

#ifdef DEBUG
    if (bytesDeleted) {
        NSLog(@"Flushing %.1fMB from SGHTTPRequest ETag cache", (CGFloat)bytesDeleted / 1024.0 / 1024.0);
    }
#endif

    for (NSString *dataFilePath in filesToDelete) {
        NSString *indexPathToDelete = nil;
        for (NSString *indexFilePath in indexFilesArray) {
            NSDictionary *index = [NSDictionary dictionaryWithContentsOfFile:indexFilePath];
            if (index[@"dataPath"]) {
                NSString *fullDataPath = [NSString stringWithFormat:@"%@/%@", SGHTTPRequest.cacheFolder, index[@"dataPath"]];

                if ([fullDataPath isEqualToString:dataFilePath]) {
                    indexPathToDelete = indexFilePath;
                    break;
                }
            }
        }
        if (indexPathToDelete) {
            [indexFilesArray removeObject:indexPathToDelete];
            if ([NSFileManager.defaultManager fileExistsAtPath:dataFilePath]) {
                [NSFileManager.defaultManager removeItemAtPath:dataFilePath error:nil];
            }
            if ([NSFileManager.defaultManager fileExistsAtPath:indexPathToDelete]) {
                [NSFileManager.defaultManager removeItemAtPath:indexPathToDelete error:nil];
            }
        }
    }
}

+ (NSString *)cacheFolder {
    NSString *path = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask,
                                                         YES)[0];
    path = [path stringByAppendingFormat:@"/%@", ETAG_CACHE_PATH];

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        BOOL isDir;
        NSString *dataPath = [path stringByAppendingString:@"/Data"];
        if (![NSFileManager.defaultManager fileExistsAtPath:dataPath isDirectory:&isDir]) {
            [NSFileManager.defaultManager createDirectoryAtPath:dataPath withIntermediateDirectories:YES
                                                     attributes:nil error:nil];
        }

        NSTimeInterval age = 60 * 60 * 12 * 30; // trash files older than 30 days
        NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil];

        for (NSString *file in files) {
            if ([file isEqualToString:@"."] || [file isEqualToString:@".."]) {
                continue;
            }

            NSString *indexFile = [path stringByAppendingPathComponent:file];
            NSDate *created = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileCreationDate;

            // too old. delete it
            if (-created.timeIntervalSinceNow > age) {
                NSDictionary *index = [NSDictionary dictionaryWithContentsOfFile:indexFile];
                if (index[@"dataPath"]) {
                    NSString *fullDataPath = [NSString stringWithFormat:@"%@/%@", path, index[@"dataPath"]];
                    if ([NSFileManager.defaultManager fileExistsAtPath:fullDataPath]) {
                        [NSFileManager.defaultManager removeItemAtPath:fullDataPath error:nil];
                    }
                }
                [NSFileManager.defaultManager removeItemAtPath:indexFile error:nil];
            }
        }
    });
    return path;
}

static BOOL gAllowCacheToDisk = NO;

+ (void)setAllowCacheToDisk:(BOOL)allowCacheToDisk {
    gAllowCacheToDisk = allowCacheToDisk;
}

+ (BOOL)allowCacheToDisk {
    return gAllowCacheToDisk;
}

static NSUInteger gMaxDiskCacheSize = 20;

+ (void)setMaxDiskCacheSize:(NSUInteger)megaBytes {
    gMaxDiskCacheSize = megaBytes;
}

+ (NSInteger)maxDiskCacheSize {
    return gMaxDiskCacheSize;
}

+ (NSInteger)maxDiskCacheSizeBytes {
    return self.maxDiskCacheSize * 1024 * 1024;
}

#pragma mark Logging

+ (void)setLogging:(SGHTTPLogging)logging {
#ifdef DEBUG
    // Logging in debug builds only.
    gLogging = logging;
#endif
}

- (NSString *)boxUpString:(NSString *)string fatLine:(BOOL)fatLine {
    NSMutableString *boxString = NSMutableString.new;
    NSInteger charsInLine = string.length + 4;

    if (fatLine) {
        [boxString appendString:@"\n╔"];
        [boxString appendString:[@"" stringByPaddingToLength:charsInLine - 2 withString:@"═" startingAtIndex:0]];
        [boxString appendString:@"╗\n"];
        [boxString appendString:[NSString stringWithFormat:@"║ %@ ║\n", string]];
        [boxString appendString:@"╚"];
        [boxString appendString:[@"" stringByPaddingToLength:charsInLine - 2 withString:@"═" startingAtIndex:0]];
        [boxString appendString:@"╝\n"];
    } else {
        [boxString appendString:@"\n┌"];
        [boxString appendString:[@"" stringByPaddingToLength:charsInLine - 2 withString:@"─" startingAtIndex:0]];
        [boxString appendString:@"┐\n"];
        [boxString appendString:[NSString stringWithFormat:@"│ %@ │\n", string]];
        [boxString appendString:@"└"];
        [boxString appendString:[@"" stringByPaddingToLength:charsInLine - 2 withString:@"─" startingAtIndex:0]];
        [boxString appendString:@"┘\n"];
    }
    return boxString;
}

- (void)logResponse:(AFHTTPRequestOperation *)operation error:(NSError *)error {
    NSString *responseString = self.responseString;
    NSObject *requestParameters = self.parameters;
    NSString *requestMethod = operation.request.HTTPMethod ?: @"";

    if (self.responseData &&
        [operation.responseSerializer isKindOfClass:AFJSONResponseSerializer.class] &&
        [NSJSONSerialization isValidJSONObject:operation.responseObject]) {
        NSError *error;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:operation.responseObject
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:&error];
        if (jsonData) {
            responseString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        }
    }
    if (self.parameters &&
        self.requestFormat == SGHTTPDataTypeJSON &&
        [NSJSONSerialization isValidJSONObject:self.parameters]) {
        NSError *error;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:self.parameters
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:&error];
        if (jsonData) {
            requestParameters = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        }
    }

    NSMutableString *output = NSMutableString.new;

    if (error) {
        [output appendString:[self boxUpString:[NSString stringWithFormat:@"HTTP %@ Request failed!", requestMethod]
                                       fatLine:YES]];
    } else {
        [output appendString:[self boxUpString:[NSString stringWithFormat:@"HTTP %@ Request succeeded", requestMethod]
                                       fatLine:YES]];
    }
    [output appendString:[self boxUpString:@"URL:" fatLine:NO]];
    [output appendString:[NSString stringWithFormat:@"%@", self.url]];
    [output appendString:[self boxUpString:@"Request Headers:" fatLine:NO]];
    [output appendString:[NSString stringWithFormat:@"%@", self.requestHeaders]];

    // this prints out POST Data: / PUT data: etc
    [output appendString:[self boxUpString:[NSString stringWithFormat:@"%@ Data:", requestMethod]
                                    fatLine:NO]];
    [output appendString:[NSString stringWithFormat:@"%@", requestParameters]];
    [output appendString:[self boxUpString:@"Status Code:" fatLine:NO]];
    [output appendString:[NSString stringWithFormat:@"%@", @(self.statusCode)]];
    [output appendString:[self boxUpString:@"Response:" fatLine:NO]];
    [output appendString:[NSString stringWithFormat:@"%@", responseString]];

    if (error) {
        [output appendString:[self boxUpString:@"NSError:" fatLine:NO]];
        [output appendString:[NSString stringWithFormat:@"%@", error]];
    }
    [output appendString:@"\n═══════════════════════\n\n"];
    NSLog(@"%@", [NSString stringWithString:output]);
}

- (BOOL)logErrors {
    return (self.logging & SGHTTPLogErrors) || (self.logging & SGHTTPLogResponses);
}

- (BOOL)logRequests {
    return self.logging & SGHTTPLogRequests;
}

- (BOOL)logResponses {
    return self.logging & SGHTTPLogResponses;
}

@end
