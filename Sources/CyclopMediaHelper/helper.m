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
#import <objc/message.h>
#include <math.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetBoolFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetClientsFn)(dispatch_queue_t, void (^)(NSArray *));
typedef void (*MRSendCommandToPlayerFn)(int, CFDictionaryRef, id, id, id, void (^)(id));
typedef void (*MRGetCommandsForPlayerFn)(id, dispatch_queue_t, void (^)(NSArray *));
typedef int (*MRClientPIDFn)(id);
typedef CFStringRef (*MRClientStringFn)(id);
typedef void (*MRGetInfoForPlayerFn)(id, Boolean, dispatch_queue_t, void (^)(NSDictionary *, void *));
typedef CFDataRef (*MRArtworkCopyDataFn)(void *);

static MRGetInfoFn sGetInfo;
static MRGetBoolFn sGetIsPlaying;
static MRGetPIDFn sGetPID;
static MRGetClientsFn sGetClients;
static MRSendCommandToPlayerFn sSendCommandToPlayer;
static MRGetCommandsForPlayerFn sGetCommandsForPlayer;
static MRClientPIDFn sClientPID;
static MRClientStringFn sClientBundle;
static MRClientStringFn sClientName;
static MRClientStringFn sClientParent;
static MRGetInfoForPlayerFn sGetInfoForPlayer;
static MRArtworkCopyDataFn sArtworkCopyData;
static CFStringRef sItemOptionKey;
static int sOwnerPID;
static dispatch_queue_t sQueue;
static NSString *sArtworkID;

/// The app the user picked in the source list, by bundle id; nil leaves the
/// choice to the system, as before there was a list.
static NSString *sChosen;
/// Path of the picked player while it is the one shown and it is not the
/// system's current one. Nil means the system's active player, which is the
/// only path commands are known to always reach.
static id sTargetPath;
/// The picked player's current item. Commands to a path that is not the
/// system's are scoped to it, or the service may hand them to whoever is
/// current instead.
static NSString *sItemID;

static NSString *const kMediaRemotePath =
    @"/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote";

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

static id activePlayerPath(void);
static void runCommand(NSString *line);

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

/// What the player says it accepts, refreshed alongside each publish and read
/// from the last answer rather than waited for.
///
/// It is cached for the same reason the owning pid is, and then for one more.
/// The reason shared with the pid: it only labels the payload, so a cycle of
/// staleness costs nothing. The reason of its own: asked from inside the
/// `GetNowPlayingInfo` callback — a block already running on `sQueue` — the
/// answer never arrives at all. Nesting it there silenced the feed outright,
/// because the payload waiting on that answer was never sent. Kept flat, both
/// calls return.
///
/// A browser tab playing one video registers no next/previous handler — there
/// is nothing to skip to — so those codes are absent and anything sent for
/// them is dropped without a word. macOS greys its own skip buttons out on
/// exactly these sessions.
static NSArray *sCommands;

static void refreshCommands(void) {
    if (!sGetCommandsForPlayer) return;
    id path = sTargetPath ?: activePlayerPath();
    if (!path) return;
    sGetCommandsForPlayer(path, sQueue, ^(NSArray *infos) {
        NSMutableArray *codes = [NSMutableArray array];
        // `valueForKey:` on a private class throws if the key is ever renamed;
        // inside this block that would take the host down. Caught, the list
        // simply stays what it was.
        @try {
            for (id info in infos) {
                id code = [info valueForKey:@"command"];
                id enabled = [info valueForKey:@"enabled"];
                // A command can be listed and still be off right now. Only what is
                // both listed and enabled counts as offered.
                if ([code isKindOfClass:NSNumber.class] &&
                    (enabled == nil || [enabled boolValue])) {
                    [codes addObject:code];
                }
            }
            sCommands = codes;
        } @catch (NSException *e) {
            fprintf(stderr, "cyclop-helper: commands unreadable: %s\n", e.reason.UTF8String ?: "");
        }
    });
}

