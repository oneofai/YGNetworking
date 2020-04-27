//
//  YGEngine.m
//  YGNetworking
//
//  Created by Sun on 2019/4/25.
//  Copyright © 2019 YGNetworking. All rights reserved.
//

#import "YGEngine.h"
#import "YGRequest.h"
#import <objc/runtime.h>

#if __has_include(<AFNetworking/AFNetworking.h>)
#import <AFNetworking/AFNetworking.h>
#import <AFNetworking/AFNetworkActivityIndicatorManager.h>
#else
#import "AFNetworking.h"
#import "AFNetworkActivityIndicatorManager.h"
#endif

static dispatch_queue_t yg_request_completion_callback_queue() {
    static dispatch_queue_t _YG_request_completion_callback_queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _YG_request_completion_callback_queue = dispatch_queue_create("com.ygnetworking.request.completion.callback.queue", DISPATCH_QUEUE_CONCURRENT);
    });
    return _YG_request_completion_callback_queue;
}

static OSStatus YGExtractIdentityAndTrustFromPKCS12(CFDataRef inPKCS12Data, CFStringRef keyPassword, SecIdentityRef *outIdentity, SecTrustRef *outTrust) {
    OSStatus securityError = errSecSuccess;
    
    const void *keys[] = { kSecImportExportPassphrase };
    const void *values[] = { keyPassword };
    CFDictionaryRef optionsDictionary = NULL;
    
    /* Create a dictionary containing the passphrase if one was specified. Otherwise, create an empty dictionary. */
    optionsDictionary = CFDictionaryCreate(NULL, keys, values, (keyPassword ? 1 : 0), NULL, NULL);
    
    CFArrayRef items = CFArrayCreate(NULL, 0, 0, NULL);
    securityError = SecPKCS12Import(inPKCS12Data, optionsDictionary, &items);
    
    if (securityError == 0) {
        CFDictionaryRef myIdentityAndTrust = CFArrayGetValueAtIndex(items, 0);
        const void *tempIdentity = NULL;
        tempIdentity = CFDictionaryGetValue(myIdentityAndTrust, kSecImportItemIdentity);
        CFRetain(tempIdentity);
        *outIdentity = (SecIdentityRef)tempIdentity;
        
        const void *tempTrust = NULL;
        tempTrust = CFDictionaryGetValue (myIdentityAndTrust, kSecImportItemTrust);
        CFRetain(tempTrust);
        *outTrust = (SecTrustRef)tempTrust;
    }
    
    if (optionsDictionary) {
        CFRelease(optionsDictionary);
    }
    
    if (items) {
        CFRelease(items);
    }
    
    return securityError;
}

#pragma mark - YGRequest Binding

@interface NSURLSessionTask (YGRequest)

@property (nonatomic, strong) YGRequest *bindedRequest;

@end

@implementation NSURLSessionTask (YGRequest)

- (YGRequest *)bindedRequest {
    return objc_getAssociatedObject(self, _cmd);
}

