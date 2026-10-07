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
//
// A line describes every session at once, not just the one macOS calls "now
// playing": a video in a browser tab and Yandex Music are two sessions, and
// the system names one of them — often the paused one — leaving the other out
// of reach. Which one the panel shows is decided in the app.
//
//   {"active": <pid macOS considers now playing, 0 if none>,
//    "sessions": [{"pid", "playing", "title", "artist", "album", "duration",
//                  "elapsed", "rate", "timestamp", "artwork"?, "commands"?}]}
//
// Commands: `get`, `cmd <code> [pid]`, `seek <seconds> [pid]`. Without a pid,
// or with 0, a command goes to the session macOS considers active.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#include <math.h>
#include <stdatomic.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetBoolFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetClientsFn)(dispatch_queue_t, void (^)(NSArray *));
typedef void (*MRSendCommandToPlayerFn)(int, CFDictionaryRef, id, id, id, void (^)(id));
typedef void (*MRGetCommandsForPlayerFn)(id, dispatch_queue_t, void (^)(NSArray *));
typedef id (*MRGetLocalOriginFn)(void);
typedef void (*MRGetStateForPlayerFn)(id, dispatch_queue_t, void (^)(unsigned int));
/// The flag asks for artwork. Read off the macOS 26 disassembly: when it is
/// set, the request gets an artwork size before it leaves; the block takes
/// the record and a second pointer nobody has needed.
typedef void (*MRGetInfoForPlayerFn)(id, Boolean, dispatch_queue_t, void (^)(CFDictionaryRef, void *));

/// The private classes, as far as they are used here. Selectors listed off the
/// runtime, not guessed.
@interface NSObject (CyclopMediaRemote)
- (id)initWithOrigin:(id)origin client:(id)client player:(id)player;
- (id)client;
- (int)processIdentifier;
@end

static MRGetInfoFn sGetInfo;
static MRGetBoolFn sGetIsPlaying;
static MRGetPIDFn sGetPID;
static MRGetClientsFn sGetClients;
static MRSendCommandToPlayerFn sSendCommandToPlayer;
static MRGetCommandsForPlayerFn sGetCommandsForPlayer;
static MRGetLocalOriginFn sGetLocalOrigin;
static MRGetStateForPlayerFn sGetStateForPlayer;
static MRGetInfoForPlayerFn sGetInfoForPlayer;

/// Where MediaRemote delivers its answers.
static dispatch_queue_t sQueue;
/// Where they are asked for and waited on — every publish and every command,
/// one at a time. Never `sQueue`: waiting there for an answer that is to be
/// delivered there is a wait that never ends. That is how the feed once went
/// silent outright — the list of commands asked for from inside the info
/// callback, already running on `sQueue`, simply never arrived.
static dispatch_queue_t sWorkQueue;

/// Touched only on `sWorkQueue`.
static NSArray *sClients;
static NSMutableDictionary<NSNumber *, NSString *> *sArtworkIDs;

static NSString *const kMediaRemotePath =
    @"/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote";

/// MediaRemote's own answer on the other side of a session's state.
static const unsigned int kPlaybackStatePlaying = 1;

/// Longest a single answer is waited for. A daemon that does not answer must
/// cost one session's line, not the whole feed.
static const double kAnswerTimeout = 1.0;

/// Codes read live off a real session's `GetSupportedCommandsForPlayer` —
/// not the old `MRMediaRemoteCommand` enum, which is not always the same
/// numbering. Play/Pause/NextTrack/PreviousTrack happened to match it
/// (0/1/4/5); SeekToPlaybackPosition did not (24, not the 11 the old enum
/// would suggest). There is no separate toggle code in the per-client set —
/// the caller sends Play or Pause explicitly, by its own known state.
typedef NS_ENUM(int, MRCommand) {
    MRCommandPlay = 0,
    MRCommandPause = 1,
    MRCommandNextTrack = 4,
    MRCommandPreviousTrack = 5,
    MRCommandSeekToPlaybackPosition = 24,
};