/// The record as it goes out on the wire, from whichever player is shown.
/// Artwork is only included when the track changed — it is the bulk of the
/// payload and never changes mid-track.
///
/// `elapsed` goes out with the moment it was taken. The daemon does not keep
/// that field running: it is a reading from the last change of state, and a
/// session that has been playing for three minutes still reports the second it
/// started at. What advances is the clock beside it, so both have to travel.
static NSMutableDictionary *payload(NSDictionary *info, BOOL playing, NSData *artwork, int pid) {
    NSString *title = textValue(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    // `playing ? @YES : @NO`, not `@(playing ? YES : NO)`: in C the
    // ternary promotes both branches to `int`, so the boxed number came
    // out an integer and the field serialised as 1 rather than true.
    out[@"playing"] = playing ? @YES : @NO;
    out[@"title"] = title;
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

    NSString *artworkID = textValue(info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"]);
    if (artworkID.length == 0) artworkID = title;
    if (artwork.length > 0 && ![artworkID isEqualToString:sArtworkID]) {
        out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
        sArtworkID = artworkID;
    }
    if (title.length == 0) sArtworkID = nil;

    // Left out entirely until an answer has arrived: absent is not the
    // same as empty, and "unknown" must not read as "accepts nothing"
    // and dim every button.
    if (sCommands) out[@"commands"] = sCommands;
    return out;
}

/// The players the source list offers, and the name of the one shown.
static void addSources(NSMutableDictionary *out, NSArray *sources, NSString *name) {
    out[@"sources"] = sources;
    out[@"chosen"] = sChosen ?: @"";
    if (name.length) out[@"name"] = name;
}

/// The system's current player — the only route before the source list, and
/// still the one used whenever the choice is automatic.
static void publishSystem(NSArray *sources, NSString *name) {
    sTargetPath = nil;
    sItemID = nil;
    sGetIsPlaying(sQueue, ^(Boolean playing) {
        sGetInfo(sQueue, ^(CFDictionaryRef raw) {
            NSDictionary *info = (__bridge NSDictionary *)raw;
            id artworkValue = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            NSData *artwork = [artworkValue isKindOfClass:NSData.class] ? artworkValue : nil;
            NSMutableDictionary *out = payload(info, playing, artwork, sOwnerPID);
            addSources(out, sources, name);
            emit(out);
        });
    });
}

/// The player picked in the list, read through its own path. The artwork
/// comes as a separate object here, not inside the record.
static void publishChosen(NSDictionary *source, NSArray *sources) {
    id path = source[@"path"];
    sTargetPath = path;
    sGetInfoForPlayer(path, true, sQueue, ^(NSDictionary *info, void *cover) {
        NSData *artwork = nil;
        if (cover && sArtworkCopyData) {
            CFDataRef data = sArtworkCopyData(cover);
            if (data) artwork = CFBridgingRelease(data);
        }
        if (!artwork) {
            id value = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            artwork = [value isKindOfClass:NSData.class] ? value : nil;
        }
        sItemID = textValue(info[@"kMRMediaRemoteNowPlayingInfoContentItemIdentifier"]);
        BOOL playing = [finiteNumber(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]) doubleValue] > 0;
        NSMutableDictionary *out = payload(info ?: @{}, playing, artwork, [source[@"pid"] intValue]);
        addSources(out, sources, source[@"name"]);
        emit(out);
    });
}

/// A path to one client's player, built the way the daemon builds its own:
/// a copy of the local path, pointed at that client. The shared local path
/// itself must not be touched — every other path is cut from it.
static id playerPath(NSString *bundle, int pid) {
    Class pathClass = NSClassFromString(@"MRPlayerPath");
    Class clientClass = NSClassFromString(@"MRClient");
    if (!pathClass || !clientClass || ![pathClass respondsToSelector:@selector(localPlayerPath)]) return nil;
    @try {
        id path = [[pathClass performSelector:@selector(localPlayerPath)] copy];
        id client = [clientClass alloc];
        if (![client respondsToSelector:@selector(initWithBundleIdentifier:)]) return nil;
        client = [client performSelector:@selector(initWithBundleIdentifier:) withObject:bundle];
        if (![client respondsToSelector:@selector(setProcessIdentifier:)] ||
            ![path respondsToSelector:@selector(setClient:)] ||
            ![path respondsToSelector:@selector(setPlayer:)]) return nil;
        ((void (*)(id, SEL, int))objc_msgSend)(client, @selector(setProcessIdentifier:), pid);
        [path performSelector:@selector(setClient:) withObject:client];
        // Nil is the client's active player; "default" would be another one
        // for apps that publish several.
        [path performSelector:@selector(setPlayer:) withObject:nil];
        return path;
    } @catch (NSException *e) {
        return nil;
    }
}

/// Every registered client with a track, for the source list. A browser plays
/// through a helper process — WebKit's GPU process, Chromium's media one — and
/// is named and identified by the app the helper serves, which is also what
/// the list should say: "SoundCloud", not "SoundCloud Graphics and Media".
static void survey(NSArray *clients) {
    NSMutableArray *found = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();
    NSUInteger asked = 0;
    for (id client in clients) {
        if (asked >= 8) break;
        int pid = sClientPID(client);
        NSString *own = sClientBundle ? (__bridge NSString *)sClientBundle(client) : nil;
        if (pid <= 0 || own.length == 0) continue;
        NSString *parent = sClientParent ? (__bridge NSString *)sClientParent(client) : nil;
        NSString *bundle = parent.length ? parent : own;
        NSString *name = sClientName ? (__bridge NSString *)sClientName(client) : nil;
        id path = playerPath(own, pid);
        if (!path) continue;
        asked++;
        dispatch_group_enter(group);
        sGetInfoForPlayer(path, false, sQueue, ^(NSDictionary *info, void *cover) {
            if (textValue(info[@"kMRMediaRemoteNowPlayingInfoTitle"]).length > 0) {
                BOOL playing = [finiteNumber(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]) doubleValue] > 0;
                [found addObject:@{
                    @"bundle": bundle, @"name": name.length ? name : @"", @"pid": @(pid),
                    @"playing": playing ? @YES : @NO, @"path": path,
                }];
            }
            dispatch_group_leave(group);
        });
    }

    // A client that never answers must not stall the feed: whichever comes
    // first, every answer or a second, goes on with what there is. Both run
    // on the same serial queue, so the flag needs no lock.
    __block BOOL done = NO;
    void (^finish)(void) = ^{
        if (done) return;
        done = YES;
        NSMutableArray *sources = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (NSDictionary *source in found) {
            if ([seen containsObject:source[@"bundle"]]) continue;
            [seen addObject:source[@"bundle"]];
            [sources addObject:@{@"bundle": source[@"bundle"], @"name": source[@"name"], @"playing": source[@"playing"]}];
        }
        NSDictionary *chosen = nil, *owner = nil;
        for (NSDictionary *source in found) {
            if (sChosen && !chosen && [source[@"bundle"] isEqualToString:sChosen]) chosen = source;
            if (!owner && [source[@"pid"] intValue] == sOwnerPID) owner = source;
        }
        // The picked app is shown through its own path only when it is not
        // the system's player already: the system's path is the one that
        // has always taken commands.
        if (chosen && [chosen[@"pid"] intValue] != sOwnerPID) {
            publishChosen(chosen, sources);
        } else {
            publishSystem(sources, owner[@"name"]);
        }
    };
    dispatch_group_notify(group, sQueue, finish);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), sQueue, finish);
}

