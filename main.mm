#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#include <cmath>
#include <unistd.h>

static NSString *const kDoubaoSourceID = @"com.bytedance.inputmethod.doubaoime.pinyin";
static NSString *const kNativeChineseID = @"com.apple.inputmethod.SCIM.Shuangpin";
static NSString *const kNativeEnglishID = @"com.apple.keylayout.US";
static constexpr NSTimeInterval kDefaultRestoreDelay = 1.2;
static constexpr useconds_t kInputSourceActivationDelayUs = 150000;
static constexpr uint64_t kSyntheticRightOptionTag = 0x4442564f5054494f;

enum class VoiceTrigger { None, FnControl, RightOption };
static NSString *const kReadyTitle = @"待命：按住 Fn + Control，或按右 Option";

static NSString *sourceName(TISInputSourceRef source) {
    if (!source) return @"未知";
    CFStringRef name = (CFStringRef)TISGetInputSourceProperty(source, kTISPropertyLocalizedName);
    return name ? (__bridge NSString *)name : @"未知";
}

static NSString *sourceID(TISInputSourceRef source) {
    if (!source) return @"";
    CFStringRef value = (CFStringRef)TISGetInputSourceProperty(source, kTISPropertyInputSourceID);
    return value ? (__bridge NSString *)value : @"";
}

static TISInputSourceRef findSource(NSString *identifier) {
    NSDictionary *filter = @{(__bridge NSString *)kTISPropertyInputSourceID: identifier};
    CFArrayRef sources = TISCreateInputSourceList((__bridge CFDictionaryRef)filter, false);
    if (!sources) return nullptr;
    TISInputSourceRef result = nullptr;
    if (CFArrayGetCount(sources) > 0) result = (TISInputSourceRef)CFRetain(CFArrayGetValueAtIndex(sources, 0));
    CFRelease(sources);
    return result;
}