- (void)setBindedRequest:(YGRequest *)bindedRequest {
    objc_setAssociatedObject(self, @selector(bindedRequest), bindedRequest, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

#pragma mark - YGEngine

@interface YGEngine () {
    dispatch_semaphore_t _lock;
}

@property (nonatomic, strong) AFURLSessionManager *sessionManager;
@property (nonatomic, strong) AFURLSessionManager *securitySessionManager;

@property (nonatomic, strong) AFHTTPRequestSerializer *afHTTPRequestSerializer;
@property (nonatomic, strong) AFJSONRequestSerializer *afJSONRequestSerializer;
@property (nonatomic, strong) AFPropertyListRequestSerializer *afPListRequestSerializer;

@property (nonatomic, strong) AFHTTPResponseSerializer *afHTTPResponseSerializer;
@property (nonatomic, strong) AFJSONResponseSerializer *afJSONResponseSerializer;
@property (nonatomic, strong) AFXMLParserResponseSerializer *afXMLResponseSerializer;
@property (nonatomic, strong) AFPropertyListResponseSerializer *afPListResponseSerializer;

@property (nonatomic, strong) NSMutableArray *sslPinningHosts;

@end

@implementation YGEngine

+ (instancetype)engine {
    return [[[self class] alloc] init];
}

+ (instancetype)sharedEngine {
    static id sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [self engine];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _lock = dispatch_semaphore_create(1);
    [AFNetworkActivityIndicatorManager sharedManager].enabled = YES;
    
    return self;
}

+ (void)load {
    [[AFNetworkReachabilityManager sharedManager] startMonitoring];
}

- (void)dealloc {
    if (_sessionManager) {
        [_sessionManager invalidateSessionCancelingTasks:YES resetSession:YES];
    }
    if (_securitySessionManager) {
        [_securitySessionManager invalidateSessionCancelingTasks:YES resetSession:YES];
    }
}

#pragma mark - Public Methods

- (void)sendRequest:(YGRequest *)request completionHandler:(YGCompletionHandler)completionHandler {
    if (request.requestType == kYGRequestNormal) {
        [self yg_dataTaskWithRequest:request completionHandler:completionHandler];
    } else if (request.requestType == kYGRequestUpload) {
        [self yg_uploadTaskWithRequest:request completionHandler:completionHandler];
    } else if (request.requestType == kYGRequestDownload) {
        [self yg_downloadTaskWithRequest:request completionHandler:completionHandler];
    } else {
        NSAssert(NO, @"Unknown request type.");
    }
}

- (YGRequest *)cancelRequestByIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return nil;
    
    YG_NETWORKING_LOCK();
    NSArray *tasks = nil;
    if ([identifier hasPrefix:@"+"]) {
        tasks = self.sessionManager.tasks;
    } else if ([identifier hasPrefix:@"-"]) {
        tasks = self.securitySessionManager.tasks;
    }
    __block YGRequest *request = nil;
    if (tasks.count > 0) {
        [tasks enumerateObjectsUsingBlock:^(NSURLSessionTask *task, NSUInteger idx, BOOL *stop) {
            if ([task.bindedRequest.identifier isEqualToString:identifier]) {
                request = task.bindedRequest;
                [task cancel];
                *stop = YES;
            }
        }];
    }
    YG_NETWORKING_UNLOCK();
    return request;
}

- (YGRequest *)getRequestByIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return nil;
    
    YG_NETWORKING_LOCK();
    NSArray *tasks = nil;
    if ([identifier hasPrefix:@"+"]) {
        tasks = self.sessionManager.tasks;
    } else if ([identifier hasPrefix:@"-"]) {
        tasks = self.securitySessionManager.tasks;
    }
    __block YGRequest *request = nil;
    [tasks enumerateObjectsUsingBlock:^(NSURLSessionTask *task, NSUInteger idx, BOOL *stop) {
        if ([task.bindedRequest.identifier isEqualToString:identifier]) {
            request = task.bindedRequest;
            *stop = YES;
        }
    }];
    YG_NETWORKING_UNLOCK();
    return request;
}

- (void)setConcurrentOperationCount:(NSInteger)count {
    if (count < 1) {
        count = 1;
    }
    self.sessionManager.operationQueue.maxConcurrentOperationCount = count;
    self.securitySessionManager.operationQueue.maxConcurrentOperationCount = count;
}

- (NSInteger)reachabilityStatus {
    return [AFNetworkReachabilityManager sharedManager].networkReachabilityStatus;
}

- (void)addSSLPinningURL:(NSString *)url {
    NSParameterAssert(url);
    
    if ([url hasPrefix:@"https"]) {
        NSString *rootDomainName = [self yg_rootDomainNameFromURL:url];
        if (rootDomainName && ![self.sslPinningHosts containsObject:rootDomainName]) {
            [self.sslPinningHosts addObject:rootDomainName];
        }
    }
}

- (void)addSSLPinningCert:(NSData *)cert {
    NSParameterAssert(cert);
    
    NSMutableSet *certSet;
    if (self.securitySessionManager.securityPolicy.pinnedCertificates.count > 0) {
        certSet = [NSMutableSet setWithSet:self.securitySessionManager.securityPolicy.pinnedCertificates];
    } else {
        certSet = [NSMutableSet set];
    }
    [certSet addObject:cert];
    [self.securitySessionManager.securityPolicy setPinnedCertificates:certSet];
}