static void publish(void) {
    if (!sGetInfo || !sGetIsPlaying) return;
    // Cached rather than nested a call deeper: it only labels the source.
    if (sGetPID) sGetPID(sQueue, ^(int pid) { sOwnerPID = pid; });
    // Flat, never from inside another answer (see `sCommands`): it asks about
    // the path the last cycle settled on, which a cycle later is this one's.
    refreshCommands();
    if (sGetClients && sClientPID && sGetInfoForPlayer) {
        sGetClients(sQueue, ^(NSArray *clients) { survey(clients); });
    } else {
        publishSystem(@[], nil);
    }
}

/// The service already tracks which player is "active" for the whole
/// system — asking it directly gives an already-resolved, already-matched
/// path. Building one by hand from a bundle id resolves too, but the
/// per-client API then reports it supports nothing and silently drops every
/// command sent to it; this is the only form that has ever worked.
/// `activePlayerPath` also answers nil until `MRMediaRemoteGetNowPlayingClients`
/// has been called at least once in this process — `startFeed` does that once,
/// at launch.
static id activePlayerPath(void) {
    id serviceClient = [NSClassFromString(@"MRMediaRemoteServiceClient") performSelector:@selector(sharedServiceClient)];
    return [serviceClient performSelector:@selector(activePlayerPath)];
}