/// The writer refuses a payload it cannot serialise with an
/// NSInvalidArgumentException, not an error out-parameter — and an exception
/// nobody catches inside a dispatch block terminates the process. That is the
/// perl host: it aborted three times in four seconds on 10.09.2026 over a NaN
/// duration, and the feed in the app took three straight deaths as the route
/// being gone. A frame that will not serialise is dropped, never fatal.
static void emit(NSDictionary *payload) {
    if (![NSJSONSerialization isValidJSONObject:payload]) {
        fprintf(stderr, "cyclop-helper: frame is not valid JSON, dropped\n");
        return;
    }
    NSData *json = nil;
    @try {
        json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    } @catch (NSException *e) {
        fprintf(stderr, "cyclop-helper: %s\n", e.reason.UTF8String ?: "JSON write failed");
        return;
    }
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

/// MediaRemote passes numbers on as the player reported them, and a player may
/// report a duration it does not know as NaN, or an infinite one for a live
/// stream. Neither is a JSON number. Anything not finite goes out as 0, which
/// the app already reads as "unknown".
static NSNumber *finiteNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return @0;
    return isfinite([value doubleValue]) ? value : @0;
}

/// A text field that is not text — a browser tab can put anything into the
/// MediaSession record — is sent as empty rather than risked on the wire.
static NSString *textValue(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}

/// One answer from MediaRemote, waited for — but never forever.
///
/// Waiting turns a chain of callbacks into a list of steps, which is what
/// lets a publish ask about several sessions in turn. The ceiling is what
/// makes waiting safe: an answer that never comes costs a second, not the
/// feed. A late answer lands in storage the block owns, so it is harmless.
static void waitForAnswer(void (^ask)(dispatch_semaphore_t answered)) {
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    ask(answered);
    dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAnswerTimeout * NSEC_PER_SEC)));
}

/// The service already tracks which player is "active" for the whole
/// system — asking it directly gives an already-resolved, already-matched
/// path. Building one by hand from a bundle id resolves too, but the
/// per-client API then reports it supports nothing and silently drops every
/// command sent to it. `activePlayerPath` also answers nil until
/// `MRMediaRemoteGetNowPlayingClients` has been called at least once in this
/// process — `startFeed` does that once, at launch.
static id activePlayerPath(void) {
    id serviceClient = [NSClassFromString(@"MRMediaRemoteServiceClient") performSelector:@selector(sharedServiceClient)];
    return [serviceClient performSelector:@selector(activePlayerPath)];
}

/// Whether every session can be read on its own, rather than only the one
/// macOS calls active.
///
/// The calls behind it are private and undocumented, and their signatures
/// were read off macOS 26 — the per-player info call takes an artwork flag
/// before the queue there. A call made with the wrong shape does not fail, it
/// crashes the host. So below 26 the helper reads what it always read: the
/// active session alone, through the calls that have been verified there.
static BOOL readsEverySession(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
        && sGetClients && sGetLocalOrigin && sGetStateForPlayer && sGetInfoForPlayer
        && NSClassFromString(@"MRPlayerPath");
}

/// Path to one session, by the pid MediaRemote listed it under.
///
/// The active session is reached by the path the service hands out — the
/// form that has always worked. Any other is built from the client object
/// exactly as MediaRemote listed it, pid and all, which resolves where one
/// built from a bundle id does not: asked through it, a session reports its
/// commands like the active one does. A pid no longer listed has nowhere to
/// go, and a command for it is dropped rather than sent to whoever is active.
static id playerPath(int pid) {
    id active = activePlayerPath();
    if (pid <= 0 || !readsEverySession()) return active;
    if (active && [[active client] processIdentifier] == pid) return active;
    for (id client in sClients) {
        if ([client processIdentifier] == pid) {
            return [[NSClassFromString(@"MRPlayerPath") alloc] initWithOrigin:sGetLocalOrigin() client:client player:nil];
        }
    }
    return nil;
}