- (void)addTwowayAuthenticationPKCS12:(NSData *)p12 keyPassword:(NSString *)password {
    NSParameterAssert(p12);
    NSParameterAssert(password);
    
    __weak __typeof(self)weakSelf = self;
    [self.securitySessionManager setSessionDidReceiveAuthenticationChallengeBlock:^NSURLSessionAuthChallengeDisposition(NSURLSession * _Nonnull session, NSURLAuthenticationChallenge * _Nonnull challenge, NSURLCredential *__autoreleasing  _Nullable * _Nullable credential) {
        __strong __typeof(weakSelf)strongSelf = weakSelf;
        NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
        if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
            // Server Trust (SSL Pinning)
            if ([strongSelf.securitySessionManager.securityPolicy evaluateServerTrust:challenge.protectionSpace.serverTrust forDomain:challenge.protectionSpace.host]) {
                *credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
                if (*credential) {
                    disposition = NSURLSessionAuthChallengeUseCredential;
                } else {
                    disposition = NSURLSessionAuthChallengePerformDefaultHandling;
                }
            } else {
                disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
            }
        } else if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodClientCertificate]) {
            // Client Certificate (Two-way Authentication)
            SecIdentityRef identity = NULL;
            SecTrustRef trust = NULL;
            
            if (YGExtractIdentityAndTrustFromPKCS12((__bridge CFDataRef)p12, (__bridge CFStringRef)password, &identity, &trust) == 0) {
                SecCertificateRef certificate = NULL;
                SecIdentityCopyCertificate(identity, &certificate);
                
                const void *certs[] = { certificate };
                CFArrayRef certArray = CFArrayCreate(kCFAllocatorDefault, certs, 1, NULL);
                *credential = [NSURLCredential credentialWithIdentity:identity certificates:(__bridge NSArray *)certArray persistence:NSURLCredentialPersistencePermanent];
                if (*credential) {
                    disposition = NSURLSessionAuthChallengeUseCredential;
                } else {
                    disposition = NSURLSessionAuthChallengePerformDefaultHandling;
                }
                
                if (certificate) {
                    CFRelease(certificate);
                }
                if (certArray) {
                    CFRelease(certArray);
                }
            }
            
            if (identity) {
                CFRelease(identity);
            }
            if (trust) {
                CFRelease(trust);
            }
        } else {
            disposition = NSURLSessionAuthChallengePerformDefaultHandling;
        }
        
        return disposition;
    }];
}

#pragma mark - Private Methods

- (void)yg_dataTaskWithRequest:(YGRequest *)request
             completionHandler:(YGCompletionHandler)completionHandler {
    NSString *httpMethod = nil;
    static dispatch_once_t onceToken;
    static NSArray *httpMethodArray = nil;
    dispatch_once(&onceToken, ^{
        httpMethodArray = @[@"GET", @"POST", @"HEAD", @"DELETE", @"PUT", @"PATCH"];
    });
    if (request.httpMethod >= 0 && request.httpMethod < httpMethodArray.count) {
        httpMethod = httpMethodArray[request.httpMethod];
    }
    NSAssert(httpMethod.length > 0, @"The HTTP method not found.");
    
    AFURLSessionManager *sessionManager = [self yg_getSessionManager:request];
    AFHTTPRequestSerializer *requestSerializer = [self yg_getRequestSerializer:request];
    
    NSError *serializationError = nil;
    NSMutableURLRequest *urlRequest = [requestSerializer requestWithMethod:httpMethod
                                                                 URLString:request.url
                                                                parameters:request.parameters
                                                                     error:&serializationError];
    
    if (serializationError) {
        if (completionHandler) {
            dispatch_async(yg_request_completion_callback_queue(), ^{
                completionHandler(nil, serializationError);
            });
        }
        return;
    }
    
    [self yg_processURLRequest:urlRequest byYGRequest:request];
    
    NSURLSessionDataTask *dataTask = nil;
    __weak __typeof(self)weakSelf = self;
    dataTask = [sessionManager dataTaskWithRequest:urlRequest
                                    uploadProgress:nil
                                  downloadProgress:nil
                                 completionHandler:^(NSURLResponse *response, id responseObject, NSError *error) {
                                     __strong __typeof(weakSelf)strongSelf = weakSelf;
                                     [strongSelf yg_processResponse:response
                                                             object:responseObject
                                                              error:error
                                                            request:request
                                                  completionHandler:completionHandler];
                                 }];
    
    [self yg_setIdentifierForReqeust:request taskIdentifier:dataTask.taskIdentifier sessionManager:sessionManager];
    [dataTask setBindedRequest:request];
    [dataTask resume];
}

