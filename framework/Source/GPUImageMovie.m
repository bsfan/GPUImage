#import "GPUImageMovie.h"
#import "GPUImageMovieWriter.h"

@interface GPUImageMovie ()
{
    BOOL audioEncodingIsFinished, videoEncodingIsFinished;
    GPUImageMovieWriter *synchronizedMovieWriter;
    CVOpenGLESTextureCacheRef coreVideoTextureCache;
    AVAssetReader *reader;
	NSLock* readerLock;
    CMTime previousFrameTime;
	CMTime previousDisplayFrameTime;
    CFAbsoluteTime previousActualFrameTime;
	CMSampleBufferRef previousSampleBufferRef;
}

- (void)processAsset;

@end

@implementation GPUImageMovie

@synthesize url = _url;
@synthesize asset = _asset;
@synthesize runBenchmark = _runBenchmark;
@synthesize playAtActualSpeed = _playAtActualSpeed;

@synthesize linkedOverlay = _linkedOverlay;

@synthesize hardFrameDifferenceLimit = _hardFrameDifferenceLimit;

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithURL:(NSURL *)url;
{
    if (!(self = [super init])) 
    {
        return nil;
    }

    [self textureCacheSetup];

    self.url = url;
    self.asset = nil;
    self.linkedOverlay = nil;
	
	readerLock = [[NSLock alloc] init];

    return self;
}

- (id)initWithAsset:(AVAsset *)asset;
{
    if (!(self = [super init])) 
    {
      return nil;
    }
    
    [self textureCacheSetup];

    self.url = nil;
    self.asset = asset;
    self.linkedOverlay = nil;
	
	readerLock = [[NSLock alloc] init];

    return self;
}

- (void)textureCacheSetup;
{
    if ([GPUImageOpenGLESContext supportsFastTextureUpload])
    {
        runSynchronouslyOnVideoProcessingQueue(^{
            [GPUImageOpenGLESContext useImageProcessingContext];
#if defined(__IPHONE_6_0)
            CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, [[GPUImageOpenGLESContext sharedImageProcessingOpenGLESContext] context], NULL, &coreVideoTextureCache);
#else
            CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, (__bridge void *)[[GPUImageOpenGLESContext sharedImageProcessingOpenGLESContext] context], NULL, &coreVideoTextureCache);
#endif
            if (err)
            {
                NSAssert(NO, @"Error at CVOpenGLESTextureCacheCreate %d", err);
            }
            
            // Need to remove the initially created texture
            [self deleteOutputTexture];
        });
    }
}

- (void)dealloc
{
    if ([GPUImageOpenGLESContext supportsFastTextureUpload])
    {
        CFRelease(coreVideoTextureCache);
    }
}
#pragma mark -
#pragma mark Movie processing

- (void)enableSynchronizedEncodingUsingMovieWriter:(GPUImageMovieWriter *)movieWriter;
{
    synchronizedMovieWriter = movieWriter;
    //movieWriter.encodingLiveVideo = NO;  //mtg: why is this here?
}

- (void)startProcessing
{
    if(self.url == nil)
    {
      [self processAsset];
      return;
    }
    
    previousFrameTime = kCMTimeZero;
    previousActualFrameTime = CFAbsoluteTimeGetCurrent();
	previousDisplayFrameTime = kCMTimeZero;
	if (previousSampleBufferRef) {
		CMSampleBufferInvalidate(previousSampleBufferRef);
		CFRelease(previousSampleBufferRef);
		previousSampleBufferRef = NULL;
	}
	
    NSDictionary *inputOptions = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:AVURLAssetPreferPreciseDurationAndTimingKey];
    AVURLAsset *inputAsset = [[AVURLAsset alloc] initWithURL:self.url options:inputOptions];    
    [inputAsset loadValuesAsynchronouslyForKeys:[NSArray arrayWithObject:@"tracks"] completionHandler: ^{
        NSError *error = nil;
        AVKeyValueStatus tracksStatus = [inputAsset statusOfValueForKey:@"tracks" error:&error];
        if (!tracksStatus == AVKeyValueStatusLoaded) 
        {
            return;
        }
        self.asset = inputAsset;
        [self processAsset];
    }];
}