static void sendCommandToShownPlayer(MRCommand command, NSDictionary *options) {
    if (!sSendCommandToPlayer) return;
    id path = sTargetPath ?: activePlayerPath();
    if (!path) return;
    if (sTargetPath && sItemID.length && sItemOptionKey) {
        NSMutableDictionary *scoped = [options mutableCopy] ?: [NSMutableDictionary dictionary];
        scoped[(__bridge NSString *)sItemOptionKey] = sItemID;
        options = scoped;
    }
    sSendCommandToPlayer(command, (__bridge CFDictionaryRef)options, nil, path, nil, ^(id result){});
}

static void handleCommand(NSString *line) {
    // Everything that picks the path runs on the feed's queue; a command
    // read before the feed has one waits for the next line.
    if (!sQueue) return;
    dispatch_async(sQueue, ^{ runCommand(line); });
}

static void runCommand(NSString *line) {
    if ([line isEqualToString:@"get"]) {
        publish();
    } else if ([line hasPrefix:@"cmd "]) {
        sendCommandToShownPlayer((MRCommand)[line substringFromIndex:4].intValue, nil);
        publish();
    } else if ([line hasPrefix:@"seek "]) {
        double seconds = [line substringFromIndex:5].doubleValue;
        sendCommandToShownPlayer(MRCommandSeekToPlaybackPosition, @{@"kMRMediaRemoteOptionPlaybackPosition": @(seconds)});
        publish();
    } else if ([line hasPrefix:@"source "]) {
        NSString *bundle = [line substringFromIndex:7];
        sChosen = [bundle isEqualToString:@"-"] ? nil : bundle;
        publish();
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
        sGetPID = (MRGetPIDFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
        sGetClients = (MRGetClientsFn)dlsym(handle, "MRMediaRemoteGetNowPlayingClients");
        sSendCommandToPlayer = (MRSendCommandToPlayerFn)dlsym(handle, "MRMediaRemoteSendCommandToPlayer");
        sGetCommandsForPlayer = (MRGetCommandsForPlayerFn)dlsym(handle, "MRMediaRemoteGetSupportedCommandsForPlayer");
        sClientPID = (MRClientPIDFn)dlsym(handle, "MRNowPlayingClientGetProcessIdentifier");
        sClientBundle = (MRClientStringFn)dlsym(handle, "MRNowPlayingClientGetBundleIdentifier");
        sClientName = (MRClientStringFn)dlsym(handle, "MRNowPlayingClientGetDisplayName");
        sClientParent = (MRClientStringFn)dlsym(handle, "MRNowPlayingClientGetParentAppBundleIdentifier");
        sGetInfoForPlayer = (MRGetInfoForPlayerFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfoForPlayer");
        sArtworkCopyData = (MRArtworkCopyDataFn)dlsym(handle, "MRNowPlayingArtworkCopyImageData");
        CFStringRef *itemKey = (CFStringRef *)dlsym(handle, "kMRMediaRemoteOptionNowPlayingContentItemID");
        if (itemKey) sItemOptionKey = *itemKey;

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
        // them would go stale silently. Cheap enough at this interval to run
        // unconditionally rather than gate it on whether anything is playing —
        // an idle session publishes the same empty record it already would.
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
    startFeed();
    startCommandReader();
}