/// What the player says it accepts.
///
/// A browser tab playing one video registers no next/previous handler — there
/// is nothing to skip to — so those codes are absent and anything sent for
/// them is dropped without a word. macOS greys its own skip buttons out on
/// exactly these sessions. Nil when there was no answer: unknown must not read
/// as "accepts nothing" and dim every button.
static NSArray *readCommands(id path) {
    if (!sGetCommandsForPlayer || !path) return nil;
    __block NSArray *codes = nil;
    waitForAnswer(^(dispatch_semaphore_t answered) {
        sGetCommandsForPlayer(path, sQueue, ^(NSArray *infos) {
            NSMutableArray *list = [NSMutableArray array];
            // `valueForKey:` on a private class throws if the key is ever
            // renamed; inside this block that would take the host down.
            // Caught, the answer is simply "unknown".
            @try {
                for (id info in infos) {
                    id code = [info valueForKey:@"command"];
                    id enabled = [info valueForKey:@"enabled"];
                    // A command can be listed and still be off right now. Only
                    // what is both listed and enabled counts as offered.
                    if ([code isKindOfClass:NSNumber.class] &&
                        (enabled == nil || [enabled boolValue])) {
                        [list addObject:code];
                    }
                }
                codes = list;
            } @catch (NSException *e) {
                fprintf(stderr, "cyclop-helper: commands unreadable: %s\n", e.reason.UTF8String ?: "");
            }
            dispatch_semaphore_signal(answered);
        });
    });
    return codes;
}

