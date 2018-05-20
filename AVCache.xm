#import <objc/runtime.h>
#import <dlfcn.h>
#import <substrate.h>

#import <AVFoundation/AVFoundation.h>
#import <MobileCoreServices/MobileCoreServices.h>

@interface AVCacheBufferSave : NSObject <AVAssetResourceLoaderDelegate>
@property (nonatomic, copy) NSURL *urlVideo;
@property (nonatomic, copy) NSString *urlVideoID;
@property (nonatomic, strong) NSMutableArray *pendingRequests;
@property (nonatomic, strong) NSMutableArray *pendingRequestsSeeker;
@property (nonatomic, strong) NSURLConnection *connection;
@property (nonatomic, strong) NSHTTPURLResponse *response;
@property (nonatomic, strong) NSFileHandle *fileHandle;
@property (nonatomic, copy) NSString *path_tmp;
@property (assign) NSUInteger downloadedBytes;
@property (assign) NSUInteger totalLenBytes;
@property (assign) BOOL isInLoopRequest;
@property (assign) BOOL requestCancel;
@property (assign) BOOL isCanceled;

+ (NSString*)videoIDWithURL:(NSURL*)url;
+ (id)cacheBufferWithURL:(NSURL*)url;
+ (void)cancelAllDownloadsExceptForURL:(NSURL*)url;
@end

@interface NSHTTPURLResponse ()
- (int)maxExpectedContentLength;
@end

@interface AVCacheBuffeSeeker : NSObject
@property (nonatomic, copy) NSURL *urlVideo;
@property (assign) NSURLConnection *connection;
@property (nonatomic, strong) NSHTTPURLResponse *response;
@property (assign) AVAssetResourceLoadingRequest *loadingRequest;
@property (assign) AVCacheBufferSave *fromAVCacheBufferSave;
@property (assign) int bytesReceived;
- (void)startDowloading;
@end

@implementation AVCacheBuffeSeeker
@synthesize connection, loadingRequest, urlVideo, response, fromAVCacheBufferSave, bytesReceived;
- (void)connection:(NSURLConnection *)connectionA didReceiveResponse:(NSURLResponse *)responseA
{
	self.response = (NSHTTPURLResponse*)responseA;
	if(!(self.response.statusCode==200 || self.response.statusCode==206)) {
		[connectionA cancel];
	}
}
- (void)connection:(NSURLConnection *)connectionA didReceiveData:(NSData *)data
{
	if(loadingRequest.cancelled || fromAVCacheBufferSave.requestCancel) {
		[connectionA cancel];
	}
	[loadingRequest.dataRequest respondWithData:data];
	bytesReceived += [data length];
}
- (void)connectionDidFinishLoading:(NSURLConnection *)connectionA
{
	if(!loadingRequest.cancelled) {
		[loadingRequest finishLoading];
	}
}
- (void)connection:(NSURLConnection *)connectionA didFailWithError:(NSError *)error
{
	dispatch_async(dispatch_get_main_queue(), ^{
		UIAlertView *myAlert = [[UIAlertView alloc] initWithTitle:@"MBCache"
		message:[error localizedDescription]
		delegate:self
		cancelButtonTitle:@"Cancel"
		otherButtonTitles:@"Retry", nil];
		[myAlert show];
	});
}
- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
	if(buttonIndex!=[alertView cancelButtonIndex]) {
		[self startDowloading];
	}
}
- (void)startDowloading
{
	NSMutableURLRequest *request = [[NSMutableURLRequest alloc] init];
	request.URL = urlVideo;
	
	long long startOffset = loadingRequest.dataRequest.requestedOffset;
	if (loadingRequest.dataRequest.currentOffset != 0) {
		startOffset = loadingRequest.dataRequest.currentOffset;
	}
	
	[request setValue:[NSString stringWithFormat:@"bytes=%d-%d", (int)(startOffset + bytesReceived), (int)(startOffset + loadingRequest.dataRequest.requestedLength)] forHTTPHeaderField:@"Range"];
	if(self.connection!=nil) {
		[self.connection cancel];
	}
	self.connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
	[self.connection setDelegateQueue:[[NSOperationQueue alloc] init]];
	[self.connection start];
}
@end





static __strong NSMutableArray* cacheBufferLiveInstances = [[NSMutableArray alloc] init];

@implementation AVCacheBufferSave
@synthesize urlVideo, urlVideoID, pendingRequests, connection, response, fileHandle, path_tmp, downloadedBytes, totalLenBytes, isInLoopRequest, requestCancel, isCanceled;
@synthesize pendingRequestsSeeker;

