// Now Playing feed, loaded into /usr/bin/perl.
//
// Since macOS 15.4 the mediaremoted daemon answers only clients it trusts, so
// an ordinary app gets an empty dictionary no matter what it asks. Claiming the
// `com.apple.mediaremote.external-access` entitlement does not help either: it
// is restricted, and a process that claims it without Apple's authorization is
// killed at launch.
//
// /usr/bin/perl, however, is a platform binary (Platform identifier=16) that
// the daemon does trust, and it is signed without library validation — so it
// can load this dylib. Running the MediaRemote calls from inside that process
// yields the full record: title, artist, album, duration, position, artwork.
//
// The helper prints one JSON object per line on stdout and takes commands on
// stdin. It exits as soon as stdin closes, so it can never outlive Cyclop.

#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetBoolFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));

/// kMRMediaRemoteCommandSeekToPlaybackPosition.
static const int kSeekCommand = 45;

static MRGetInfoFn sGetInfo;
static MRGetBoolFn sGetIsPlaying;
static MRSendCommandFn sSendCommand;
static MRGetPIDFn sGetPID;
static int sOwnerPID;
static dispatch_queue_t sQueue;
static NSString *sArtworkID;

static NSString *const kMediaRemotePath =
    @"/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote";

static void emit(NSDictionary *payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

/// Reads the current record and prints it. Artwork is only included when the
/// track changed — it is the bulk of the payload and never changes mid-track.
///
/// `elapsed` goes out with the moment it was taken. The daemon does not keep
/// that field running: it is a reading from the last change of state, and a
/// session that has been playing for three minutes still reports the second it
/// started at. What advances is the clock beside it, so both have to travel.
static void publish(void) {
    if (!sGetInfo || !sGetIsPlaying) return;
    // Cached rather than nested a call deeper: it only labels the source.
    if (sGetPID) sGetPID(sQueue, ^(int pid) { sOwnerPID = pid; });
    sGetIsPlaying(sQueue, ^(Boolean playing) {
        sGetInfo(sQueue, ^(CFDictionaryRef raw) {
            NSDictionary *info = (__bridge NSDictionary *)raw;
            NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"";

            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            out[@"playing"] = @(playing ? YES : NO);
            out[@"title"] = title;
            out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
            out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
            out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
            out[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0;
            out[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @0;
            out[@"pid"] = @(sOwnerPID);

            // Elapsed time is a reading taken at Timestamp, not a live clock:
            // the daemon stores what the player last told it and never advances
            // it. A track can play for minutes with elapsed frozen at 0. Both
            // halves have to travel together or the number means nothing — the
            // reader turns them back into a position by counting forward from
            // the stamp. `now` is sent with them so that counting starts from
            // the moment the record was read rather than the moment the line
            // was parsed, and so a reader can tell how stale its copy is.
            NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if ([stamp isKindOfClass:NSDate.class]) out[@"timestamp"] = @(stamp.timeIntervalSince1970);
            out[@"now"] = @(NSDate.date.timeIntervalSince1970);

            NSString *artworkID = info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"] ?: title;
            NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            if (artwork.length > 0 && ![artworkID isEqualToString:sArtworkID]) {
                out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
                sArtworkID = artworkID;
            }
            if (title.length == 0) sArtworkID = nil;

            emit(out);
        });
    });
}

/// Reads the record a moment from now. Publishing in the same breath as a
/// command only ever reports the state the command was meant to change, since
/// nothing downstream has acted on it yet.
static void publishSoon(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), sQueue, ^{
        publish();
    });
}

static void handleCommand(NSString *line) {
    if ([line isEqualToString:@"get"]) {
        publish();
    } else if ([line hasPrefix:@"cmd "]) {
        if (sSendCommand) sSendCommand([line substringFromIndex:4].intValue, NULL);
        publishSoon();
    } else if ([line hasPrefix:@"seek "]) {
        // Deliberately not MRMediaRemoteSetElapsedTime. That call writes a
        // position into the daemon's own record without asking the player to
        // move; the bar jumps, the music carries on where it was, and every
        // later reading is offset by the difference until the track changes.
        // Measured on macOS 26.5.2: one call left the record 29.6 s adrift of
        // Spotify for the rest of the song. The seek command at least asks the
        // player, which is the only thing that can actually move the playhead.
        if (sSendCommand) {
            double position = [line substringFromIndex:5].doubleValue;
            sSendCommand(kSeekCommand, (__bridge CFDictionaryRef)@{
                @"kMRMediaRemoteOptionPlaybackPosition": @(position)
            });
        }
        publishSoon();
    }
}

static void startFeed(void) {
    [NSThread detachNewThreadWithBlock:^{
        sQueue = dispatch_queue_create("com.cyclop.mediaremote", DISPATCH_QUEUE_SERIAL);

        void *handle = dlopen(kMediaRemotePath.UTF8String, RTLD_NOW);
        if (!handle) {
            emit(@{@"error": @"mediaremote-unavailable"});
            return;
        }
        sGetInfo = (MRGetInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        sGetIsPlaying = (MRGetBoolFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        sSendCommand = (MRSendCommandFn)dlsym(handle, "MRMediaRemoteSendCommand");
        sGetPID = (MRGetPIDFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");

        MRRegisterFn registerNotifications =
            (MRRegisterFn)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        if (registerNotifications) registerNotifications(sQueue);

        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        ];
        // Kept because they cost nothing and do fire on some systems — but they
        // cannot be relied on. On macOS 26.5.2 not one of these arrived across
        // repeated half-minute windows that contained real track changes, so
        // `NowPlayingFeed` polls with `get` rather than waiting to be told.
        for (NSString *name in names) {
            [NSNotificationCenter.defaultCenter addObserverForName:name
                                                           object:nil
                                                            queue:nil
                                                       usingBlock:^(NSNotification *note) {
                publish();
            }];
        }

        publish();
        [NSRunLoop.currentRunLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
        [NSRunLoop.currentRunLoop run];
    }];
}

static void startCommandReader(void) {
    [NSThread detachNewThreadWithBlock:^{
        char buffer[512];
        while (fgets(buffer, sizeof buffer, stdin)) {
            @autoreleasepool {
                NSString *line = [@(buffer) stringByTrimmingCharactersInSet:
                                  NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (line.length) handleCommand(line);
            }
        }
        // Cyclop closed the pipe or went away.
        exit(0);
    }];
}

__attribute__((constructor))
static void cyclop_helper_init(void) {
    startFeed();
    startCommandReader();
}