- (void)processAsset
{
	[readerLock lock];
	
    //__unsafe_unretained GPUImageMovie *weakSelf = self;
	//ok wtf brad: http://stackoverflow.com/questions/8592289/arc-the-meaning-of-unsafe-unretained
	//see "why would you ever use __unsafe_unretained?"
	__weak GPUImageMovie *weakSelf = self;
    NSError *error = nil;
    reader = [AVAssetReader assetReaderWithAsset:self.asset error:&error];
	
	AVAssetTrack *assetVideoTrack = [[self.asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
	
    //mtg: naturalSize is NOT deprecated for AVComposition, and since that's what we're primarily using this for...
	CGSize assetSize;
	if ([self.asset isKindOfClass:[AVComposition class]]) {
		assetSize = [(AVComposition*)self.asset naturalSize];
	}
	else {
		assetSize = [assetVideoTrack naturalSize];
	}
	
    NSMutableDictionary *outputSettings = [NSMutableDictionary dictionary];
    [outputSettings setObject: [NSNumber numberWithInt:kCVPixelFormatType_32BGRA]  forKey: (NSString*)kCVPixelBufferPixelFormatTypeKey];
	[outputSettings setObject:[NSNumber numberWithInt:assetSize.width] forKey: (NSString*)kCVPixelBufferWidthKey];
	[outputSettings setObject:[NSNumber numberWithInt:assetSize.height] forKey: (NSString*)kCVPixelBufferHeightKey];
    // Maybe set alwaysCopiesSampleData to NO on iOS 5.0 for faster video decoding

    AVAssetReaderTrackOutput *readerVideoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:assetVideoTrack outputSettings:outputSettings];
    [reader addOutput:readerVideoTrackOutput];
	
    NSArray *audioTracks = [self.asset tracksWithMediaType:AVMediaTypeAudio];
    BOOL shouldRecordAudioTrack = (([audioTracks count] > 0) && (weakSelf.audioEncodingTarget != nil) );
    AVAssetReaderTrackOutput *readerAudioTrackOutput = nil;

    if (shouldRecordAudioTrack)
    {
        audioEncodingIsFinished = NO;

        // This might need to be extended to handle movies with more than one audio track
        AVAssetTrack* audioTrack = [audioTracks objectAtIndex:0];
        readerAudioTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:nil];
        [reader addOutput:readerAudioTrackOutput];
    }
	
	BOOL didStart = [reader startReading];
    if (!didStart)
    {
		NSLog(@"Error reading from file at URL: %@", weakSelf.url);
        return;
    }
    
    if (synchronizedMovieWriter != nil)
    {
        [synchronizedMovieWriter setVideoInputReadyCallback:^{
			//GPUImageMovie *strongSelf = weakSelf;
			if (weakSelf) {
				[weakSelf readNextVideoFrameFromOutput:readerVideoTrackOutput];
			}
        }];

        [synchronizedMovieWriter setAudioInputReadyCallback:^{
			if (weakSelf) {
				[weakSelf readNextAudioSampleFromOutput:readerAudioTrackOutput];
			}
        }];

        [synchronizedMovieWriter enableSynchronizationCallbacks];
		
		[readerLock unlock];
    }
    else
    {
		[readerLock unlock];
		
        while (reader.status == AVAssetReaderStatusReading)
        {
                [weakSelf readNextVideoFrameFromOutput:readerVideoTrackOutput];

            if ( (shouldRecordAudioTrack) && (!audioEncodingIsFinished) )
            {
                    [weakSelf readNextAudioSampleFromOutput:readerAudioTrackOutput];
            }

        }

        if (reader.status == AVAssetWriterStatusCompleted) {
                [weakSelf endProcessing];
        }
    }
}