static NSString *artworkID(NSDictionary *info) {
    NSString *identifier = textValue(info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"]);
    return identifier.length > 0 ? identifier : textValue(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
}

/// Artwork travels only when a session's track changed — it is the bulk of
/// the payload and never changes mid-track. Kept per session: two players
/// each change track on their own.
static BOOL needsArtwork(NSDictionary *info, int pid) {
    if (textValue(info[@"kMRMediaRemoteNowPlayingInfoTitle"]).length == 0) {
        [sArtworkIDs removeObjectForKey:@(pid)];
        return NO;
    }
    return ![artworkID(info) isEqualToString:sArtworkIDs[@(pid)]];
}

/// One session's line.
///
/// `elapsed` goes out with the moment it was taken. The daemon does not keep
/// that field running: it is a reading from the last change of state, and a
/// session that has been playing for three minutes still reports the second it
/// started at. What advances is the clock beside it, so both have to travel.
static NSDictionary *record(NSDictionary *info, BOOL playing, int pid, NSArray *commands) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    // `playing ? @YES : @NO`, not `@(playing ? YES : NO)`: in C the ternary
    // promotes both branches to `int`, so the boxed number came out an integer
    // and the field serialised as 1 rather than true.
    out[@"playing"] = playing ? @YES : @NO;
    out[@"title"] = textValue(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
    out[@"artist"] = textValue(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
    out[@"album"] = textValue(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
    out[@"duration"] = finiteNumber(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
    out[@"elapsed"] = finiteNumber(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
    out[@"rate"] = finiteNumber(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
    out[@"pid"] = @(pid);

    id stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    out[@"timestamp"] = [stamp isKindOfClass:NSDate.class]
        ? finiteNumber(@([(NSDate *)stamp timeIntervalSince1970]))
        : @0;

    if (needsArtwork(info, pid)) {
        id value = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        NSData *artwork = [value isKindOfClass:NSData.class] ? value : nil;
        if (artwork.length > 0) {
            out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
            sArtworkIDs[@(pid)] = artworkID(info);
        }
    }

    // Left out entirely when there was no answer: absent is not the same as
    // empty.
    if (commands) out[@"commands"] = commands;
    return out;
}

/// One session read through its own path. Nil when it did not answer in time
/// — left out of this line, back on the next.
static NSDictionary *readSession(id client, id origin) {
    int pid = [client processIdentifier];
    id path = [[NSClassFromString(@"MRPlayerPath") alloc] initWithOrigin:origin client:client player:nil];
    if (!path) return nil;

    __block unsigned int state = 0;
    waitForAnswer(^(dispatch_semaphore_t answered) {
        sGetStateForPlayer(path, sQueue, ^(unsigned int value) {
            state = value;
            dispatch_semaphore_signal(answered);
        });
    });

    // Asked without artwork first: the record says whether the cover changed,
    // and only then is it worth fetching.
    NSDictionary *info = nil;
    for (int pass = 0; pass < 2; pass++) {
        BOOL withArtwork = pass == 1;
        if (withArtwork && !needsArtwork(info, pid)) break;
        __block NSDictionary *answer = nil;
        waitForAnswer(^(dispatch_semaphore_t answered) {
            sGetInfoForPlayer(path, withArtwork, sQueue, ^(CFDictionaryRef raw, void *unused) {
                answer = [(__bridge NSDictionary *)raw copy];
                dispatch_semaphore_signal(answered);
            });
        });
        if (answer) info = answer;
        if (!info) return nil;
    }

    BOOL playing = state == kPlaybackStatePlaying
        || [finiteNumber(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]) doubleValue] > 0;
    return record(info, playing, pid, readCommands(path));
}

/// The active session alone, through the global calls — what the helper read
/// before it read every session, and what it still reads where it cannot.
static NSDictionary *readActiveSession(int pid) {
    if (!sGetInfo || !sGetIsPlaying) return nil;
    __block Boolean playing = false;
    waitForAnswer(^(dispatch_semaphore_t answered) {
        sGetIsPlaying(sQueue, ^(Boolean value) {
            playing = value;
            dispatch_semaphore_signal(answered);
        });
    });
    __block NSDictionary *info = nil;
    waitForAnswer(^(dispatch_semaphore_t answered) {
        sGetInfo(sQueue, ^(CFDictionaryRef raw) {
            info = [(__bridge NSDictionary *)raw copy];
            dispatch_semaphore_signal(answered);
        });
    });
    if (!info) return nil;
    return record(info, playing, pid, readCommands(activePlayerPath()));
}

/// Reads every session and prints them as one line. Runs on `sWorkQueue`.
static void publishNow(void) {
    if (!sGetInfo && !sGetInfoForPlayer) return;

    __block int activePID = 0;
    if (sGetPID) waitForAnswer(^(dispatch_semaphore_t answered) {
        sGetPID(sQueue, ^(int pid) {
            activePID = pid;
            dispatch_semaphore_signal(answered);
        });
    });

    NSMutableArray *sessions = [NSMutableArray array];
    if (readsEverySession()) {
        __block NSArray *clients = nil;
        waitForAnswer(^(dispatch_semaphore_t answered) {
            sGetClients(sQueue, ^(NSArray *list) {
                clients = [list copy];
                dispatch_semaphore_signal(answered);
            });
        });
        sClients = clients ?: @[];
        id origin = sGetLocalOrigin();
        for (id client in sClients) {
            NSDictionary *session = readSession(client, origin);
            if (session) [sessions addObject:session];
        }
    } else {
        NSDictionary *session = readActiveSession(activePID);
        if (session) [sessions addObject:session];
    }

    // A session that went away takes its cover with it: if it comes back, its
    // first line has to carry the artwork again.
    NSSet *alive = [NSSet setWithArray:[sessions valueForKey:@"pid"]];
    for (NSNumber *pid in sArtworkIDs.allKeys) {
        if (![alive containsObject:pid]) [sArtworkIDs removeObjectForKey:pid];
    }

    emit(@{@"active": @(activePID), @"sessions": sessions});
}

/// Asks for a publish. Requests pile up — a timer, three notifications, every
/// command — and while one is still waiting its turn, another adds nothing.
static atomic_bool sPublishQueued;

static void publish(void) {
    if (atomic_exchange(&sPublishQueued, true)) return;
    dispatch_async(sWorkQueue, ^{
        atomic_store(&sPublishQueued, false);
        @autoreleasepool { publishNow(); }
    });
}

static void sendCommand(MRCommand command, NSDictionary *options, int pid) {
    if (!sSendCommandToPlayer) return;
    id path = playerPath(pid);
    if (!path) return;
    sSendCommandToPlayer(command, (__bridge CFDictionaryRef)options, nil, path, nil, ^(id result){});
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    int pid = parts.count > 2 ? parts[2].intValue : 0;
    if ([parts[0] isEqualToString:@"get"]) {
        publish();
    } else if ([parts[0] isEqualToString:@"cmd"] && parts.count > 1) {
        MRCommand command = (MRCommand)parts[1].intValue;
        dispatch_async(sWorkQueue, ^{ sendCommand(command, nil, pid); });
        publish();
    } else if ([parts[0] isEqualToString:@"seek"] && parts.count > 1) {
        double seconds = parts[1].doubleValue;
        dispatch_async(sWorkQueue, ^{
            sendCommand(MRCommandSeekToPlaybackPosition,
                        @{@"kMRMediaRemoteOptionPlaybackPosition": @(seconds)}, pid);
        });
        publish();
    }
}

static void loadSymbols(void *handle) {
    sGetInfo = (MRGetInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
    sGetIsPlaying = (MRGetBoolFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    sGetPID = (MRGetPIDFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
    sGetClients = (MRGetClientsFn)dlsym(handle, "MRMediaRemoteGetNowPlayingClients");
    sSendCommandToPlayer = (MRSendCommandToPlayerFn)dlsym(handle, "MRMediaRemoteSendCommandToPlayer");
    sGetCommandsForPlayer = (MRGetCommandsForPlayerFn)dlsym(handle, "MRMediaRemoteGetSupportedCommandsForPlayer");
    sGetLocalOrigin = (MRGetLocalOriginFn)dlsym(handle, "MRMediaRemoteGetLocalOrigin");
    sGetStateForPlayer = (MRGetStateForPlayerFn)dlsym(handle, "MRMediaRemoteGetPlaybackStateForPlayer");
    sGetInfoForPlayer = (MRGetInfoForPlayerFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfoForPlayer");
}

static void startFeed(void) {
    [NSThread detachNewThreadWithBlock:^{
        void *handle = dlopen(kMediaRemotePath.UTF8String, RTLD_NOW);
        if (!handle) {
            emit(@{@"error": @"mediaremote-unavailable"});
            return;
        }
        // Set on the work queue, where every call through them is made, so no
        // call races the assignment from another thread. A command that got
        // there first finds them nil and does nothing.
        dispatch_sync(sWorkQueue, ^{ loadSymbols(handle); });

        MRRegisterFn registerNotifications =
            (MRRegisterFn)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        if (registerNotifications) registerNotifications(sQueue);

        // activePlayerPath answers nil until the per-client subscription has
        // been primed at least once in this process — call order matters,
        // not just symbol presence.
        if (sGetClients) sGetClients(sQueue, ^(NSArray *clients) {});

        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        ];
        for (NSString *name in names) {
            [NSNotificationCenter.defaultCenter addObserverForName:name
                                                           object:nil
                                                            queue:nil
                                                       usingBlock:^(NSNotification *note) {
                publish();
            }];
        }

        // A poll, not just a subscription: on macOS 26 the notifications above
        // were measured arriving zero times across 30-second windows that
        // included real track changes (#23), so a client that only reacted to
        // them would go stale silently. The notifications describe only the
        // active session anyway, and a second one changing track behind it
        // is seen by the poll alone. Cheap enough at this interval to run
        // unconditionally rather than gate it on whether anything is playing
        // — an idle session publishes the same empty line it already would.
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
            publish();
        }];

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
    // Both queues exist before either thread starts: a command can arrive
    // before the feed has finished loading MediaRemote, and it must find a
    // queue to wait its turn on rather than a nil one.
    sQueue = dispatch_queue_create("com.cyclop.mediaremote", DISPATCH_QUEUE_SERIAL);
    sWorkQueue = dispatch_queue_create("com.cyclop.mediaremote.work", DISPATCH_QUEUE_SERIAL);
    sClients = @[];
    sArtworkIDs = [NSMutableDictionary dictionary];
    startFeed();
    startCommandReader();
}