static void postKey(CGEventSourceRef source, CGKeyCode key, bool down, CGEventFlags flags) {
    CGEventRef event = CGEventCreateKeyboardEvent(source, key, down);
    if (!event) return;
    CGEventSetFlags(event, flags);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void postNextInputSourceShortcut() {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    postKey(source, kVK_Control, true, kCGEventFlagMaskControl);
    usleep(30000);
    postKey(source, kVK_Option, true, kCGEventFlagMaskControl | kCGEventFlagMaskAlternate);
    usleep(30000);
    postKey(source, kVK_Space, true, kCGEventFlagMaskControl | kCGEventFlagMaskAlternate);
    usleep(40000);
    postKey(source, kVK_Space, false, kCGEventFlagMaskControl | kCGEventFlagMaskAlternate);
    usleep(25000);
    postKey(source, kVK_Option, false, kCGEventFlagMaskControl);
    postKey(source, kVK_Control, false, 0);
    if (source) CFRelease(source);
}

static void postRightOptionTap() {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    for (int phase = 0; phase < 2; ++phase) {
        bool down = phase == 0;
        CGEventRef event = CGEventCreateKeyboardEvent(source, kVK_RightOption, down);
        if (!event) continue;
        CGEventSetType(event, kCGEventFlagsChanged);
        CGEventSetFlags(event, down ? (kCGEventFlagMaskAlternate | NX_DEVICERALTKEYMASK) : 0);
        CGEventSetIntegerValueField(event, kCGEventSourceUserData, kSyntheticRightOptionTag);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        if (down) usleep(70000);
    }
    if (source) CFRelease(source);
}

@interface VoiceSwitcher : NSObject <NSApplicationDelegate>
@end

@implementation VoiceSwitcher {
    NSStatusItem *_status;
    NSMenuItem *_stateItem;
    NSMenu *_delayMenu;
    NSTimeInterval _restoreDelay;
    CFMachPortRef _tap;
    CFRunLoopSourceRef _tapSource;
    TISInputSourceRef _doubao;
    TISInputSourceRef _nativeChinese;
    TISInputSourceRef _nativeEnglish;
    NSMenuItem *_fnToggleItem;
    BOOL _fnToggleEnabled;
    BOOL _fnDown;
    BOOL _fnCandidate;
    TISInputSourceRef _previous;
    NSTimer *_restoreTimer;
    BOOL _chordDown;
    VoiceTrigger _voiceTrigger;
    BOOL _rightOptionPending;
    BOOL _rightOptionWaitingForRelease;
    BOOL _switched;
}

static CGEventRef handleEvent(CGEventTapProxy, CGEventType type, CGEventRef event, void *context) {
    VoiceSwitcher *self = (__bridge VoiceSwitcher *)context;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (self->_tap) CGEventTapEnable(self->_tap, true);
        return event;
    }
    if (type == kCGEventKeyDown) {
        if (self->_fnDown) self->_fnCandidate = NO;
        return event;
    }
    if (type != kCGEventFlagsChanged) return event;
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == kSyntheticRightOptionTag) return event;
    CGEventFlags flags = CGEventGetFlags(event);
    BOOL fn = (flags & kCGEventFlagMaskSecondaryFn) != 0;
    BOOL control = (flags & kCGEventFlagMaskControl) != 0;
    BOOL chord = control && fn;
    BOOL rightOptionEvent = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) == kVK_RightOption;
    BOOL rightOptionDown = rightOptionEvent && (flags & NX_DEVICERALTKEYMASK);
    if (fn && !self->_fnDown) {
        self->_fnDown = YES;
        CGEventFlags otherModifiers = kCGEventFlagMaskControl | kCGEventFlagMaskShift |
                                      kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand;
        self->_fnCandidate = self->_fnToggleEnabled && !(flags & otherModifiers) && !self->_switched;
    } else if (fn && self->_fnDown) {
        CGEventFlags otherModifiers = kCGEventFlagMaskControl | kCGEventFlagMaskShift |
                                      kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand;
        if (flags & otherModifiers) self->_fnCandidate = NO;
    }
    BOOL switchedNow = NO;
    if (chord && !self->_chordDown && self->_voiceTrigger == VoiceTrigger::None) {
        switchedNow = [self startVoice];
        if (self->_switched) self->_voiceTrigger = VoiceTrigger::FnControl;
    }
    if (!chord && self->_chordDown && self->_voiceTrigger == VoiceTrigger::FnControl) {
        self->_voiceTrigger = VoiceTrigger::None;
        [self stopVoice];
    }
    self->_chordDown = chord;
    if (rightOptionEvent && self->_rightOptionPending) {
        if (!rightOptionDown && self->_rightOptionWaitingForRelease) {
            self->_rightOptionWaitingForRelease = NO;
            dispatch_async(dispatch_get_main_queue(), ^{ [self advanceToDoubao:8]; });
        }
        return nullptr;
    }
    if (rightOptionDown && !chord) {
        if (self->_voiceTrigger == VoiceTrigger::RightOption) {
            self->_voiceTrigger = VoiceTrigger::None;
            [self stopVoice];
        } else if (self->_voiceTrigger == VoiceTrigger::None) {
            if ([self prepareRightOptionVoice]) return nullptr;
        }
    }
    if (switchedNow) {
        // Keep the original hardware event in the event tap until Doubao is active.
        // Injected replacement events are not reliably recognized by Doubao.
        usleep(kInputSourceActivationDelayUs);
    }
    if (!fn && self->_fnDown) {
        BOOL shouldToggle = self->_fnCandidate;
        self->_fnDown = NO;
        self->_fnCandidate = NO;
        if (shouldToggle) [self toggleNativeInputSource];
    }
    return event;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    _doubao = findSource(kDoubaoSourceID);
    _nativeChinese = findSource(kNativeChineseID);
    _nativeEnglish = findSource(kNativeEnglishID);
    _fnToggleEnabled = [[NSUserDefaults standardUserDefaults] objectForKey:@"fnToggleEnabled"] ?
                       [[NSUserDefaults standardUserDefaults] boolForKey:@"fnToggleEnabled"] : YES;
    _restoreDelay = [[NSUserDefaults standardUserDefaults] doubleForKey:@"restoreDelay"] ?: kDefaultRestoreDelay;
    _status = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"waveform.circle.fill"
                                      accessibilityDescription:@"豆包语音切换"];
    icon = [icon imageWithSymbolConfiguration:
            [NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightRegular]];
    [icon setTemplate:YES];
    _status.button.image = icon;
    _status.button.toolTip = @"豆包语音输入切换器";
    NSMenu *menu = [[NSMenu alloc] init];
    _stateItem = [[NSMenuItem alloc] initWithTitle:@"正在启动…" action:nil keyEquivalent:@""];
    [menu addItem:_stateItem];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *retry = [[NSMenuItem alloc] initWithTitle:@"重新连接键盘监听" action:@selector(startTap) keyEquivalent:@""];
    retry.target = self;
    [menu addItem:retry];
    _fnToggleItem = [[NSMenuItem alloc] initWithTitle:@"单按 Fn 切换系统中英文"
                                              action:@selector(toggleFnSetting:) keyEquivalent:@""];
    _fnToggleItem.target = self;
    _fnToggleItem.state = _fnToggleEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:_fnToggleItem];
    NSMenuItem *delayParent = [[NSMenuItem alloc] initWithTitle:@"语音结束后恢复延迟" action:nil keyEquivalent:@""];
    _delayMenu = [[NSMenu alloc] init];
    for (NSNumber *seconds in @[@0.5, @1.2, @2.0, @3.0]) {
        NSMenuItem *choice = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%.1f 秒", seconds.doubleValue]
                                                       action:@selector(selectDelay:) keyEquivalent:@""];
        choice.target = self;
        choice.representedObject = seconds;
        choice.state = fabs(_restoreDelay - seconds.doubleValue) < 0.01 ? NSControlStateValueOn : NSControlStateValueOff;
        [_delayMenu addItem:choice];
    }
    delayParent.submenu = _delayMenu;
    [menu addItem:delayParent];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];
    _status.menu = menu;
    [self startTap];
}