- (void)readNextVideoFrameFromOutput:(AVAssetReaderTrackOutput *)readerVideoTrackOutput;
{
	[readerLock lock];
	
	AVAssetReaderStatus readerStatus = reader.status;
	
    if (readerStatus == AVAssetReaderStatusReading)
    {
        CMSampleBufferRef sampleBufferRef = [readerVideoTrackOutput copyNextSampleBuffer];
		[readerLock unlock];
        if (sampleBufferRef)
        {
			// Do this outside of the video processing queue to not slow that down while waiting
			CMTime currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBufferRef);
			CMTime differenceFromLastFrame = CMTimeSubtract(currentSampleTime, previousFrameTime);
			CFAbsoluteTime currentActualTime = CFAbsoluteTimeGetCurrent();
			
			CGFloat frameTimeDifference = CMTimeGetSeconds(differenceFromLastFrame);
			CGFloat actualTimeDifference = currentActualTime - previousActualFrameTime;
			
			CGFloat frameTimeDisplayDifference = CMTimeGetSeconds(CMTimeSubtract(previousFrameTime, previousDisplayFrameTime));
			
            // ian: have the linked overlay process a frame at our current time
            if (self.linkedOverlay)
            {
                [self.linkedOverlay processFrameAtTargetTime:currentSampleTime];
            }
            
			//mtg: filter out frames that are displayed too quickly that we'll never realistically display them
			//mtg: glitch frames always come just barely (160 ns) before the correct frame, filter these out too, what's the magic number though?? 10 usec seems to do it
			if (previousSampleBufferRef && (CMTIME_IS_INVALID(previousDisplayFrameTime) || (frameTimeDisplayDifference > _hardFrameDifferenceLimit && frameTimeDifference > 1e-5)))
			{
				if (_playAtActualSpeed && frameTimeDifference > actualTimeDifference)
				{
					usleep(1000000.0 * (frameTimeDifference - actualTimeDifference));
				}
				
				previousDisplayFrameTime = previousFrameTime;
				previousActualFrameTime = CFAbsoluteTimeGetCurrent();
				
				__unsafe_unretained GPUImageMovie *weakSelf = self;
				runSynchronouslyOnVideoProcessingQueue(^{
					[weakSelf processMovieFrame:previousSampleBufferRef];
				});
				
				//NSLog(@"displayed frame at %lld / %d (%e %e)", previousFrameTime.value, previousFrameTime.timescale, frameTimeDifference, frameTimeDisplayDifference);
			}
			//			else {
			//				NSLog(@"skipped frame at %lld / %d (%e %e)", previousFrameTime.value, previousFrameTime.timescale, frameTimeDifference, frameTimeDisplayDifference);
			//			}
			
			if (frameTimeDisplayDifference < 0) {
				previousDisplayFrameTime = kCMTimeZero;
			}
			
			if (previousSampleBufferRef) {
				CMSampleBufferInvalidate(previousSampleBufferRef);
				CFRelease(previousSampleBufferRef);
			}
			previousSampleBufferRef = sampleBufferRef;
			previousFrameTime = currentSampleTime;
        }
        else
        {
            videoEncodingIsFinished = YES;
            [self endProcessing];
        }
    }
    else if (synchronizedMovieWriter != nil)
    {
        if (readerStatus == AVAssetWriterStatusCompleted)
        {
			[readerLock unlock];
            [self endProcessing];
        }
		else {
			[readerLock unlock];
		}
    }
	else {
		[readerLock unlock];
	}
}

- (void)readNextAudioSampleFromOutput:(AVAssetReaderTrackOutput *)readerAudioTrackOutput;
{
    if (audioEncodingIsFinished)
    {
        return;
    }

    CMSampleBufferRef audioSampleBufferRef = [readerAudioTrackOutput copyNextSampleBuffer];
    
    if (audioSampleBufferRef) 
    {
        runSynchronouslyOnVideoProcessingQueue(^{
            [self.audioEncodingTarget processAudioBuffer:audioSampleBufferRef];
            
            CMSampleBufferInvalidate(audioSampleBufferRef);
            CFRelease(audioSampleBufferRef);
        });
    }
    else
    {
        audioEncodingIsFinished = YES;
    }
}