- (void)yg_uploadTaskWithRequest:(YGRequest *)request
               completionHandler:(YGCompletionHandler)completionHandler {
    
    AFURLSessionManager *sessionManager = [self yg_getSessionManager:request];
    AFHTTPRequestSerializer *requestSerializer = [self yg_getRequestSerializer:request];
    
    __block NSError *serializationError = nil;
    NSMutableURLRequest *urlRequest = [requestSerializer multipartFormRequestWithMethod:@"POST"
                                                                              URLString:request.url
                                                                             parameters:request.parameters
                                                              constructingBodyWithBlock:^(id<AFMultipartFormData> formData) {
        [request.uploadFormDatas enumerateObjectsUsingBlock:^(YGUploadFormData *obj, NSUInteger idx, BOOL *stop) {
            if (obj.fileData) {
                if (obj.fileName && obj.mimeType) {
                    [formData appendPartWithFileData:obj.fileData name:obj.name fileName:obj.fileName mimeType:obj.mimeType];
                } else {
                    [formData appendPartWithFormData:obj.fileData name:obj.name];
                }
            } else if (obj.fileURL) {
                NSError *fileError = nil;
                if (obj.fileName && obj.mimeType) {
                    [formData appendPartWithFileURL:obj.fileURL name:obj.name fileName:obj.fileName mimeType:obj.mimeType error:&fileError];
                } else {
                    [formData appendPartWithFileURL:obj.fileURL name:obj.name error:&fileError];
                }
                if (fileError) {
                    serializationError = fileError;
                    *stop = YES;
                }
            }
        }];
    } error:&serializationError];
    
    if (serializationError) {
        if (completionHandler) {
            dispatch_async(yg_request_completion_callback_queue(), ^{
                completionHandler(nil, serializationError);
            });
        }
        return;
    }
    
    [self yg_processURLRequest:urlRequest byYGRequest:request];
    
    NSURLSessionUploadTask *uploadTask = nil;
    __weak __typeof(self)weakSelf = self;
    uploadTask = [sessionManager uploadTaskWithStreamedRequest:urlRequest
                                                      progress:request.progressBlock
                                             completionHandler:^(NSURLResponse *response, id responseObject, NSError *error) {
        __strong __typeof(weakSelf)strongSelf = weakSelf;
        [strongSelf yg_processResponse:response
                                object:responseObject
                                 error:error
                               request:request
                     completionHandler:completionHandler];
    }];
    
    [self yg_setIdentifierForReqeust:request taskIdentifier:uploadTask.taskIdentifier sessionManager:sessionManager];
    [uploadTask setBindedRequest:request];
    [uploadTask resume];
}

- (void)yg_downloadTaskWithRequest:(YGRequest *)request
                 completionHandler:(YGCompletionHandler)completionHandler {
    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:request.url]];
    [self yg_processURLRequest:urlRequest byYGRequest:request];
    
    NSURL *downloadFileSavePath;
    BOOL isDirectory;
    if(![[NSFileManager defaultManager] fileExistsAtPath:request.downloadSavePath isDirectory:&isDirectory]) {
        isDirectory = NO;
    }
    if (isDirectory) {
        NSString *fileName = [urlRequest.URL lastPathComponent];
        downloadFileSavePath = [NSURL fileURLWithPath:[NSString pathWithComponents:@[request.downloadSavePath, fileName]] isDirectory:NO];
    } else {
        downloadFileSavePath = [NSURL fileURLWithPath:request.downloadSavePath isDirectory:NO];
    }
    
    NSURLSessionDownloadTask *downloadTask = nil;
    AFURLSessionManager *sessionManager = [self yg_getSessionManager:request];
    downloadTask = [sessionManager downloadTaskWithRequest:urlRequest
                                                  progress:request.progressBlock
                                               destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
                                                   return downloadFileSavePath;
                                               }
                                         completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
                                                    if (completionHandler) {
                                                        completionHandler(filePath, error);
                                                    }
                                         }];
    
    [self yg_setIdentifierForReqeust:request taskIdentifier:downloadTask.taskIdentifier sessionManager:sessionManager];
    [downloadTask setBindedRequest:request];
    [downloadTask resume];
}