- (void)startTap {
    if (!_doubao) _doubao = findSource(kDoubaoSourceID);
    if (!_doubao) {
        _stateItem.title = @"未找到已启用的豆包输入法";
        return;
    }
    if (_tap) {
        CGEventTapEnable(_tap, true);
        _stateItem.title = kReadyTitle;
        return;
    }
    _tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                            kCGEventTapOptionDefault,
                            CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(kCGEventKeyDown),
                            handleEvent, (__bridge void *)self);
    if (!_tap) {
        _stateItem.title = @"键盘监听未获权限，点击重试";
        NSLog(@"键盘监听创建失败；辅助功能=%d，输入监控=%d。程序不会自动请求权限。",
              AXIsProcessTrusted(), CGPreflightListenEventAccess());
        return;
    }
    _tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), _tapSource, kCFRunLoopCommonModes);
    CGEventTapEnable(_tap, true);
    _stateItem.title = kReadyTitle;
    NSLog(@"键盘监听已启动");
}

- (void)toggleNativeInputSource {
    if (!_nativeChinese || !_nativeEnglish) {
        _stateItem.title = @"缺少系统简体双拼或美式英文输入法";
        return;
    }
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    NSString *currentID = sourceID(current);
    TISInputSourceRef target = [currentID isEqualToString:kNativeChineseID] ? _nativeEnglish : _nativeChinese;
    OSStatus result = TISSelectInputSource(target);
    if (result != noErr) {
        NSLog(@"切换系统中英文失败：%d", (int)result);
        _stateItem.title = @"系统中英文切换失败";
    } else {
        _stateItem.title = [NSString stringWithFormat:@"已切换至 %@", sourceName(target)];
    }
    if (current) CFRelease(current);
}

- (void)toggleFnSetting:(NSMenuItem *)sender {
    _fnToggleEnabled = !_fnToggleEnabled;
    sender.state = _fnToggleEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [[NSUserDefaults standardUserDefaults] setBool:_fnToggleEnabled forKey:@"fnToggleEnabled"];
    _fnCandidate = NO;
}

- (BOOL)startVoice {
    [_restoreTimer invalidate];
    _restoreTimer = nil;
    if (_switched) {
        _stateItem.title = [NSString stringWithFormat:@"语音输入中 · 将返回 %@", sourceName(_previous)];
        return NO;
    }
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    if (!current) return NO;
    if ([sourceID(current) isEqualToString:kDoubaoSourceID]) {
        CFRelease(current);
        _stateItem.title = @"豆包已是当前输入法";
        return NO;
    }
    if (_previous) CFRelease(_previous);
    _previous = current;
    OSStatus result = TISSelectInputSource(_doubao);
    if (result == noErr) {
        _switched = YES;
        _stateItem.title = [NSString stringWithFormat:@"语音输入中 · 将返回 %@", sourceName(_previous)];
        return YES;
    } else {
        NSLog(@"切换豆包输入法失败：%d", (int)result);
        _stateItem.title = @"切换豆包失败，请检查输入法设置";
        CFRelease(_previous);
        _previous = nullptr;
        return NO;
    }
}