- (void)processMovieFrame:(CMSampleBufferRef)movieSampleBuffer; 
{
//    CMTimeGetSeconds
//    CMTimeSubtract
    
    CMTime currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(movieSampleBuffer);
    CVImageBufferRef movieFrame = CMSampleBufferGetImageBuffer(movieSampleBuffer);

    int bufferHeight = CVPixelBufferGetHeight(movieFrame);
#if TARGET_IPHONE_SIMULATOR
    int bufferWidth = CVPixelBufferGetBytesPerRow(movieFrame) / 4; // This works around certain movie frame types on the Simulator (see https://github.com/BradLarson/GPUImage/issues/424)
#else
    int bufferWidth = CVPixelBufferGetWidth(movieFrame);
#endif

    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();

    if ([GPUImageOpenGLESContext supportsFastTextureUpload])
    {
        CVPixelBufferLockBaseAddress(movieFrame, 0);
        
        [GPUImageOpenGLESContext useImageProcessingContext];
        CVOpenGLESTextureRef texture = NULL;
        CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
																	coreVideoTextureCache,
																	movieFrame,
																	NULL,
																	GL_TEXTURE_2D,
																	GL_RGBA,
																	bufferWidth,
																	bufferHeight,
																	GL_RGBA,  //GL_BRGA  since we're reading the pixels directly...
																	GL_UNSIGNED_BYTE,
																	0,
																	&texture);
        
        if (!texture || err) {
            NSLog(@"Movie CVOpenGLESTextureCacheCreateTextureFromImage failed (error: %d)", err);  
            return;
        }
        
        outputTexture = CVOpenGLESTextureGetName(texture);
        //        glBindTexture(CVOpenGLESTextureGetTarget(texture), outputTexture);
        glBindTexture(GL_TEXTURE_2D, outputTexture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        
        for (id<GPUImageInput> currentTarget in targets)
        {
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            NSInteger targetTextureIndex = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];
            
            [currentTarget setInputSize:CGSizeMake(bufferWidth, bufferHeight) atIndex:targetTextureIndex];
            [currentTarget setInputTexture:outputTexture atIndex:targetTextureIndex];
            
            [currentTarget newFrameReadyAtTime:currentSampleTime atIndex:targetTextureIndex];
        }
        
        CVPixelBufferUnlockBaseAddress(movieFrame, 0);
        
        // Flush the CVOpenGLESTexture cache and release the texture
        CVOpenGLESTextureCacheFlush(coreVideoTextureCache, 0);
        CFRelease(texture);
        outputTexture = 0;        
    }
    else
    {
        // Upload to texture
        CVPixelBufferLockBaseAddress(movieFrame, 0);
        
        glBindTexture(GL_TEXTURE_2D, outputTexture);
        // Using BGRA extension to pull in video frame data directly
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, bufferWidth, bufferHeight, 0, GL_BGRA, GL_UNSIGNED_BYTE, CVPixelBufferGetBaseAddress(movieFrame));
        
        CGSize currentSize = CGSizeMake(bufferWidth, bufferHeight);
        for (id<GPUImageInput> currentTarget in targets)
        {
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            NSInteger targetTextureIndex = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];

            [currentTarget setInputSize:currentSize atIndex:targetTextureIndex];
            [currentTarget newFrameReadyAtTime:currentSampleTime atIndex:targetTextureIndex];
        }
        CVPixelBufferUnlockBaseAddress(movieFrame, 0);
    }
    
    if (_runBenchmark)
    {
        CFAbsoluteTime currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime);
        NSLog(@"Current frame time : %f ms", 1000.0 * currentFrameTime);
    }
}

- (void)endProcessing;
{
	if (synchronizedMovieWriter != nil)
	{
		[synchronizedMovieWriter setVideoInputReadyCallback:^{}];
		[synchronizedMovieWriter setAudioInputReadyCallback:^{}];
		[synchronizedMovieWriter endProcessing];  //we want the writer to stop ASAP
	}
	
	[readerLock lock];
	
	if (reader.status == AVAssetReaderStatusReading) {
		[reader cancelReading];
	}
	
	//block until reading stops!
	while (reader.status == AVAssetReaderStatusReading) {
		[NSThread sleepForTimeInterval:0.1];
	}
	
	[readerLock unlock];
	
	for (id<GPUImageInput> currentTarget in targets)
	{
		[currentTarget endProcessing];
	}
}

@end