- (void)yg_processURLRequest:(NSMutableURLRequest *)urlRequest byYGRequest:(YGRequest *)request {
    if (request.headers.count > 0) {
        [request.headers enumerateKeysAndObjectsUsingBlock:^(id field, id value, BOOL * __unused stop) {
            //if (![urlRequest valueForHTTPHeaderField:field]) {
                [urlRequest setValue:value forHTTPHeaderField:field];
            //}
        }];
    }
    urlRequest.timeoutInterval = request.timeoutInterval;
}

- (void)yg_processResponse:(NSURLResponse *)response
                    object:(id)responseObject
                     error:(NSError *)error
                   request:(YGRequest *)request
         completionHandler:(YGCompletionHandler)completionHandler {
    NSError *serializationError = nil;
    if (request.responseSerializerType != kYGResponseSerializerRAW) {
        AFHTTPResponseSerializer *responseSerializer = [self yg_getResponseSerializer:request];
        responseObject = [responseSerializer responseObjectForResponse:response data:responseObject error:&serializationError];
    }
    
    if (completionHandler) {
        if (serializationError) {
            completionHandler(nil, serializationError);
        } else {
            completionHandler(responseObject, error);
        }
    }
}

- (void)yg_setIdentifierForReqeust:(YGRequest *)request
                    taskIdentifier:(NSUInteger)taskIdentifier
                    sessionManager:(AFURLSessionManager *)sessionManager {
    NSString *identifier = nil;
    if ([sessionManager isEqual:self.sessionManager]) {
        identifier = [NSString stringWithFormat:@"+%lu", (unsigned long)taskIdentifier];
    } else if ([sessionManager isEqual:self.securitySessionManager]) {
        identifier = [NSString stringWithFormat:@"-%lu", (unsigned long)taskIdentifier];
    }
    [request setValue:identifier forKey:@"_identifier"];
}

- (NSString *)yg_rootDomainNameFromURL:(NSString *)urlString {
    NSString *host = [[NSURL URLWithString:urlString] host];
    // Separate the host into its constituent components, e.g. [@"secure", @"twitter", @"com"]
    NSArray * hostComponents = [host componentsSeparatedByString:@"."];
    if ([hostComponents count] >= 2) {
        // Create a string out of the last two components in the host name, e.g. @"twitter" and @"com"
        host = [NSString stringWithFormat:@"%@.%@", [hostComponents objectAtIndex:(hostComponents.count - 2)], [hostComponents objectAtIndex:(hostComponents.count - 1)]];
    }
    return host;
}

- (BOOL)yg_shouldSSLPinningWithURL:(NSString *)urlString {
    if (urlString && [urlString hasPrefix:@"https"]) {
        NSString *rootDomainName = [self yg_rootDomainNameFromURL:urlString];
        if ([self.sslPinningHosts containsObject:rootDomainName]) {
            return YES;
        }
    }
    return NO;
}

- (AFURLSessionManager *)yg_getSessionManager:(YGRequest *)request {
    if ([self yg_shouldSSLPinningWithURL:request.url]) {
        return self.securitySessionManager;
    } else {
        return self.sessionManager;
    }
}

- (AFHTTPRequestSerializer *)yg_getRequestSerializer:(YGRequest *)request {
    if (request.requestSerializerType == kYGRequestSerializerRAW) {
        return self.afHTTPRequestSerializer;
    } else if(request.requestSerializerType == kYGRequestSerializerJSON) {
        return self.afJSONRequestSerializer;
    } else if (request.requestSerializerType == kYGRequestSerializerPlist) {
        return self.afPListRequestSerializer;
    } else {
        NSAssert(NO, @"Unknown request serializer type.");
        return nil;
    }
}