- (BOOL)prepareRightOptionVoice {
    if (_switched) {
        [_restoreTimer invalidate];
        _restoreTimer = nil;
        _voiceTrigger = VoiceTrigger::RightOption;
        _stateItem.title = [NSString stringWithFormat:@"语音输入中 · 将返回 %@", sourceName(_previous)];
        return NO;
    }
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    if (!current) return NO;
    if ([sourceID(current) isEqualToString:kDoubaoSourceID]) {
        CFRelease(current);
        return NO;
    }
    if (_previous) CFRelease(_previous);
    _previous = current;
    _rightOptionPending = YES;
    _rightOptionWaitingForRelease = YES;
    _voiceTrigger = VoiceTrigger::RightOption;
    _stateItem.title = @"正在激活豆包语音…";
    return YES;
}

- (void)advanceToDoubao:(NSUInteger)remaining {
    if (!_rightOptionPending) return;
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    BOOL selected = current && [sourceID(current) isEqualToString:kDoubaoSourceID];
    if (current) CFRelease(current);
    if (selected) {
        _switched = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!self->_rightOptionPending) return;
            postRightOptionTap();
            NSLog(@"豆包已通过系统快捷键激活，已补发右 Option 点按");
            self->_rightOptionPending = NO;
            self->_stateItem.title = [NSString stringWithFormat:@"语音输入中 · 将返回 %@", sourceName(self->_previous)];
        });
        return;
    }
    if (remaining == 0) {
        NSLog(@"系统快捷键未能切换到豆包输入法");
        _rightOptionPending = NO;
        _voiceTrigger = VoiceTrigger::None;
        if (_previous) TISSelectInputSource(_previous);
        if (_previous) CFRelease(_previous);
        _previous = nullptr;
        _stateItem.title = @"无法激活豆包，请检查输入法切换快捷键";
        return;
    }
    postNextInputSourceShortcut();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self advanceToDoubao:remaining - 1]; });
}

- (void)stopVoice {
    if (!_switched) return;
    [_restoreTimer invalidate];
    _stateItem.title = @"等待豆包提交语音结果…";
    _restoreTimer = [NSTimer scheduledTimerWithTimeInterval:_restoreDelay
                                                    target:self
                                                  selector:@selector(restoreInputSource)
                                                  userInfo:nil repeats:NO];
}

- (void)restoreInputSource {
    _restoreTimer = nil;
    if (!_switched || _voiceTrigger != VoiceTrigger::None) return;
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    if (current && [sourceID(current) isEqualToString:kDoubaoSourceID] && _previous) {
        OSStatus result = TISSelectInputSource(_previous);
        if (result != noErr) NSLog(@"恢复输入法失败：%d", (int)result);
    }
    if (current) CFRelease(current);
    if (_previous) CFRelease(_previous);
    _previous = nullptr;
    _switched = NO;
    _stateItem.title = kReadyTitle;
}

- (void)selectDelay:(NSMenuItem *)sender {
    _restoreDelay = [sender.representedObject doubleValue];
    [[NSUserDefaults standardUserDefaults] setDouble:_restoreDelay forKey:@"restoreDelay"];
    for (NSMenuItem *item in _delayMenu.itemArray) {
        item.state = item == sender ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)quit:(id)sender {
    (void)sender;
    [_restoreTimer invalidate];
    _chordDown = NO;
    _rightOptionPending = NO;
    _voiceTrigger = VoiceTrigger::None;
    [self restoreInputSource];
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    if (_tapSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _tapSource, kCFRunLoopCommonModes);
        CFRelease(_tapSource);
    }
    if (_tap) CFRelease(_tap);
    if (_doubao) CFRelease(_doubao);
    if (_nativeChinese) CFRelease(_nativeChinese);
    if (_nativeEnglish) CFRelease(_nativeEnglish);
    if (_previous) CFRelease(_previous);
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--permissions") == 0) {
            printf("accessibility=%d input_monitoring=%d\n",
                   AXIsProcessTrusted(), CGPreflightListenEventAccess());
            return 0;
        }
        if (argc > 1 && strcmp(argv[1], "--list") == 0) {
            CFArrayRef sources = TISCreateInputSourceList(nullptr, false);
            if (sources) {
                for (CFIndex i = 0; i < CFArrayGetCount(sources); ++i) {
                    TISInputSourceRef source = (TISInputSourceRef)CFArrayGetValueAtIndex(sources, i);
                    printf("%s\t%s\n", sourceID(source).UTF8String, sourceName(source).UTF8String);
                }
                CFRelease(sources);
            }
            return 0;
        }
        [NSApplication sharedApplication];
        VoiceSwitcher *delegate = [[VoiceSwitcher alloc] init];
        NSApp.delegate = delegate;
        [NSApp run];
    }
    return 0;
}