+ (NSString*)videoIDWithURL:(NSURL*)url
{
	NSArray* compUrl = [url pathComponents];
	return [NSString stringWithFormat:@"%@_%@", [compUrl count]>6?compUrl[7]:nil, [url lastPathComponent]];
}
+ (NSString*)getPathTempForFile:(NSString*)filename
{
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
	NSString *documentsDirectory = [paths objectAtIndex:0];
	NSString *dataPath = [documentsDirectory stringByAppendingPathComponent:@"BufferCache"];
	if (![[NSFileManager defaultManager] fileExistsAtPath:dataPath]) {
		[[NSFileManager defaultManager] createDirectoryAtPath:dataPath withIntermediateDirectories:NO attributes:nil error:nil];
	}
	return [[NSString alloc] initWithString:[NSString stringWithFormat:@"%@/%@",dataPath, filename]];
}
+ (id)cacheBufferWithURL:(NSURL*)url
{
	NSString* urlVideoIDInit = [self videoIDWithURL:url];
	for(AVCacheBufferSave* curr in cacheBufferLiveInstances) {
		if(curr.urlVideoID) {
			if([curr.urlVideoID isEqualToString:urlVideoIDInit]) {
				return curr;
			}
		}
	}
	AVCacheBufferSave* ret = [[[self class] alloc] init];
	ret.urlVideoID = urlVideoIDInit;
	ret.urlVideo = [url copy];
	ret.path_tmp = [self getPathTempForFile:urlVideoIDInit];
	return ret;
}
+ (void)cancelAllDownloadsExceptForURL:(NSURL*)url
{
	AVCacheBufferSave* cacheCurr = [self cacheBufferWithURL:url];
	for(AVCacheBufferSave* curr in cacheBufferLiveInstances) {
		if(cacheCurr==curr) {
			continue;
		}
		curr.requestCancel = YES;
	}
}
- (id)init
{
	self = [super init];
	self.pendingRequests = [NSMutableArray array];
	self.pendingRequestsSeeker = [NSMutableArray array];
	[cacheBufferLiveInstances addObject:self];
	[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(processPendingRequests) userInfo:nil repeats:YES];
	return self;
}

- (void)dalloc
{
	[cacheBufferLiveInstances removeObject:self];
}

- (void)connection:(NSURLConnection *)connectionA didReceiveResponse:(NSURLResponse *)responseA
{
	if(connectionA==self.connection) {
		self.response = (NSHTTPURLResponse *)responseA;
		self.totalLenBytes = (int)[self.response maxExpectedContentLength];
		if(self.response.statusCode==200 || self.response.statusCode==206) {
			if(self.downloadedBytes >= self.totalLenBytes) {
				[connectionA cancel];
				if(self.fileHandle) {
					[self.fileHandle closeFile];
				}
			}
		} else {
			self.totalLenBytes = self.downloadedBytes;
			[connectionA cancel];
			if(self.fileHandle) {
				[self.fileHandle closeFile];
			}
		}
	}
}
- (void)connection:(NSURLConnection *)connectionA didReceiveData:(NSData *)data
{
	if(connectionA==self.connection) {
		[self.fileHandle seekToEndOfFile];
		[self.fileHandle writeData:data];
		[self.fileHandle synchronizeFile];
		self.downloadedBytes = [self.fileHandle offsetInFile] + data.length;
		if(requestCancel) {
			[connectionA cancel];
			[self.fileHandle closeFile];
			isCanceled = YES;
		}
	}
}
- (void)connectionDidFinishLoading:(NSURLConnection *)connectionA
{
	if(connectionA==self.connection) {
		if(self.fileHandle) {
			[self.fileHandle closeFile];
		}
	}
}
- (void)connection:(NSURLConnection *)connectionA didFailWithError:(NSError *)error
{
	dispatch_async(dispatch_get_main_queue(), ^{
		UIAlertView *myAlert = [[UIAlertView alloc] initWithTitle:@"MBCache"
		message:[error localizedDescription]
		delegate:self
		cancelButtonTitle:@"Cancel"
		otherButtonTitles:@"Retry", nil];
		[myAlert show];
	});
}




- (void)startDowloading
{
	if (![[NSFileManager defaultManager] fileExistsAtPath:self.path_tmp]) {
		[[NSFileManager defaultManager] createFileAtPath:self.path_tmp contents:nil attributes:nil];
		self.fileHandle = [NSFileHandle fileHandleForWritingAtPath:self.path_tmp];
		[self.fileHandle truncateFileAtOffset:0];
	} else {
		self.fileHandle = [NSFileHandle fileHandleForWritingAtPath:self.path_tmp];
	}
	NSMutableURLRequest *request = [[NSMutableURLRequest alloc] init];
	request.URL = urlVideo;
	if(self.fileHandle) {
		[self.fileHandle seekToEndOfFile];
		self.downloadedBytes = [self.fileHandle offsetInFile];
		if(self.downloadedBytes > 0) {
			[request setValue:[NSString stringWithFormat:@"bytes=%d-", (int)self.downloadedBytes] forHTTPHeaderField:@"Range"];
		}
	}
	self.connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
	[self.connection setDelegateQueue:[[NSOperationQueue alloc] init]];
	[self.connection start];
}


- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
	if(buttonIndex!=[alertView cancelButtonIndex]) {
		[self startDowloading];
	}
}

- (void)processPendingRequests
{
	if(isInLoopRequest) {
		return;
	}
	isInLoopRequest = YES;
	NSMutableArray *requestsCompleted = [NSMutableArray array];
	for (AVAssetResourceLoadingRequest *loadingRequest in self.pendingRequests) {
		if(loadingRequest.cancelled) {
			[requestsCompleted addObject:loadingRequest];
			continue;
		}
		[self fillInContentInformation:loadingRequest.contentInformationRequest];
		if(self.response!=nil) {
			long long startOffset = loadingRequest.dataRequest.requestedOffset;
			if (loadingRequest.dataRequest.currentOffset != 0) {
				startOffset = loadingRequest.dataRequest.currentOffset;
			}
			if(self.downloadedBytes < startOffset) {
				[requestsCompleted addObject:loadingRequest];
				[self.pendingRequestsSeeker addObject:loadingRequest];
				AVCacheBuffeSeeker* buffSeeker = [AVCacheBuffeSeeker new];
				buffSeeker.loadingRequest = loadingRequest;
				buffSeeker.urlVideo = self.urlVideo;
				buffSeeker.fromAVCacheBufferSave = self;
				[buffSeeker startDowloading];
			}
		}
		
		BOOL didRespondCompletely = [self respondWithDataForRequest:loadingRequest.dataRequest fromOffset:NO];
		if(didRespondCompletely) {
			[requestsCompleted addObject:loadingRequest];
			[loadingRequest finishLoading];
		}
	}
	[self.pendingRequests removeObjectsInArray:requestsCompleted];
	isInLoopRequest = NO;
}

- (void)fillInContentInformation:(AVAssetResourceLoadingContentInformationRequest *)contentInformationRequest
{
    if(contentInformationRequest == nil) {
        return;
    }
    if(self.response != nil) {
		NSString *mimeType = [self.response MIMEType];
		CFStringRef contentType = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, (__bridge CFStringRef)(mimeType), NULL);
		contentInformationRequest.contentType = CFBridgingRelease(contentType);
	}
    contentInformationRequest.byteRangeAccessSupported = YES;
    contentInformationRequest.contentLength = self.totalLenBytes;
}
- (NSData *)dataFromFileInRange:(NSRange)range
{
    NSFileHandle *fileHandleRead = [NSFileHandle fileHandleForReadingAtPath:self.path_tmp];
    [fileHandleRead seekToFileOffset:range.location];
    return [fileHandleRead readDataOfLength:range.length];
}

- (BOOL)respondWithDataForRequest:(AVAssetResourceLoadingDataRequest *)dataRequest fromOffset:(BOOL)isFromOffset
{
	long long startOffset = dataRequest.requestedOffset;
	if (dataRequest.currentOffset != 0) {
		startOffset = dataRequest.currentOffset;
    }
    if ((self.downloadedBytes==0) || (self.downloadedBytes < startOffset) || self.response==nil) {
        return NO;
    }
	
    NSUInteger unreadBytes = self.downloadedBytes - (NSUInteger)startOffset;
    NSUInteger numberOfBytesToRespondWith = MIN((NSUInteger)dataRequest.requestedLength, unreadBytes);
    
	NSRange range = NSMakeRange((NSUInteger)startOffset, numberOfBytesToRespondWith);
	NSData *subData = [self dataFromFileInRange:range];
    [dataRequest respondWithData:subData];
	
    long long endOffset = startOffset + dataRequest.requestedLength;
    BOOL didRespondFully = self.downloadedBytes >= endOffset;
    return didRespondFully;
}



- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest
{	
	[self.pendingRequests addObject:loadingRequest];
	if(self.connection == nil || ![[NSFileManager defaultManager] fileExistsAtPath:self.path_tmp] || (requestCancel&&isCanceled) ) {
		requestCancel = NO;
		isCanceled = NO;
		[self startDowloading];
    }
	
	return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest
{
	[self.pendingRequests removeObject:loadingRequest];
}
@end


%hook AVURLAsset
+ (id)assetWithURL:(NSURL*)URL
{
	if(URL) {
		NSString* urlSt = [URL absoluteString];
		if([urlSt hasPrefix:@"http://"]) {
			AVCacheBufferSave* initCacheBufferSave = [AVCacheBufferSave cacheBufferWithURL:URL];
			urlSt = [@"AVCacheBufferSave://" stringByAppendingString:[urlSt substringFromIndex:7]];
			URL = [NSURL URLWithString:urlSt];
			AVURLAsset* ret = %orig(URL);
			[ret.resourceLoader setDelegate:initCacheBufferSave queue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
			return ret;
		}
	}
	return %orig;
}
+ (id)URLAssetWithURL:(id)URL options:(id)arg2
{
	if(URL) {
		NSString* urlSt = [URL absoluteString];
		if([urlSt hasPrefix:@"http://"]) {
			AVCacheBufferSave* initCacheBufferSave = [AVCacheBufferSave cacheBufferWithURL:URL];
			urlSt = [@"AVCacheBufferSave://" stringByAppendingString:[urlSt substringFromIndex:7]];
			URL = [NSURL URLWithString:urlSt];
			AVURLAsset* ret = %orig(URL, arg2);
			[ret.resourceLoader setDelegate:initCacheBufferSave queue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
			return ret;
		}
	}
	return %orig;
}
%end


#import <MediaPlayer/MPMoviePlayerController.h>

@interface NativePlayerViewController : UIViewController
@property (nonatomic, copy) UISlider *topToolbar;
@property (nonatomic, copy) UISlider *prosressSlider;
@property (nonatomic, copy) MPMoviePlayerController *mediaPlayer;
@end

%hook NativePlayerViewController
- (void)playVideoWithURL:(id)arg1 subtitlesFilePath:(id)arg2 subtitlesDelay:(id)arg3 streamMode:(BOOL)arg4 initialPlaybackTime:(CGFloat)arg5 canGoToNextVideo:(BOOL)arg6 canGoToPrevVideo:(BOOL)arg7
{
	%orig;
	
	static NSTimer* timerHere;
	if(timerHere && timerHere.isValid) {
		[timerHere invalidate];
	}
	timerHere = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(updateBufferProgress) userInfo:nil repeats:YES];
	
	UISlider* prosressSlider = [(NativePlayerViewController*)self topToolbar];
	if(prosressSlider) {
		static __strong UIProgressView* progressBuffer = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
		[progressBuffer setAutoresizingMask:(UIViewAutoresizingFlexibleWidth)];
		progressBuffer.tag = 5659;
		progressBuffer.progress = 0.0f;
		progressBuffer.backgroundColor = [UIColor blackColor];
		progressBuffer.progressTintColor = [UIColor lightTextColor];
		progressBuffer.frame = CGRectMake(0 , prosressSlider.frame.size.height - 5, prosressSlider.frame.size.width , 10);
		progressBuffer.layer.cornerRadius = prosressSlider.layer.cornerRadius;
		progressBuffer.layer.masksToBounds = YES;
		progressBuffer.hidden = NO;
		if(UIView* tgView = [prosressSlider viewWithTag:5659]) {
			[tgView removeFromSuperview];
		}
		[prosressSlider addSubview:progressBuffer];
		[prosressSlider sendSubviewToBack:progressBuffer];
	}	
}
- (void)viewWillDisappear:(BOOL)arg1
{
	MPMoviePlayerController* mediaPlayer = [(NativePlayerViewController*)self mediaPlayer];
	if(mediaPlayer) {
		NSURL* contentURL = [mediaPlayer contentURL];
		if(contentURL && ![contentURL isFileURL]) {
			AVCacheBufferSave* cachebuff = [AVCacheBufferSave cacheBufferWithURL:contentURL];
			cachebuff.requestCancel = YES;
		}
	}
	UISlider* prosressSlider = [(NativePlayerViewController*)self topToolbar];
	if(prosressSlider) {
		if(UIView* tgView = [prosressSlider viewWithTag:5659]) {
			[tgView removeFromSuperview];
		}
	}
	
	%orig;
}
%new
- (void)updateBufferProgress
{
	UISlider* prosressSlider = [(NativePlayerViewController*)self topToolbar];
	MPMoviePlayerController* mediaPlayer = [(NativePlayerViewController*)self mediaPlayer];
	if(prosressSlider && mediaPlayer) {
		NSURL* contentURL = [mediaPlayer contentURL];
		if(contentURL && ![contentURL isFileURL]) {
			AVCacheBufferSave* cachebuff = [AVCacheBufferSave cacheBufferWithURL:contentURL];
			[AVCacheBufferSave cancelAllDownloadsExceptForURL:contentURL];
			if(UIProgressView* tgView = [prosressSlider viewWithTag:5659]) {
				tgView.progress = ([@(cachebuff.downloadedBytes) floatValue]/[@(cachebuff.totalLenBytes) floatValue]);
				tgView.hidden = (tgView.progress >= 1)?YES:NO;
			}
		}
	}
}
%end