- (AFHTTPResponseSerializer *)yg_getResponseSerializer:(YGRequest *)request {
    if (request.responseSerializerType == kYGResponseSerializerRAW) {
        return self.afHTTPResponseSerializer;
    } else if (request.responseSerializerType == kYGResponseSerializerJSON) {
        return self.afJSONResponseSerializer;
    } else if (request.responseSerializerType == kYGResponseSerializerPlist) {
        return self.afPListResponseSerializer;
    } else if (request.responseSerializerType == kYGResponseSerializerXML) {
        return self.afXMLResponseSerializer;
    } else {
        NSAssert(NO, @"Unknown response serializer type.");
        return nil;
    }
}

#pragma mark - Accessor

- (AFURLSessionManager *)sessionManager {
    if (!_sessionManager) {
        _sessionManager = [[AFURLSessionManager alloc] initWithSessionConfiguration:nil];
        _sessionManager.responseSerializer = self.afHTTPResponseSerializer;
        _sessionManager.operationQueue.maxConcurrentOperationCount = 5;
        _sessionManager.completionQueue = yg_request_completion_callback_queue();
    }
    return _sessionManager;
}

- (AFURLSessionManager *)securitySessionManager {
    if (!_securitySessionManager) {
        _securitySessionManager = [[AFURLSessionManager alloc] initWithSessionConfiguration:nil];
        _securitySessionManager.responseSerializer = self.afHTTPResponseSerializer;
        _securitySessionManager.securityPolicy = [AFSecurityPolicy policyWithPinningMode:AFSSLPinningModeCertificate];
        _securitySessionManager.operationQueue.maxConcurrentOperationCount = 5;
        _securitySessionManager.completionQueue = yg_request_completion_callback_queue();
    }
    return _securitySessionManager;
}

- (AFHTTPRequestSerializer *)afHTTPRequestSerializer {
    if (!_afHTTPRequestSerializer) {
        _afHTTPRequestSerializer = [AFHTTPRequestSerializer serializer];
        
    }
    return _afHTTPRequestSerializer;
}

- (AFJSONRequestSerializer *)afJSONRequestSerializer {
    if (!_afJSONRequestSerializer) {
        _afJSONRequestSerializer = [AFJSONRequestSerializer serializer];
        
    }
    return _afJSONRequestSerializer;
}

- (AFPropertyListRequestSerializer *)afPListRequestSerializer {
    if (!_afPListRequestSerializer) {
        _afPListRequestSerializer = [AFPropertyListRequestSerializer serializer];
    }
    return _afPListRequestSerializer;
}

- (AFHTTPResponseSerializer *)afHTTPResponseSerializer {
    if (!_afHTTPResponseSerializer) {
        _afHTTPResponseSerializer = [AFHTTPResponseSerializer serializer];
    }
    return _afHTTPResponseSerializer;
}

- (AFJSONResponseSerializer *)afJSONResponseSerializer {
    if (!_afJSONResponseSerializer) {
        _afJSONResponseSerializer = [AFJSONResponseSerializer serializer];
        // Append more other commonly-used types to the JSON responses accepted MIME types.
        //_afJSONResponseSerializer.acceptableContentTypes = [NSSet setWithObjects:@"application/json", @"text/json", @"text/javascript", @"text/html", @"text/plain", nil];
    }
    return _afJSONResponseSerializer;
}

- (AFXMLParserResponseSerializer *)afXMLResponseSerializer {
    if (!_afXMLResponseSerializer) {
        _afXMLResponseSerializer = [AFXMLParserResponseSerializer serializer];
    }
    return _afXMLResponseSerializer;
}

- (AFPropertyListResponseSerializer *)afPListResponseSerializer {
    if (!_afPListResponseSerializer) {
        _afPListResponseSerializer = [AFPropertyListResponseSerializer serializer];
    }
    return _afPListResponseSerializer;
}

- (NSMutableArray *)sslPinningHosts {
    if (!_sslPinningHosts) {
        _sslPinningHosts = [NSMutableArray array];
    }
    return _sslPinningHosts;
}

@end
