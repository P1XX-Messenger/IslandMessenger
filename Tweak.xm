/*
 ═══════════════════════════════════════════════════════════════════════
  IslandMessenger — один файл Tweak.xm (Theos + Logos, процесс SpringBoard)
  iOS 16.0+ · iPhone 14 Pro / 15 / 16 · Dopamine / palera1n (rootless + rootful)
 ═══════════════════════════════════════════════════════════════════════

  СБОРКА. Создай папку проекта и положи 4 файла (Tweak.xm — этот):

  ── Makefile ──────────────────────────────────────────────────────────
  export THEOS_PACKAGE_SCHEME = rootless
  TARGET := iphone:clang:latest:16.0
  ARCHS = arm64 arm64e
  INSTALL_TARGET_PROCESSES = SpringBoard
  include $(THEOS)/makefiles/common.mk
  TWEAK_NAME = IslandMessenger
  IslandMessenger_FILES = Tweak.xm
  IslandMessenger_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
  IslandMessenger_FRAMEWORKS = UIKit QuartzCore AVFoundation Accelerate AudioToolbox
  include $(THEOS_MAKE_PATH)/tweak.mk
  (для rootful-пакета удали первую строку Makefile и собери ещё раз)

  ── IslandMessenger.plist ─────────────────────────────────────────────
  { Filter = { Bundles = ( "com.apple.springboard" ); }; }

  ── control ───────────────────────────────────────────────────────────
  Package: com.pups.islandmessenger
  Name: IslandMessenger
  Version: 1.0.0
  Architecture: iphoneos-arm
  Description: Customizable Dynamic Island with in-island messenger
  Maintainer: Pups
  Author: Pups
  Section: Tweaks
  Depends: mobilesubstrate, firmware (>= 16.0)

  КАК ПОЛЬЗОВАТЬСЯ.
  • Долгое нажатие на остров (в свёрнутом виде) открывает панель настроек:
    все ползунки работают вживую, остров меняется прямо на глазах.
  • Тап по острову: есть уведомления — чат-карточка, нет — плеер (громкость + эквалайзер).
  • «Тест уведомления» в панели показывает карточку без реального сообщения.

  ЧЕСТНО О ПРИВАТНЫХ API (нельзя проверить без устройства):
  • Перехват: NCNotificationDispatcher (запасной вариант — BBServer).
  • Ответ iMessage: IMCore (IMChat). CKChatController — это UI приложения «Сообщения»,
    в SpringBoard он не работает; IMChat — слой под ним.
  • Универсальный ответ: текстовое действие уведомления (BBAction/NCNotificationAction —
    аналог UNTextInputNotificationAction) + ответ через BBResponse / actionRunner.
    Это самое хрупкое место, ключи и селекторы зависят от версии iOS.
  • Громкость: MediaRemote отдаёт только now-playing и команды, поэтому уровень
    и установка громкости идут через AVSystemController (Celestial), плей/пауза — MediaRemote.
  • Эквалайзер: AVAudioEngine не может «подслушать» звук чужих приложений из SpringBoard.
    Источник «Микрофон» — настоящий tap на inputNode (нужно разрешение микрофона),
    источник «Анимация» — привязан к MediaRemote (играет/пауза) и громкости.
 ═══════════════════════════════════════════════════════════════════════
*/

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/utsname.h>

#pragma clang diagnostic ignored "-Wundeclared-selector"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wunused-function"

#define ISL_DOMAIN  @"com.pups.islandmessenger"
#define ISL_CHANGED @"com.pups.islandmessenger.changed"
#define ISL_MEDIA   @"com.pups.islandmessenger.media"

#pragma mark - Утилиты

static void ISLMain(void (^b)(void)) {
    if ([NSThread isMainThread]) b(); else dispatch_async(dispatch_get_main_queue(), b);
}
static id ISLKV(id o, NSString *k) {
    if (!o) return nil;
    @try { return [o valueForKey:k]; } @catch (__unused id e) { return nil; }
}
static NSString *ISLStr(id v) {
    return ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) ? (NSString *)v : nil;
}
static id ISLCall0(id o, NSString *s) {
    SEL sel = NSSelectorFromString(s);
    if (o && [o respondsToSelector:sel]) return ((id (*)(id, SEL))objc_msgSend)(o, sel);
    return nil;
}
static id ISLCall1(id o, NSString *s, id a) {
    SEL sel = NSSelectorFromString(s);
    if (o && [o respondsToSelector:sel]) return ((id (*)(id, SEL, id))objc_msgSend)(o, sel, a);
    return nil;
}
static NSArray *ISLFlatten(id v) {
    NSMutableArray *o = [NSMutableArray array];
    if ([v isKindOfClass:[NSArray class]]) [o addObjectsFromArray:v];
    else if ([v isKindOfClass:[NSSet class]]) [o addObjectsFromArray:[v allObjects]];
    else if ([v isKindOfClass:[NSDictionary class]]) { for (id x in [v allValues]) [o addObjectsFromArray:ISLFlatten(x)]; }
    else if (v) [o addObject:v];
    return o;
}
static void ISLLoadPrivate(void) {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/Celestial.framework/Celestial", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    });
}
static id ISLAVC(void) {
    ISLLoadPrivate();
    return ISLCall0(NSClassFromString(@"AVSystemController"), @"sharedAVSystemController");
}
static void ISLOpenApp(NSString *bid) {
    if (!bid.length) return;
    ISLLoadPrivate();
    typedef int (*SBSLaunchFn)(CFStringRef, Boolean);
    SBSLaunchFn fn = (SBSLaunchFn)dlsym(RTLD_DEFAULT, "SBSLaunchApplicationWithIdentifier");
    if (fn) { fn((__bridge CFStringRef)bid, false); return; }
    UIApplication *a = [UIApplication sharedApplication];
    SEL s = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if ([a respondsToSelector:s]) ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(a, s, bid, NO);
}
static UIImage *ISLAppIcon(NSString *bid) {
    if (!bid.length) return nil;
    SEL s = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([UIImage respondsToSelector:s])
        return ((UIImage *(*)(id, SEL, id, int, CGFloat))objc_msgSend)([UIImage class], s, bid, 0, [UIScreen mainScreen].scale);
    return nil;
}

#pragma mark - Настройки

@interface ISLConfig : NSObject
+ (NSUserDefaults *)d;
+ (CGFloat)f:(NSString *)k;
+ (BOOL)b:(NSString *)k;
+ (NSInteger)i:(NSString *)k;
+ (void)set:(id)v for:(NSString *)k;
+ (UIColor *)hsb:(NSString *)prefix;
@end

@implementation ISLConfig
+ (NSUserDefaults *)d {
    static NSUserDefaults *d; static dispatch_once_t t;
    dispatch_once(&t, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:ISL_DOMAIN];
        [d registerDefaults:@{
            // вид
            @"shape": @0, @"width": @126, @"height": @37, @"offX": @0, @"offY": @0, @"pin": @YES,
            @"radius": @18.5, @"radiusExp": @34, @"holeOp": @1, @"alpha": @1,
            // цвет
            @"gradient": @NO, @"gradAngle": @90,
            @"bgH": @0, @"bgS": @0, @"bgB": @0,
            @"bg2H": @0.62, @"bg2S": @0.65, @"bg2B": @0.40,
            @"strokeW": @0, @"strokeH": @0.6, @"strokeS": @0, @"strokeB": @1,
            @"tintH": @0, @"tintS": @0, @"tintB": @1,
            // медиа
            @"eqOn": @YES, @"eqSource": @0,
            // сообщения
            @"msgOn": @YES, @"mode": @0, @"timeout": @8, @"listMode": @0,
            @"listIDs": @[@"com.apple.MobileSMS", @"net.whatsapp.WhatsApp", @"ph.telegra.Telegraph", @"org.whispersystems.signal"],
            @"hideBanner": @YES, @"haptics": @YES,
            // клавиатура
            @"kbH": @220, @"kbEmoji": @YES, @"quickSend": @YES, @"lang": @0
        }];
    });
    return d;
}
+ (CGFloat)f:(NSString *)k { return [[self d] floatForKey:k]; }
+ (BOOL)b:(NSString *)k { return [[self d] boolForKey:k]; }
+ (NSInteger)i:(NSString *)k { return [[self d] integerForKey:k]; }
+ (void)set:(id)v for:(NSString *)k {
    [[self d] setObject:v forKey:k];
    ISLMain(^{ [[NSNotificationCenter defaultCenter] postNotificationName:ISL_CHANGED object:nil]; });
}
+ (UIColor *)hsb:(NSString *)p {
    return [UIColor colorWithHue:[self f:[p stringByAppendingString:@"H"]]
                      saturation:[self f:[p stringByAppendingString:@"S"]]
                      brightness:[self f:[p stringByAppendingString:@"B"]] alpha:1];
}
@end

#pragma mark - Устройство, геометрия, haptics

static BOOL ISLHasIsland(void) {
    static BOOL r; static dispatch_once_t t;
    dispatch_once(&t, ^{
        struct utsname u; uname(&u);
        NSString *m = [NSString stringWithUTF8String:u.machine];
        if ([m hasPrefix:@"iPhone"]) {
            NSArray *p = [[m substringFromIndex:6] componentsSeparatedByString:@","];
            if (p.count == 2) {
                int a = [p[0] intValue], b = [p[1] intValue];
                if (a >= 18) r = YES;            // iPhone 17 и новее
                else if (a == 17) r = (b != 5);  // 16 / 16 Plus / 16 Pro / Pro Max; 17,5 = 16e без острова
                else if (a == 16) r = YES;       // 15 Pro / Pro Max
                else if (a == 15) r = (b >= 2);  // 14 Pro / Pro Max, 15 / 15 Plus
                else r = NO;
                return;
            }
        }
        UIWindow *w = [UIApplication sharedApplication].windows.firstObject;   // симулятор / неизвестная модель
        r = w.safeAreaInsets.top >= 58;
    });
    return r;
}
static CGFloat ISLSafeTop(UIView *v) {
    CGFloat t = v.safeAreaInsets.top;
    if (t > 0) return t;
    if (ISLHasIsland()) return 59;
    CGSize s = [UIScreen mainScreen].bounds.size;
    return MAX(s.width, s.height) <= 736 ? 20 : 47;
}
static void ISLTick(void) {
    if (![ISLConfig b:@"haptics"]) return;
    static UIImpactFeedbackGenerator *g;
    if (!g) g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [g impactOccurred];
}
static void ISLBuzz(UINotificationFeedbackType t) {
    if (![ISLConfig b:@"haptics"]) return;
    static UINotificationFeedbackGenerator *g;
    if (!g) g = [UINotificationFeedbackGenerator new];
    [g notificationOccurred:t];
}

#pragma mark - Модель уведомления

@interface ISLNote : NSObject
@property (nonatomic, copy) NSString *bundleID, *title, *text, *threadID, *noteID;
@property (nonatomic, strong) UIImage *avatar;
@property (nonatomic, strong) id request, bulletin;
@property (nonatomic) BOOL isTest;
@end
@implementation ISLNote @end

#pragma mark - Медиа: now-playing (MediaRemote) + громкость (AVSystemController)

@interface ISLMedia : NSObject
@property (nonatomic) BOOL playing;
@property (nonatomic, copy) NSString *title, *artist;
@property (nonatomic) float volume;
+ (instancetype)shared;
- (void)start;
- (void)refresh;
- (void)pollVolume;
- (void)setVolumeValue:(float)v;
- (void)command:(int)c;   // 0 play, 1 pause, 2 toggle, 4 next, 5 previous
@end

@implementation ISLMedia
+ (instancetype)shared {
    static ISLMedia *m; static dispatch_once_t t;
    dispatch_once(&t, ^{ m = [ISLMedia new]; });
    return m;
}
- (void)post { [[NSNotificationCenter defaultCenter] postNotificationName:ISL_MEDIA object:nil]; }
- (void)start {
    static BOOL started; if (started) return; started = YES;
    ISLLoadPrivate();
    void (*reg)(dispatch_queue_t) = (void (*)(dispatch_queue_t))dlsym(RTLD_DEFAULT, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (reg) reg(dispatch_get_main_queue());
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(refresh) name:@"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification" object:nil];
    [nc addObserver:self selector:@selector(refresh) name:@"kMRMediaRemoteNowPlayingInfoDidChangeNotification" object:nil];
    [nc addObserver:self selector:@selector(volNote:) name:@"AVSystemController_SystemVolumeDidChangeNotification" object:nil];
    id c = ISLAVC();
    SEL sub = NSSelectorFromString(@"setAttribute:forKey:error:");
    if ([c respondsToSelector:sub]) {
        NSError *e = nil;
        ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(c, sub, @[@"AVSystemController_SystemVolumeDidChangeNotification"], @"AVSystemController_SubscribeToNotificationsAttribute", &e);
    }
    [self refresh];
    [self pollVolume];
}
- (void)refresh {
    typedef void (^PlayCB)(Boolean);
    typedef void (^InfoCB)(CFDictionaryRef);
    void (*isPlaying)(dispatch_queue_t, PlayCB) = (void (*)(dispatch_queue_t, PlayCB))dlsym(RTLD_DEFAULT, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    void (*getInfo)(dispatch_queue_t, InfoCB) = (void (*)(dispatch_queue_t, InfoCB))dlsym(RTLD_DEFAULT, "MRMediaRemoteGetNowPlayingInfo");
    if (isPlaying) isPlaying(dispatch_get_main_queue(), ^(Boolean p) { self.playing = p; [self post]; });
    if (getInfo) getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef d) {
        NSDictionary *i = (__bridge NSDictionary *)d;
        self.title = ISLStr(i[@"kMRMediaRemoteNowPlayingInfoTitle"]);
        self.artist = ISLStr(i[@"kMRMediaRemoteNowPlayingInfoArtist"]);
        [self post];
    });
}
- (void)volNote:(NSNotification *)n {
    NSNumber *v = n.userInfo[@"AVSystemController_AudioVolumeNotificationParameter"];
    if ([v isKindOfClass:[NSNumber class]]) { _volume = v.floatValue; [self post]; }
}
- (void)pollVolume {
    id c = ISLAVC();
    SEL s = NSSelectorFromString(@"getVolume:forCategory:");
    if (![c respondsToSelector:s]) return;
    float v = 0;
    BOOL ok = ((BOOL (*)(id, SEL, float *, id))objc_msgSend)(c, s, &v, @"Audio/Video");
    if (ok && fabsf(v - _volume) > 0.001f) { _volume = v; [self post]; }
}
- (void)setVolumeValue:(float)v {
    v = MAX(0, MIN(1, v));
    id c = ISLAVC();
    SEL s = NSSelectorFromString(@"setVolumeTo:forCategory:");
    if ([c respondsToSelector:s]) ((BOOL (*)(id, SEL, float, id))objc_msgSend)(c, s, v, @"Audio/Video");
    _volume = v;
}
- (void)command:(int)cmd {
    ISLLoadPrivate();
    Boolean (*send)(int, id) = (Boolean (*)(int, id))dlsym(RTLD_DEFAULT, "MRMediaRemoteSendCommand");
    if (send) send(cmd, nil);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self refresh]; });
}
@end

#pragma mark - Эквалайзер (AVAudioEngine tap + vDSP FFT)

@interface ISLEqView : UIView
@property (nonatomic) NSInteger count;
@property (nonatomic) BOOL allowMic;
@property (nonatomic, strong) UIColor *barColor;
- (void)startRunning;
- (void)stopRunning;
@end

@implementation ISLEqView {
    NSMutableArray<CALayer *> *_bars;
    CADisplayLink *_link;
    float _lvl[16];
    volatile float _tgt[16];
    AVAudioEngine *_engine;
    BOOL _micOn;
}
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (!self) return nil;
    _count = 9; _allowMic = YES; _barColor = [UIColor whiteColor]; _bars = [NSMutableArray new];
    self.userInteractionEnabled = NO;
    for (int i = 0; i < 16; i++) {
        CALayer *l = [CALayer layer]; l.backgroundColor = _barColor.CGColor;
        [self.layer addSublayer:l]; [_bars addObject:l];
    }
    return self;
}
- (void)setBarColor:(UIColor *)c {
    _barColor = c;
    for (CALayer *l in _bars) l.backgroundColor = c.CGColor;
}
- (void)layoutBars {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    NSInteger n = MAX(1, MIN(16, _count));
    CGFloat gap = 2, bw = (w - gap * (n - 1)) / n;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (NSInteger i = 0; i < 16; i++) {
        CALayer *l = _bars[i];
        if (i >= n) { l.hidden = YES; continue; }
        l.hidden = NO;
        CGFloat bh = MAX(2, _lvl[i] * h);
        l.frame = CGRectMake(i * (bw + gap), h - bh, bw, bh);
        l.cornerRadius = MIN(bw / 2, 3);
    }
    [CATransaction commit];
}
- (void)layoutSubviews { [super layoutSubviews]; [self layoutBars]; }
- (void)tick {
    ISLMedia *m = [ISLMedia shared];
    float t = (float)CACurrentMediaTime();
    for (NSInteger i = 0; i < _count && i < 16; i++) {
        float tg;
        if (_micOn) tg = _tgt[i];
        else if (m.playing) {
            float a = fabsf(sinf(t * (2.1f + 0.37f * i) + i * 1.7f));
            float b = fabsf(sinf(t * 0.9f + i));
            tg = (0.15f + 0.85f * a * (0.4f + 0.6f * b)) * (0.2f + 0.8f * m.volume);
        } else tg = 0;
        _lvl[i] = tg > _lvl[i] ? tg : _lvl[i] * 0.80f + tg * 0.20f;
    }
    [self layoutBars];
}
- (void)startRunning {
    if (!_link) {
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
        _link.preferredFramesPerSecond = 30;
        [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    if (_allowMic && [ISLConfig i:@"eqSource"] == 1) [self startMic];
}
- (void)stopRunning {
    [_link invalidate]; _link = nil;
    [self stopMic];
    memset(_lvl, 0, sizeof(_lvl));
    [self layoutBars];
}
- (void)startMic {
    if (_engine) return;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    if (s.recordPermission != AVAudioSessionRecordPermissionGranted) return;   // без запроса, чтобы не падать в SpringBoard
    NSError *e = nil;
    [s setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeMeasurement options:AVAudioSessionCategoryOptionMixWithOthers error:&e];
    if (e) return;
    [s setActive:YES error:&e];
    if (e) return;
    AVAudioEngine *eng = [AVAudioEngine new];
    AVAudioInputNode *in = eng.inputNode;
    AVAudioFormat *fmt = [in outputFormatForBus:0];
    if (fmt.sampleRate <= 0) return;
    __weak ISLEqView *ws = self;
    [in installTapOnBus:0 bufferSize:1024 format:fmt block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) { [ws analyze:buf]; }];
    [eng prepare];
    if (![eng startAndReturnError:&e]) { [in removeTapOnBus:0]; return; }
    _engine = eng; _micOn = YES;
}
- (void)stopMic {
    if (!_engine) return;
    [_engine.inputNode removeTapOnBus:0];
    [_engine stop]; _engine = nil; _micOn = NO;
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
}
- (void)analyze:(AVAudioPCMBuffer *)buf {
    if (!buf.floatChannelData) return;
    static FFTSetup setup; static float win[1024]; static dispatch_once_t t;
    dispatch_once(&t, ^{ setup = vDSP_create_fftsetup(10, kFFTRadix2); vDSP_hann_window(win, 1024, vDSP_HANN_NORM); });
    const int N = 1024;
    float tmp[1024]; memset(tmp, 0, sizeof(tmp));
    int n = (int)MIN((NSUInteger)N, (NSUInteger)buf.frameLength);
    vDSP_vmul(buf.floatChannelData[0], 1, win, 1, tmp, 1, (vDSP_Length)n);
    float re[512], im[512];
    DSPSplitComplex sc = { re, im };
    vDSP_ctoz((const DSPComplex *)tmp, 2, &sc, 1, N / 2);
    vDSP_fft_zrip(setup, &sc, 1, 10, FFT_FORWARD);
    float mag[512];
    vDSP_zvmags(&sc, 1, mag, 1, N / 2);
    NSInteger bars = MAX(1, MIN(16, _count));
    for (NSInteger i = 0; i < bars; i++) {
        int lo = MAX(1, (int)powf(256.f, (float)i / bars));
        int hi = MAX(lo + 1, (int)powf(256.f, (float)(i + 1) / bars));
        float sum = 0; int c = 0;
        for (int k = lo; k < hi && k < 512; k++) { sum += mag[k]; c++; }
        float avg = c ? sum / c : 0;
        _tgt[i] = MIN(1.f, log10f(1.f + avg) / 6.f);
    }
}
- (void)dealloc { [_link invalidate]; [self stopMic]; }
@end

#pragma mark - Вспомогательные вью

@interface ISLGradientView : UIView @end
@implementation ISLGradientView
+ (Class)layerClass { return [CAGradientLayer class]; }
@end

// «Ушки» челки: вогнутые скругления по бокам плоской верхней кромки
@interface ISLEarView : UIView
@property (nonatomic) BOOL right;
@property (nonatomic, strong) UIColor *fill;
@end
@implementation ISLEarView
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    self.backgroundColor = [UIColor clearColor]; self.opaque = NO; self.userInteractionEnabled = NO;
    return self;
}
- (void)setFill:(UIColor *)c { _fill = c; [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)r {
    CGFloat s = self.bounds.size.width;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (self.right) { CGContextTranslateCTM(ctx, s, 0); CGContextScaleCTM(ctx, -1, 1); }
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(0, 0)];
    [p addLineToPoint:CGPointMake(s, 0)];
    [p addLineToPoint:CGPointMake(s, s)];
    [p addArcWithCenter:CGPointMake(0, s) radius:s startAngle:0 endAngle:-M_PI_2 clockwise:NO];
    [p closePath];
    [(self.fill ?: [UIColor blackColor]) setFill];
    [p fill];
}
@end

#pragma mark - Мини-клавиатура (UIInputView, без Full Access)

@interface ISLKey : UIButton
@property (nonatomic, strong) UIColor *base, *hi;
@end
@implementation ISLKey
- (void)setHighlighted:(BOOL)h {
    [super setHighlighted:h];
    self.backgroundColor = h ? self.hi : self.base;
}
@end

// EN — референсная раскладка (QWERTY), RU — шаблон (ЙЦУКЕН)
static NSArray<NSString *> *ISLLetterRows(NSInteger lang) {
    if (lang == 1) return @[@"qwertyuiop", @"asdfghjkl", @"zxcvbnm"];
    return @[@"йцукенгшщзхъ", @"фывапролджэ", @"ячсмитьбю"];
}
static NSArray<NSString *> *ISLSymbolRows(void) {
    return @[@"1234567890", @"-/:;()₽&@\"", @".,?!'"];
}
static NSArray<NSString *> *ISLQuick(NSInteger lang) {
    if (lang == 1) return @[@"OK", @"Got it 👍", @"Will reply soon", @"Call you later", @"Thanks!", @"Busy, text you later"];
    return @[@"Ок", @"Хорошо 👍", @"Скоро отвечу", @"Перезвоню позже", @"Спасибо!", @"Занят, напишу позже"];
}
static NSArray<NSString *> *ISLEmojis(void) {
    static NSArray *a; static dispatch_once_t t;
    dispatch_once(&t, ^{
        NSString *s = @"😀😃😄😁😆😅😂🤣😊😇🙂😉😍🥰😘😋😎🤗🤔😐😴😢😭😡😱🙏👍👎👌✌️👏🙌💪❤️🧡💛💚💙💜🔥✨🎉🎂☕🍕🌹☀️🌙⭐🚀";
        NSMutableArray *m = [NSMutableArray array];
        [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences
                           usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop) { [m addObject:sub]; }];
        a = m;
    });
    return a;
}

typedef NS_ENUM(NSInteger, ISLPage) { ISLPageLetters = 0, ISLPageSymbols = 1, ISLPageEmoji = 2 };

@interface ISLKeyboard : UIInputView
@property (nonatomic, copy) void (^onChange)(NSString *text);
@property (nonatomic, copy) void (^onSend)(NSString *text);
@property (nonatomic) NSInteger lang;   // 0 = RU, 1 = EN
- (NSString *)current;
- (void)reset;
@end

@implementation ISLKeyboard {
    NSMutableString *_buf;
    ISLPage _page;
    NSInteger _shift;      // 0 выкл, 1 одна заглавная, 2 caps lock
    BOOL _dirty;
    CGSize _last;
    UIScrollView *_quick;
    UIView *_keys;
    NSTimer *_rep;
    CFTimeInterval _shiftT;
    NSMutableArray<ISLKey *> *_letters;
    ISLKey *_shiftKey;
}
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f inputViewStyle:UIInputViewStyleDefault];
    if (!self) return nil;
    self.allowsSelfSizing = YES;
    self.backgroundColor = [UIColor clearColor];
    _buf = [NSMutableString new]; _letters = [NSMutableArray new];
    _quick = [UIScrollView new]; _quick.showsHorizontalScrollIndicator = NO; [self addSubview:_quick];
    _keys = [UIView new]; [self addSubview:_keys];
    _lang = [ISLConfig i:@"lang"]; _shift = 1; _dirty = YES;
    return self;
}
- (NSString *)current { return [_buf copy]; }
- (void)changed { if (self.onChange) self.onChange([_buf copy]); }
- (void)markDirty { _dirty = YES; [self setNeedsLayout]; }
- (void)setLang:(NSInteger)l { _lang = l; [self markDirty]; }
- (void)reset {
    [_buf setString:@""]; _page = ISLPageLetters; _shift = 1; _lang = [ISLConfig i:@"lang"];
    [self markDirty]; [self changed];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if (!_dirty && CGSizeEqualToSize(_last, self.bounds.size)) return;
    _last = self.bounds.size; _dirty = NO;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    _quick.frame = CGRectMake(0, 0, W, 34);
    _keys.frame = CGRectMake(0, 38, W, MAX(0, H - 38));
    [self rebuildQuick];
    [self rebuildKeys];
}
- (void)rebuildQuick {
    [_quick.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    CGFloat x = 8;
    for (NSString *q in ISLQuick(_lang)) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        [b setTitle:q forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
        b.layer.cornerRadius = 15; b.layer.cornerCurve = kCACornerCurveContinuous;
        CGSize s = [q sizeWithAttributes:@{NSFontAttributeName: b.titleLabel.font}];
        b.frame = CGRectMake(x, 2, ceil(s.width) + 24, 30);
        [b addTarget:self action:@selector(quickTap:) forControlEvents:UIControlEventTouchUpInside];
        [_quick addSubview:b];
        x += b.frame.size.width + 6;
    }
    _quick.contentSize = CGSizeMake(x + 2, 34);
}
- (ISLKey *)mk:(NSString *)t style:(int)st frame:(CGRect)f {
    ISLKey *b = [ISLKey buttonWithType:UIButtonTypeCustom];
    b.frame = f;
    b.layer.cornerRadius = 7; b.layer.cornerCurve = kCACornerCurveContinuous;
    if (st == 0)      { b.base = [UIColor colorWithWhite:1 alpha:0.20]; b.hi = [UIColor colorWithWhite:1 alpha:0.42]; }
    else if (st == 1) { b.base = [UIColor colorWithWhite:1 alpha:0.10]; b.hi = [UIColor colorWithWhite:1 alpha:0.30]; }
    else              { b.base = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1]; b.hi = [UIColor colorWithRed:0.35 green:0.88 blue:0.50 alpha:1]; }
    b.backgroundColor = b.base;
    b.titleLabel.font = [UIFont systemFontOfSize:(st == 0 ? 20 : 15) weight:(st == 0 ? UIFontWeightRegular : UIFontWeightSemibold)];
    b.titleLabel.adjustsFontSizeToFitWidth = YES; b.titleLabel.minimumScaleFactor = 0.6;
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_keys addSubview:b];
    return b;
}
- (void)rebuildKeys {
    [_keys.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    [_letters removeAllObjects]; _shiftKey = nil;
    CGFloat W = _keys.bounds.size.width, H = _keys.bounds.size.height;
    if (W < 60 || H < 60) return;
    const CGFloat m = 4, g = 5;
    CGFloat rowH = (H - 3 * g) / 4.0;
    NSArray<NSString *> *rows = (_page == ISLPageSymbols) ? ISLSymbolRows() : ISLLetterRows(_lang);
    NSUInteger nMax = [rows[0] length];
    CGFloat kw = (W - 2 * m - (nMax - 1) * g) / nMax;

    if (_page == ISLPageEmoji) {
        UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, W, rowH * 3 + g * 2)];
        sv.showsHorizontalScrollIndicator = NO; [_keys addSubview:sv];
        NSArray *em = ISLEmojis(); CGFloat cw = 42;
        for (NSUInteger i = 0; i < em.count; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake((i / 3) * cw + 4, (i % 3) * (rowH + g), cw, rowH);
            b.titleLabel.font = [UIFont systemFontOfSize:26];
            [b setTitle:em[i] forState:UIControlStateNormal];
            [b addTarget:self action:@selector(emojiTap:) forControlEvents:UIControlEventTouchUpInside];
            [sv addSubview:b];
        }
        sv.contentSize = CGSizeMake(ceil(em.count / 3.0) * cw + 8, sv.bounds.size.height);
    } else {
        for (NSUInteger r = 0; r < 3; r++) {
            NSMutableArray *items = [NSMutableArray array];   // @[заголовок, вид(0 символ/1 shift/2 backspace), ширина в «клавишах»]
            if (r == 2 && _page == ISLPageLetters) [items addObject:@[@"⇧", @1, @1.5]];
            [rows[r] enumerateSubstringsInRange:NSMakeRange(0, [rows[r] length]) options:NSStringEnumerationByComposedCharacterSequences
                                     usingBlock:^(NSString *sub, NSRange rr, NSRange er, BOOL *stop) { [items addObject:@[sub, @0, @1.0]]; }];
            if (r == 2) [items addObject:@[@"⌫", @2, @1.5]];
            CGFloat units = 0; for (NSArray *it in items) units += [it[2] floatValue];
            CGFloat k = MIN(kw, (W - 2 * m - (items.count - 1) * g) / units);
            CGFloat total = units * k + (items.count - 1) * g;
            CGFloat x = (W - total) / 2, y = r * (rowH + g);
            for (NSArray *it in items) {
                CGFloat w = k * [it[2] floatValue];
                int kind = [it[1] intValue];
                CGRect fr = CGRectMake(x, y, w, rowH);
                if (kind == 0) {
                    ISLKey *b = [self mk:it[0] style:0 frame:fr];
                    b.accessibilityLabel = it[0];
                    [b addTarget:self action:@selector(charDown:) forControlEvents:UIControlEventTouchDown];
                    if (_page == ISLPageLetters) [_letters addObject:b];
                } else if (kind == 1) {
                    _shiftKey = [self mk:it[0] style:1 frame:fr];
                    [_shiftKey addTarget:self action:@selector(shiftTap) forControlEvents:UIControlEventTouchDown];
                } else {
                    ISLKey *b = [self mk:it[0] style:1 frame:fr];
                    [b addTarget:self action:@selector(bsDown) forControlEvents:UIControlEventTouchDown];
                    [b addTarget:self action:@selector(bsUp) forControlEvents:(UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel)];
                }
                x += w + g;
            }
        }
    }
    // нижний ряд: 123/ABC · язык · эмодзи · пробел · отправить
    BOOL emojiOn = [ISLConfig b:@"kbEmoji"];
    CGFloat y = 3 * (rowH + g), w1 = kw * 1.5, w2 = kw * 1.3, wSend = kw * 2.2;
    CGFloat wSpace = W - 2 * m - w1 - w2 - (emojiOn ? w2 : 0) - wSend - g * (emojiOn ? 4 : 3);
    CGFloat x = m;
    ISLKey *kPage = [self mk:(_page == ISLPageLetters ? @"123" : @"ABC") style:1 frame:CGRectMake(x, y, w1, rowH)]; x += w1 + g;
    [kPage addTarget:self action:@selector(pageTap) forControlEvents:UIControlEventTouchUpInside];
    ISLKey *kLang = [self mk:@"🌐" style:1 frame:CGRectMake(x, y, w2, rowH)]; x += w2 + g;
    [kLang addTarget:self action:@selector(langTap) forControlEvents:UIControlEventTouchUpInside];
    if (emojiOn) {
        ISLKey *kEm = [self mk:(_page == ISLPageEmoji ? @"⌨︎" : @"😀") style:1 frame:CGRectMake(x, y, w2, rowH)]; x += w2 + g;
        [kEm addTarget:self action:@selector(emojiPageTap) forControlEvents:UIControlEventTouchUpInside];
    }
    ISLKey *kSp = [self mk:(_lang == 1 ? @"space" : @"пробел") style:0 frame:CGRectMake(x, y, wSpace, rowH)]; x += wSpace + g;
    kSp.titleLabel.font = [UIFont systemFontOfSize:14];
    [kSp addTarget:self action:@selector(spaceTap) forControlEvents:UIControlEventTouchDown];
    ISLKey *kSend = [self mk:(_lang == 1 ? @"Send" : @"Отпр.") style:2 frame:CGRectMake(x, y, wSend, rowH)];
    [kSend addTarget:self action:@selector(sendTap) forControlEvents:UIControlEventTouchUpInside];
    [self refreshCase];
}
- (void)refreshCase {
    for (ISLKey *k in _letters) {
        NSString *low = k.accessibilityLabel;
        [k setTitle:(_shift > 0 ? [low uppercaseString] : low) forState:UIControlStateNormal];
    }
    _shiftKey.base = _shift > 0 ? [UIColor colorWithWhite:1 alpha:0.55] : [UIColor colorWithWhite:1 alpha:0.10];
    _shiftKey.backgroundColor = _shiftKey.base;
    [_shiftKey setTitle:(_shift == 2 ? @"⇪" : @"⇧") forState:UIControlStateNormal];
}
- (void)charDown:(ISLKey *)k {
    [_buf appendString:[k titleForState:UIControlStateNormal]];
    if (_shift == 1) { _shift = 0; [self refreshCase]; }
    ISLTick(); [self changed];
}
- (void)emojiTap:(UIButton *)b { [_buf appendString:[b titleForState:UIControlStateNormal]]; ISLTick(); [self changed]; }
- (void)spaceTap { [_buf appendString:@" "]; ISLTick(); [self changed]; }
- (void)shiftTap {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _shiftT < 0.3) _shift = 2; else _shift = (_shift == 0) ? 1 : 0;
    _shiftT = now; ISLTick(); [self refreshCase];
}
- (void)backspace {
    if (_buf.length) { [_buf deleteCharactersInRange:[_buf rangeOfComposedCharacterSequenceAtIndex:_buf.length - 1]]; [self changed]; }
}
- (void)bsDown {
    ISLTick(); [self backspace];
    [_rep invalidate];
    _rep = [NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(bsStart) userInfo:nil repeats:NO];
}
- (void)bsStart { _rep = [NSTimer scheduledTimerWithTimeInterval:0.07 target:self selector:@selector(backspace) userInfo:nil repeats:YES]; }
- (void)bsUp { [_rep invalidate]; _rep = nil; }
- (void)pageTap { ISLTick(); _page = (_page == ISLPageLetters) ? ISLPageSymbols : ISLPageLetters; [self markDirty]; }
- (void)emojiPageTap { ISLTick(); _page = (_page == ISLPageEmoji) ? ISLPageLetters : ISLPageEmoji; [self markDirty]; }
- (void)langTap {
    ISLTick(); _lang = (_lang == 1) ? 0 : 1; _page = ISLPageLetters;
    [ISLConfig set:@(_lang) for:@"lang"];
    [self markDirty]; [self changed];
}
- (void)sendTap {
    NSString *t = [_buf stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    ISLTick();
    if (!t.length) return;
    if (self.onSend) self.onSend(t);
}
- (void)quickTap:(UIButton *)b {
    NSString *t = [b titleForState:UIControlStateNormal];
    ISLTick();
    if ([ISLConfig b:@"quickSend"]) { if (self.onSend) self.onSend(t); }
    else { [_buf appendString:t]; [self changed]; }
}
- (void)dealloc { [_rep invalidate]; }
@end

#pragma mark - Отправка ответа (IMCore + универсальный ответ через действие уведомления)

static void ISLEnsureIMCore(void) {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        dlopen("/System/Library/PrivateFrameworks/IMCore.framework/IMCore", RTLD_LAZY);
        Class dcc = NSClassFromString(@"IMDaemonController");
        id dc = ISLCall0(dcc, @"sharedController") ?: ISLCall0(dcc, @"sharedInstance");
        SEL add = NSSelectorFromString(@"addListenerID:capabilities:");
        if ([dc respondsToSelector:add]) ((void (*)(id, SEL, id, unsigned int))objc_msgSend)(dc, add, @"com.pups.islandmessenger", 0xFFFFFFFFu);
        SEL con = NSSelectorFromString(@"connectToDaemon");
        if ([dc respondsToSelector:con]) ((void (*)(id, SEL))objc_msgSend)(dc, con);
        ISLCall0(NSClassFromString(@"IMChatRegistry"), @"sharedInstance");
    });
}
static id ISLFindChat(NSString *tid, NSString *title) {
    id reg = ISLCall0(NSClassFromString(@"IMChatRegistry"), @"sharedInstance");
    if (!reg) return nil;
    id chat = nil;
    if (tid.length) {
        chat = ISLCall1(reg, @"existingChatWithChatIdentifier:", tid);
        if (!chat) chat = ISLCall1(reg, @"existingChatWithGUID:", tid);
        if (!chat) for (NSString *p in @[@"iMessage;-;", @"iMessage;+;", @"SMS;-;"]) {
            chat = ISLCall1(reg, @"existingChatWithGUID:", [p stringByAppendingString:tid]);
            if (chat) break;
        }
    }
    if (chat) return chat;
    id all = ISLKV(reg, @"allExistingChats");
    if (![all isKindOfClass:[NSArray class]]) return nil;
    for (id c in all) {
        NSString *ci = ISLStr(ISLKV(c, @"chatIdentifier")), *dn = ISLStr(ISLKV(c, @"displayName")), *nm = ISLStr(ISLKV(c, @"name"));
        if (tid.length && [ci isEqualToString:tid]) return c;
        if (title.length && ([dn isEqualToString:title] || [nm isEqualToString:title])) return c;
        id rcp = ISLKV(c, @"recipient");
        NSString *rn = ISLStr(ISLKV(rcp, @"name")) ?: ISLStr(ISLKV(rcp, @"fullName"));
        if (title.length && [rn isEqualToString:title]) return c;
    }
    return nil;
}
static BOOL ISLSendViaIMCore(ISLNote *n, NSString *text) {
    @try {
        ISLEnsureIMCore();
        id chat = ISLFindChat(n.threadID, n.title);
        if (!chat) return NO;
        Class M = NSClassFromString(@"IMMessage");
        NSAttributedString *as = [[NSAttributedString alloc] initWithString:text];
        id msg = nil;
        SEL s1 = NSSelectorFromString(@"instantMessageWithText:flags:");
        SEL s2 = NSSelectorFromString(@"instantMessageWithText:messageSubject:flags:");
        if ([M respondsToSelector:s1]) msg = ((id (*)(id, SEL, id, unsigned long long))objc_msgSend)(M, s1, as, 0x100005ULL);
        else if ([M respondsToSelector:s2]) msg = ((id (*)(id, SEL, id, id, unsigned long long))objc_msgSend)(M, s2, as, nil, 0x100005ULL);
        SEL send = NSSelectorFromString(@"sendMessage:");
        if (!msg || ![chat respondsToSelector:send]) return NO;
        ((void (*)(id, SEL, id))objc_msgSend)(chat, send, msg);
        return YES;
    } @catch (__unused id e) { return NO; }
}
static NSDictionary *ISLTextParams(NSString *t) {
    return @{ @"UIUserNotificationActionResponseTypedTextKey": t, @"UNNotificationResponseUserTextKey": t,
              @"userText": t, @"UserText": t, @"textInput": t };
}
static BOOL ISLActionIsText(id a) {
    if (!a) return NO;
    Class tc = NSClassFromString(@"NCNotificationTextInputAction");
    if (tc && [a isKindOfClass:tc]) return YES;
    if ([a respondsToSelector:NSSelectorFromString(@"textInputButtonTitle")]) return YES;
    id bp = ISLKV(a, @"behaviorParameters");
    if ([bp isKindOfClass:[NSDictionary class]])
        for (id k in bp) if ([[k description] rangeOfString:@"TextInput" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    id beh = ISLKV(a, @"behavior");
    if ([beh respondsToSelector:@selector(integerValue)] && [beh integerValue] == 1) return YES;
    return NO;
}
// Путь A: BulletinBoard — BBAction (текстовый ввод) → BBResponse
static BOOL ISLReplyViaBulletin(id bulletin, NSString *text) {
    if (!bulletin) return NO;
    NSMutableArray *acts = [NSMutableArray array];
    SEL sl = NSSelectorFromString(@"supplementaryActionsForLayout:");
    if ([bulletin respondsToSelector:sl])
        for (long long lay = 0; lay < 3; lay++)
            [acts addObjectsFromArray:ISLFlatten(((id (*)(id, SEL, long long))objc_msgSend)(bulletin, sl, lay))];
    [acts addObjectsFromArray:ISLFlatten(ISLKV(bulletin, @"supplementaryActions"))];
    for (id a in acts) {
        if (!ISLActionIsText(a)) continue;
        id resp = ISLCall1(bulletin, @"responseForAction:", a);
        if (!resp) continue;
        @try { [resp setValue:ISLTextParams(text) forKey:@"context"]; } @catch (__unused id e) {}
        id blk = ISLKV(bulletin, @"responseSendBlock");
        if (blk) { ((void (^)(id))blk)(resp); return YES; }
        SEL sr = NSSelectorFromString(@"sendResponse:");
        id obs = ISLKV(bulletin, @"observer");
        if (obs && [obs respondsToSelector:sr]) { ((void (*)(id, SEL, id))objc_msgSend)(obs, sr, resp); return YES; }
        if ([bulletin respondsToSelector:sr]) { ((void (*)(id, SEL, id))objc_msgSend)(bulletin, sr, resp); return YES; }
    }
    return NO;
}
// Путь B: NCNotificationAction.actionRunner
static BOOL ISLReplyViaRunner(id req, NSString *text) {
    if (!req) return NO;
    NSMutableArray *acts = [NSMutableArray array];
    for (NSString *k in @[@"supplementaryActions", @"allSupplementaryActions", @"supplementaryActionsByLayout"])
        [acts addObjectsFromArray:ISLFlatten(ISLKV(req, k))];
    SEL ex = NSSelectorFromString(@"executeAction:fromOrigin:endpoint:withParameters:completion:");
    for (id a in acts) {
        if (!ISLActionIsText(a)) continue;
        id runner = ISLKV(a, @"actionRunner");
        if (runner && [runner respondsToSelector:ex]) {
            ((void (*)(id, SEL, id, id, id, id, id))objc_msgSend)(runner, ex, a, nil, nil, ISLTextParams(text), nil);
            return YES;
        }
    }
    return NO;
}
static void ISLSendReply(ISLNote *n, NSString *text, void (^cb)(BOOL ok)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (n.isTest) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ cb(YES); });
            return;
        }
        BOOL ok = NO;
        if ([n.bundleID isEqualToString:@"com.apple.MobileSMS"]) ok = ISLSendViaIMCore(n, text);
        if (!ok) { @try { ok = ISLReplyViaRunner(n.request, text); } @catch (__unused id e) {} }
        if (!ok) { @try { ok = ISLReplyViaBulletin(n.bulletin ?: ISLKV(n.request, @"bulletin"), text); } @catch (__unused id e) {} }
        cb(ok);
    });
}

#pragma mark - Панель настроек (живые ползунки)

static const void *kISLLbl = &kISLLbl;

@interface ISLPanel : UIView
@property (nonatomic, copy) void (^onClose)(void);
@property (nonatomic, copy) void (^onTest)(void);
- (void)reloadAll;
- (void)startLive;
- (void)stopLive;
@end

@implementation ISLPanel {
    UILabel *_title; UIButton *_close; UISegmentedControl *_tabs;
    UIScrollView *_scroll; UIStackView *_stack;
    UISlider *_vol; UILabel *_volL; NSTimer *_live;
}
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (!self) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.95];
    self.layer.cornerRadius = 24; self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 0.5; self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
    self.clipsToBounds = YES;
    _title = [UILabel new]; _title.text = @"Island Messenger"; _title.textColor = [UIColor whiteColor];
    _title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold]; [self addSubview:_title];
    _close = [UIButton buttonWithType:UIButtonTypeSystem]; [_close setTitle:@"✕" forState:UIControlStateNormal];
    _close.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold]; [_close setTintColor:[UIColor whiteColor]];
    [_close addTarget:self action:@selector(closeTap) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:_close];
    _tabs = [[UISegmentedControl alloc] initWithItems:@[@"Вид", @"Цвет", @"Медиа", @"Чат", @"Клав."]];
    _tabs.selectedSegmentIndex = 0;
    [_tabs addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged]; [self addSubview:_tabs];
    _scroll = [UIScrollView new]; _scroll.alwaysBounceVertical = YES; [self addSubview:_scroll];
    _stack = [UIStackView new]; _stack.axis = UILayoutConstraintAxisVertical; _stack.spacing = 8;
    _stack.translatesAutoresizingMaskIntoConstraints = NO; [_scroll addSubview:_stack];
    [NSLayoutConstraint activateConstraints:@[
        [_stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:6],
        [_stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [_stack.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor constant:16],
        [_stack.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [_stack.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor constant:-32]]];
    [self buildTab:0];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    _title.frame = CGRectMake(16, 12, W - 80, 24);
    _close.frame = CGRectMake(W - 52, 8, 44, 32);
    _tabs.frame = CGRectMake(12, 44, W - 24, 30);
    _scroll.frame = CGRectMake(0, 84, W, MAX(0, H - 84));
}
- (void)closeTap { [self stopLive]; if (self.onClose) self.onClose(); }
- (void)tabChanged { [self buildTab:_tabs.selectedSegmentIndex]; }
- (void)reloadAll { [self buildTab:_tabs.selectedSegmentIndex]; }
- (void)startLive {
    [_live invalidate];
    _live = [NSTimer scheduledTimerWithTimeInterval:0.15 target:self selector:@selector(liveTick) userInfo:nil repeats:YES];
}
- (void)stopLive { [_live invalidate]; _live = nil; }
- (void)liveTick {
    [[ISLMedia shared] pollVolume];
    if (_vol && !_vol.isTracking) {
        float v = [ISLMedia shared].volume;
        _vol.value = v; _volL.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(v * 100)];
    }
}
- (void)dealloc { [_live invalidate]; }

// ── конструкторы строк ──
- (UILabel *)lab:(NSString *)t {
    UILabel *l = [UILabel new]; l.text = t; l.textColor = [UIColor colorWithWhite:1 alpha:0.92];
    l.font = [UIFont systemFontOfSize:13]; l.translatesAutoresizingMaskIntoConstraints = NO; return l;
}
- (UIView *)row {
    UIView *r = [UIView new]; [r.heightAnchor constraintEqualToConstant:34].active = YES; return r;
}
- (void)add:(UIView *)v { [_stack addArrangedSubview:v]; }
- (UIView *)sliderRow:(NSString *)t key:(NSString *)k min:(float)mn max:(float)mx fmt:(NSString *)fmt value:(float)val action:(SEL)act out:(UISlider **)out {
    UIView *row = [self row];
    UILabel *l = [self lab:t], *v = [self lab:@""];
    v.textAlignment = NSTextAlignmentRight;
    v.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    v.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    UISlider *s = [UISlider new]; s.translatesAutoresizingMaskIntoConstraints = NO;
    s.minimumValue = mn; s.maximumValue = mx; s.value = val;
    s.accessibilityIdentifier = k; s.accessibilityHint = fmt;
    v.text = [NSString stringWithFormat:fmt, (double)val];
    objc_setAssociatedObject(s, kISLLbl, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [s addTarget:self action:act forControlEvents:UIControlEventValueChanged];
    [row addSubview:l]; [row addSubview:v]; [row addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [l.leadingAnchor constraintEqualToAnchor:row.leadingAnchor], [l.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [l.widthAnchor constraintEqualToConstant:118],
        [v.trailingAnchor constraintEqualToAnchor:row.trailingAnchor], [v.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [v.widthAnchor constraintEqualToConstant:52],
        [s.leadingAnchor constraintEqualToAnchor:l.trailingAnchor constant:4],
        [s.trailingAnchor constraintEqualToAnchor:v.leadingAnchor constant:-4],
        [s.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]]];
    if (out) *out = s;
    return row;
}
- (UIView *)cfgSlider:(NSString *)t key:(NSString *)k min:(float)mn max:(float)mx fmt:(NSString *)fmt {
    return [self sliderRow:t key:k min:mn max:mx fmt:fmt value:[ISLConfig f:k] action:@selector(slid:) out:NULL];
}
- (UIView *)switchRow:(NSString *)t key:(NSString *)k on:(BOOL)on action:(SEL)act {
    UIView *row = [self row]; UILabel *l = [self lab:t];
    UISwitch *sw = [UISwitch new]; sw.translatesAutoresizingMaskIntoConstraints = NO; sw.on = on;
    sw.accessibilityIdentifier = k; [sw addTarget:self action:act forControlEvents:UIControlEventValueChanged];
    [row addSubview:l]; [row addSubview:sw];
    [NSLayoutConstraint activateConstraints:@[
        [l.leadingAnchor constraintEqualToAnchor:row.leadingAnchor], [l.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [sw.trailingAnchor constraintEqualToAnchor:row.trailingAnchor], [sw.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]]];
    return row;
}
- (UIView *)cfgSwitch:(NSString *)t key:(NSString *)k { return [self switchRow:t key:k on:[ISLConfig b:k] action:@selector(sw:)]; }
- (UIView *)segRow:(NSString *)t key:(NSString *)k items:(NSArray *)items {
    UIView *row = [self row]; UILabel *l = [self lab:t];
    UISegmentedControl *sc = [[UISegmentedControl alloc] initWithItems:items];
    sc.translatesAutoresizingMaskIntoConstraints = NO; sc.selectedSegmentIndex = [ISLConfig i:k]; sc.accessibilityIdentifier = k;
    [sc addTarget:self action:@selector(seg:) forControlEvents:UIControlEventValueChanged];
    [row addSubview:l]; [row addSubview:sc];
    [NSLayoutConstraint activateConstraints:@[
        [l.leadingAnchor constraintEqualToAnchor:row.leadingAnchor], [l.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [l.widthAnchor constraintEqualToConstant:70],
        [sc.leadingAnchor constraintEqualToAnchor:l.trailingAnchor constant:4], [sc.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [sc.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]]];
    return row;
}
- (UIView *)buttonsRow {
    UIStackView *st = [UIStackView new]; st.axis = UILayoutConstraintAxisHorizontal; st.distribution = UIStackViewDistributionFillEqually; st.spacing = 10;
    [st.heightAnchor constraintEqualToConstant:38].active = YES;
    NSArray *defs = @[@[@"Тест уведомления", @"test"], @[@"Сбросить всё", @"reset"]];
    for (NSArray *d in defs) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.backgroundColor = [d[1] isEqual:@"test"] ? [UIColor colorWithRed:0.04 green:0.52 blue:1 alpha:1] : [UIColor colorWithWhite:1 alpha:0.14];
        b.layer.cornerRadius = 12; b.layer.cornerCurve = kCACornerCurveContinuous;
        b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        [b setTitle:d[0] forState:UIControlStateNormal]; [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.accessibilityIdentifier = d[1]; [b addTarget:self action:@selector(btn:) forControlEvents:UIControlEventTouchUpInside];
        [st addArrangedSubview:b];
    }
    return st;
}
// ── обработчики ──
- (void)slid:(UISlider *)s {
    UILabel *v = objc_getAssociatedObject(s, kISLLbl);
    v.text = [NSString stringWithFormat:s.accessibilityHint, (double)s.value];
    [ISLConfig set:@(s.value) for:s.accessibilityIdentifier];
}
- (void)volSlid:(UISlider *)s {
    UILabel *v = objc_getAssociatedObject(s, kISLLbl);
    v.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(s.value * 100)];
    [[ISLMedia shared] setVolumeValue:s.value];
}
- (void)sw:(UISwitch *)s { [ISLConfig set:@(s.isOn) for:s.accessibilityIdentifier]; }
- (void)seg:(UISegmentedControl *)s { [ISLConfig set:@(s.selectedSegmentIndex) for:s.accessibilityIdentifier]; }
- (void)listSw:(UISwitch *)s {
    NSMutableArray *ids = [([[ISLConfig d] arrayForKey:@"listIDs"] ?: @[]) mutableCopy];
    NSString *bid = s.accessibilityIdentifier;
    if (s.isOn) { if (![ids containsObject:bid]) [ids addObject:bid]; } else [ids removeObject:bid];
    [ISLConfig set:ids for:@"listIDs"];
}
- (void)btn:(UIButton *)b {
    if ([b.accessibilityIdentifier isEqual:@"test"]) { if (self.onTest) self.onTest(); return; }
    [[ISLConfig d] removePersistentDomainForName:ISL_DOMAIN];
    [[NSNotificationCenter defaultCenter] postNotificationName:ISL_CHANGED object:nil];
    [self buildTab:_tabs.selectedSegmentIndex];
}
// ── вкладки ──
- (void)buildTab:(NSInteger)i {
    for (UIView *v in [_stack.arrangedSubviews copy]) { [_stack removeArrangedSubview:v]; [v removeFromSuperview]; }
    _vol = nil; _volL = nil;
    switch (i) {
        case 0:
            [self add:[self segRow:@"Форма" key:@"shape" items:@[@"Остров", @"Капсула", @"Челка"]]];
            [self add:[self cfgSlider:@"Ширина" key:@"width" min:60 max:300 fmt:@"%.0f"]];
            [self add:[self cfgSlider:@"Высота" key:@"height" min:20 max:70 fmt:@"%.0f"]];
            [self add:[self cfgSlider:@"Offset X" key:@"offX" min:-150 max:150 fmt:@"%.0f"]];
            [self add:[self cfgSlider:@"Offset Y" key:@"offY" min:-30 max:80 fmt:@"%.0f"]];
            [self add:[self cfgSwitch:@"Pin к safe area" key:@"pin"]];
            [self add:[self cfgSlider:@"Радиус, свёрнуто" key:@"radius" min:0 max:50 fmt:@"%.1f"]];
            [self add:[self cfgSlider:@"Радиус, развёрн." key:@"radiusExp" min:0 max:50 fmt:@"%.1f"]];
            [self add:[self cfgSlider:@"Camera-hole opacity" key:@"holeOp" min:0 max:1 fmt:@"%.2f"]];
            [self add:[self cfgSlider:@"Alpha фона" key:@"alpha" min:0.1 max:1 fmt:@"%.2f"]];
            break;
        case 1:
            [self add:[self cfgSwitch:@"Градиент" key:@"gradient"]];
            [self add:[self cfgSlider:@"Фон 1 · hue" key:@"bgH" min:0 max:1 fmt:@"%.2f"]];
            [self add:[self cfgSlider:@"Фон 1 · sat" key:@"bgS" min:0 max:1 fmt:@"%.2f"]];
            [self add:[self cfgSlider:@"Фон 1 · bright" key:@"bgB" min:0 max:1 fmt:@"%.2f"]];
            [self add:[self cfgSlider:@"Фон 2 · hue" key:@"bg2H" min:0 max:1 fmt:@"%.2f"]];
            [self add:[self cfgSlider:@"Фон 2 · sat" key:@"bg2S" min:0 max:1 fmt:@"%.2f"]];
            [self add:[self cfgSlider:@"Фон 2 · bright" key:@"bg2B" min:0 max:1 fmt:@"%.2f"]];
            [self add:[self cfgSlider:@"Угол градиента" key:@"gradAngle" min:0 max:360 fmt:@"%.0f°"]];
            [self add:[self cfgSlider:@"Обводка, pt" key:@"strokeW" min:0 max:4 fmt:@"%.1f"]];
            [self add:[self cfgSlider:@"Обводка · hue" key:@"strokeH" min:0 max:1 fmt:@"%.2f"]];
            [self add:[self cfgSlider:@"Обводка · sat" key:@"strokeS" min:0 max:1 fmt:@"%.2f"]];
            [self add:[self cfgSlider:@"Tint · hue" key:@"tintH" min:0 max:1 fmt:@"%.2f"]];
            [self add:[self cfgSlider:@"Tint · sat" key:@"tintS" min:0 max:1 fmt:@"%.2f"]];
            break;
        case 2: {
            UISlider *s = nil;
            UIView *r = [self sliderRow:@"Громкость (live)" key:@"volume" min:0 max:1 fmt:@"%.2f" value:[ISLMedia shared].volume action:@selector(volSlid:) out:&s];
            _vol = s; _volL = objc_getAssociatedObject(s, kISLLbl);
            _volL.text = [NSString stringWithFormat:@"%d%%", (int)lroundf([ISLMedia shared].volume * 100)];
            [self add:r];
            [self add:[self cfgSwitch:@"Эквалайзер" key:@"eqOn"]];
            [self add:[self segRow:@"Источник" key:@"eqSource" items:@[@"Анимация", @"Микрофон (tap)"]]];
            break; }
        case 3: {
            [self add:[self cfgSwitch:@"Мессенджер в острове" key:@"msgOn"]];
            [self add:[self segRow:@"Режим" key:@"mode" items:@[@"Авто-разворот", @"Бейдж", @"Тихо"]]];
            [self add:[self cfgSlider:@"Таймаут, с" key:@"timeout" min:2 max:30 fmt:@"%.0f с"]];
            [self add:[self segRow:@"Фильтр" key:@"listMode" items:@[@"Whitelist", @"Blacklist"]]];
            NSArray *ids = [[ISLConfig d] arrayForKey:@"listIDs"];
            NSArray *apps = @[@[@"iMessage", @"com.apple.MobileSMS"], @[@"WhatsApp", @"net.whatsapp.WhatsApp"],
                              @[@"Telegram", @"ph.telegra.Telegraph"], @[@"Signal", @"org.whispersystems.signal"]];
            for (NSArray *a in apps) {
                UIView *r = [self switchRow:[NSString stringWithFormat:@"в списке: %@", a[0]] key:a[1] on:[ids containsObject:a[1]] action:@selector(listSw:)];
                [self add:r];
            }
            [self add:[self cfgSwitch:@"Скрывать системный баннер" key:@"hideBanner"]];
            [self add:[self cfgSwitch:@"Haptics" key:@"haptics"]];
            break; }
        case 4:
            [self add:[self cfgSlider:@"Высота клавиатуры" key:@"kbH" min:200 max:240 fmt:@"%.0f"]];
            [self add:[self cfgSwitch:@"Эмодзи" key:@"kbEmoji"]];
            [self add:[self cfgSwitch:@"Quick-reply сразу отправляет" key:@"quickSend"]];
            [self add:[self segRow:@"Раскладка" key:@"lang" items:@[@"RU", @"EN"]]];
            break;
    }
    [self add:[self buttonsRow]];
}
@end

#pragma mark - Окно-оверлей

@interface ISLWindow : UIWindow @end
@implementation ISLWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    UIView *root = self.rootViewController.view;
    return (v == self || v == root) ? nil : v;   // пустые места пропускают касания в систему
}
@end

@interface ISLRootVC : UIViewController @end
@implementation ISLRootVC
- (void)loadView { UIView *v = [UIView new]; v.backgroundColor = [UIColor clearColor]; self.view = v; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (BOOL)shouldAutorotate { return NO; }
@end

#pragma mark - Контроллер острова

typedef NS_ENUM(NSInteger, ISLState) { ISLStIdle = 0, ISLStChat, ISLStCompose, ISLStSent, ISLStMedia };

@interface ISLController : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)boot;
- (void)ingest:(ISLNote *)n force:(BOOL)force;
- (void)showTest;
@end

@implementation ISLController {
    ISLWindow *_win; UIView *_root;
    UIView *_hole, *_shadow;
    ISLGradientView *_island;
    ISLEarView *_earL, *_earR;
    ISLEqView *_eqMini; UILabel *_badge;
    UIImageView *_hdrIcon; UILabel *_hdrCount;
    UIView *_chat; UIImageView *_avatar; UILabel *_initials; UIImageView *_appBadge; UILabel *_name, *_text;
    UIButton *_replyBtn, *_hideBtn;
    UIView *_compose, *_fieldBox; UILabel *_field; UIButton *_cancelBtn; ISLKeyboard *_kb;
    UILabel *_sent;
    UIView *_media; UILabel *_mTitle, *_mArtist, *_mVolLbl, *_mVolIcon; UISlider *_mVol;
    UIButton *_mPlay, *_mPrev, *_mNext; ISLEqView *_mEq;
    ISLPanel *_panel; BOOL _panelOpen;
    NSMutableArray<ISLNote *> *_queue; NSInteger _idx; ISLState _state;
    NSTimer *_timer, *_volTimer; BOOL _built, _sending;
}
+ (instancetype)shared {
    static ISLController *c; static dispatch_once_t t;
    dispatch_once(&t, ^{ c = [ISLController new]; });
    return c;
}

// ── геометрия ──
- (CGFloat)W { return [UIScreen mainScreen].bounds.size.width; }
- (CGFloat)kbH { return MAX(200, MIN(240, [ISLConfig f:@"kbH"])); }
- (CGFloat)expW { return MIN([self W] - 16, 372); }
// 0 остров · 1 плавающая капсула · 2 челка. Без Dynamic Island «остров» автоматически становится капсулой.
- (NSInteger)shape {
    NSInteger s = [ISLConfig i:@"shape"];
    if (s == 0 && !ISLHasIsland()) s = 1;
    return s;
}
- (CGRect)collapsedFrame {
    CGFloat sw = [self W], w = [ISLConfig f:@"width"], h = [ISLConfig f:@"height"];
    CGFloat ox = [ISLConfig f:@"offX"], oy = [ISLConfig f:@"offY"];
    CGFloat st = ISLSafeTop(_root), y; BOOL pin = [ISLConfig b:@"pin"];
    switch ([self shape]) {
        case 2:  y = oy; h += ISLHasIsland() ? 11 : 0; break;               // челка: от самой кромки экрана
        case 1:  y = (pin ? st : 0) + 8 + oy; break;                        // плавающая капсула под статус-баром
        default: y = pin ? (st - 11 - h) + oy : 11 + oy; break;             // остров: pin держит нижний край у safe area
    }
    return CGRectMake((sw - w) / 2 + ox, y, w, h);
}
- (CGFloat)expHeight:(ISLState)s {
    CGRect c = [self collapsedFrame]; CGFloat hz = c.size.height + 4;
    switch (s) {
        case ISLStChat:    return hz + 116;
        case ISLStCompose: return hz + 72 + 38 + 6 + [self kbH] + 8;
        case ISLStSent:    return hz + 56;
        case ISLStMedia:   return hz + 172;
        default:           return c.size.height;
    }
}
- (CGRect)frameForState:(ISLState)s {
    CGRect c = [self collapsedFrame];
    if (s == ISLStIdle) return c;
    CGFloat w = [self expW];
    CGFloat x = CGRectGetMidX(c) - w / 2;
    x = MAX(8, MIN([self W] - 8 - w, x));
    return CGRectMake(x, c.origin.y, w, [self expHeight:s]);
}

// ── создание ──
- (UILabel *)lbl:(UIFont *)f lines:(NSInteger)n {
    UILabel *l = [UILabel new]; l.font = f; l.numberOfLines = n; l.textColor = [UIColor whiteColor];
    l.lineBreakMode = NSLineBreakByTruncatingTail; return l;
}
- (UIButton *)pill:(NSString *)t color:(UIColor *)c action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.backgroundColor = c; b.layer.cornerRadius = 17; b.layer.cornerCurve = kCACornerCurveContinuous;
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [b setTitle:t forState:UIControlStateNormal]; [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (UIButton *)iconBtn:(NSString *)t action:(SEL)a size:(CGFloat)sz {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.titleLabel.font = [UIFont systemFontOfSize:sz]; [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside]; return b;
}
- (void)boot {
    if (_built) return; _built = YES;
    [ISLConfig d];
    _queue = [NSMutableArray new]; _state = ISLStIdle;
    CGRect sb = [UIScreen mainScreen].bounds;
    _win = [[ISLWindow alloc] initWithFrame:sb];
    _win.windowLevel = UIWindowLevelAlert + 2000;
    _win.backgroundColor = [UIColor clearColor];
    ISLRootVC *vc = [ISLRootVC new];
    _win.rootViewController = vc; _root = vc.view;
    _win.hidden = NO;
    [_root layoutIfNeeded];
    [self buildViews];
    [self applyConfig:NO];
    [self setState:ISLStIdle];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(cfgChanged) name:ISL_CHANGED object:nil];
    [nc addObserver:self selector:@selector(mediaChanged) name:ISL_MEDIA object:nil];
    [nc addObserver:self selector:@selector(rotated) name:UIDeviceOrientationDidChangeNotification object:nil];
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[ISLMedia shared] start];
    NSLog(@"[IslandMessenger] boot ok, island=%d", (int)ISLHasIsland());
}
- (void)buildViews {
    __weak ISLController *ws = self;
    _hole = [UIView new]; _hole.backgroundColor = [UIColor blackColor]; _hole.userInteractionEnabled = NO;
    _hole.layer.cornerCurve = kCACornerCurveContinuous; [_root addSubview:_hole];
    _shadow = [UIView new]; _shadow.backgroundColor = [UIColor colorWithWhite:0 alpha:0.01]; _shadow.userInteractionEnabled = NO;
    _shadow.layer.shadowColor = [UIColor blackColor].CGColor; _shadow.layer.shadowOpacity = 0.4;
    _shadow.layer.shadowRadius = 12; _shadow.layer.shadowOffset = CGSizeMake(0, 5); [_root addSubview:_shadow];
    _earL = [ISLEarView new]; _earR = [ISLEarView new]; _earR.right = YES; [_root addSubview:_earL]; [_root addSubview:_earR];
    _island = [ISLGradientView new]; _island.clipsToBounds = YES; _island.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _island.layer.cornerCurve = kCACornerCurveContinuous; [_root addSubview:_island];

    // свёрнутый вид: мини-эквалайзер и бейдж
    _eqMini = [ISLEqView new]; _eqMini.count = 4; _eqMini.allowMic = NO; _eqMini.alpha = 0; [_island addSubview:_eqMini];
    _badge = [self lbl:[UIFont systemFontOfSize:11 weight:UIFontWeightBold] lines:1];
    _badge.textAlignment = NSTextAlignmentCenter; _badge.backgroundColor = [UIColor systemRedColor];
    _badge.clipsToBounds = YES; _badge.alpha = 0; [_island addSubview:_badge];

    // шапка развёрнутого вида
    _hdrIcon = [UIImageView new]; _hdrIcon.contentMode = UIViewContentModeScaleAspectFit;
    _hdrIcon.layer.cornerRadius = 4; _hdrIcon.clipsToBounds = YES; _hdrIcon.alpha = 0; [_island addSubview:_hdrIcon];
    _hdrCount = [self lbl:[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium] lines:1];
    _hdrCount.textAlignment = NSTextAlignmentRight; _hdrCount.alpha = 0; [_island addSubview:_hdrCount];

    // чат-карточка
    _chat = [UIView new]; _chat.alpha = 0; [_island addSubview:_chat];
    _avatar = [UIImageView new]; _avatar.contentMode = UIViewContentModeScaleAspectFill;
    _avatar.clipsToBounds = YES; _avatar.layer.cornerRadius = 22; [_chat addSubview:_avatar];
    _initials = [self lbl:[UIFont systemFontOfSize:18 weight:UIFontWeightSemibold] lines:1];
    _initials.textAlignment = NSTextAlignmentCenter; [_avatar addSubview:_initials];
    _appBadge = [UIImageView new]; _appBadge.layer.cornerRadius = 5; _appBadge.clipsToBounds = YES;
    _appBadge.layer.borderWidth = 1.5; _appBadge.layer.borderColor = [UIColor blackColor].CGColor; [_chat addSubview:_appBadge];
    _name = [self lbl:[UIFont systemFontOfSize:15 weight:UIFontWeightBold] lines:1]; [_chat addSubview:_name];
    _text = [self lbl:[UIFont systemFontOfSize:14] lines:2]; [_chat addSubview:_text];
    _replyBtn = [self pill:@"Ответить" color:[UIColor colorWithRed:0.04 green:0.52 blue:1 alpha:1] action:@selector(tapReply)];
    _hideBtn = [self pill:@"Скрыть" color:[UIColor colorWithWhite:1 alpha:0.16] action:@selector(tapHide)];
    [_chat addSubview:_replyBtn]; [_chat addSubview:_hideBtn];

    // ввод ответа
    _compose = [UIView new]; _compose.alpha = 0; [_island addSubview:_compose];
    _fieldBox = [UIView new]; _fieldBox.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    _fieldBox.layer.cornerRadius = 12; _fieldBox.layer.cornerCurve = kCACornerCurveContinuous; [_compose addSubview:_fieldBox];
    _field = [self lbl:[UIFont systemFontOfSize:16] lines:1]; _field.lineBreakMode = NSLineBreakByTruncatingHead;
    _field.text = @"Ответ…"; _field.alpha = 0.45; [_fieldBox addSubview:_field];
    _cancelBtn = [self iconBtn:@"✕" action:@selector(tapCancel) size:16]; [_fieldBox addSubview:_cancelBtn];
    _kb = [[ISLKeyboard alloc] initWithFrame:CGRectZero]; [_compose addSubview:_kb];
    _kb.onChange = ^(NSString *t) {
        ISLController *s = ws; if (!s) return;
        BOOL e = (t.length == 0);
        s->_field.text = e ? ([ISLConfig i:@"lang"] == 1 ? @"Reply…" : @"Ответ…") : t;
        s->_field.alpha = e ? 0.45 : 1;
    };
    _kb.onSend = ^(NSString *t) { [ws doSend:t]; };

    // «Отправлено ✓»
    _sent = [self lbl:[UIFont systemFontOfSize:20 weight:UIFontWeightSemibold] lines:1];
    _sent.textAlignment = NSTextAlignmentCenter; _sent.alpha = 0; [_island addSubview:_sent];

    // плеер: громкость + эквалайзер
    _media = [UIView new]; _media.alpha = 0; [_island addSubview:_media];
    _mTitle = [self lbl:[UIFont systemFontOfSize:16 weight:UIFontWeightBold] lines:1]; [_media addSubview:_mTitle];
    _mArtist = [self lbl:[UIFont systemFontOfSize:13] lines:1]; [_media addSubview:_mArtist];
    _mPrev = [self iconBtn:@"⏮" action:@selector(tapPrev) size:22]; _mPlay = [self iconBtn:@"▶︎" action:@selector(tapPlay) size:26];
    _mNext = [self iconBtn:@"⏭" action:@selector(tapNext) size:22];
    [_media addSubview:_mPrev]; [_media addSubview:_mPlay]; [_media addSubview:_mNext];
    _mVolIcon = [self lbl:[UIFont systemFontOfSize:16] lines:1]; _mVolIcon.text = @"🔈"; [_media addSubview:_mVolIcon];
    _mVol = [UISlider new]; [_mVol addTarget:self action:@selector(volChanged:) forControlEvents:UIControlEventValueChanged];
    [_media addSubview:_mVol];
    _mVolLbl = [self lbl:[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium] lines:1];
    _mVolLbl.textAlignment = NSTextAlignmentRight; [_media addSubview:_mVolLbl];
    _mEq = [ISLEqView new]; _mEq.count = 16; _mEq.allowMic = YES; [_media addSubview:_mEq];

    // жесты
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapIsland:)];
    tap.delegate = self; tap.cancelsTouchesInView = NO; [_island addGestureRecognizer:tap];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longIsland:)];
    lp.minimumPressDuration = 0.6; lp.delegate = self; [_island addGestureRecognizer:lp];
    UITapGestureRecognizer *card = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapCard)];
    card.delegate = self; [_chat addGestureRecognizer:card];
    NSArray *dirs = @[@(UISwipeGestureRecognizerDirectionLeft), @(UISwipeGestureRecognizerDirectionRight), @(UISwipeGestureRecognizerDirectionUp)];
    for (NSNumber *d in dirs) {
        UISwipeGestureRecognizer *sw = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swiped:)];
        sw.direction = (UISwipeGestureRecognizerDirection)d.integerValue; sw.delegate = self; [_chat addGestureRecognizer:sw];
    }
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    return ![t.view isKindOfClass:[UIControl class]];
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if ([g isKindOfClass:[UILongPressGestureRecognizer class]]) return _state == ISLStIdle;
    return YES;
}

// ── применение настроек (live-preview) ──
- (void)cfgChanged { [self applyConfig:YES]; }
- (void)applyConfig:(BOOL)animated {
    void (^work)(void) = ^{
        CGRect f = [self frameForState:self->_state];
        BOOL idle = (self->_state == ISLStIdle);
        CGFloat rad = [ISLConfig f:idle ? @"radius" : @"radiusExp"];
        self->_island.frame = f; self->_shadow.frame = f;
        for (UIView *v in @[self->_island, self->_shadow]) {
            v.layer.cornerRadius = rad;
            v.layer.maskedCorners = ([self shape] == 2)
                ? (kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner)
                : (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner);
        }
        UIColor *c1 = [ISLConfig hsb:@"bg"], *c2 = [ISLConfig hsb:@"bg2"];
        CGFloat a = [ISLConfig f:@"alpha"]; BOOL grad = [ISLConfig b:@"gradient"];
        CAGradientLayer *g = (CAGradientLayer *)self->_island.layer;
        g.colors = @[(id)[c1 colorWithAlphaComponent:a].CGColor, (id)[(grad ? c2 : c1) colorWithAlphaComponent:a].CGColor];
        CGFloat ang = [ISLConfig f:@"gradAngle"] * M_PI / 180.0;
        g.startPoint = CGPointMake(0.5 - 0.5 * cos(ang), 0.5 - 0.5 * sin(ang));
        g.endPoint = CGPointMake(0.5 + 0.5 * cos(ang), 0.5 + 0.5 * sin(ang));
        self->_island.layer.borderWidth = [ISLConfig f:@"strokeW"];
        self->_island.layer.borderColor = [ISLConfig hsb:@"stroke"].CGColor;
        self->_shadow.alpha = ([self shape] == 1 && a > 0.9) ? 1 : 0;
        // «camera-hole»: чёрная подложка ровно над аппаратным вырезом острова
        self->_hole.hidden = !ISLHasIsland();
        self->_hole.frame = CGRectMake(([self W] - 126) / 2, 11, 126, 37);
        self->_hole.layer.cornerRadius = 18.5;
        self->_hole.alpha = [ISLConfig f:@"holeOp"];
        // tint
        UIColor *tint = [ISLConfig hsb:@"tint"];
        for (UILabel *l in @[self->_name, self->_hdrCount, self->_field, self->_initials, self->_mTitle, self->_mVolLbl, self->_mVolIcon]) l.textColor = tint;
        self->_text.textColor = [tint colorWithAlphaComponent:0.75];
        self->_mArtist.textColor = [tint colorWithAlphaComponent:0.65];
        self->_eqMini.barColor = tint; self->_mEq.barColor = tint;
        for (UIButton *b in @[self->_mPrev, self->_mPlay, self->_mNext, self->_cancelBtn]) [b setTitleColor:tint forState:UIControlStateNormal];
        self->_mVol.minimumTrackTintColor = tint;
        [self placeEars:f expanded:!idle];
        [self layoutContent];
    };
    if (animated) [UIView animateWithDuration:0.12 delay:0 options:(UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction) animations:work completion:nil];
    else work();
    [self updateAccessories];
}
- (void)placeEars:(CGRect)f expanded:(BOOL)e {
    CGFloat s = 12;
    _earL.frame = CGRectMake(f.origin.x - s, f.origin.y, s, s);
    _earR.frame = CGRectMake(CGRectGetMaxX(f), f.origin.y, s, s);
    _earL.alpha = _earR.alpha = ([self shape] == 2 && !e) ? 1 : 0;
    UIColor *c = [[ISLConfig hsb:@"bg"] colorWithAlphaComponent:[ISLConfig f:@"alpha"]];
    _earL.fill = c; _earR.fill = c;
}
- (void)layoutContent {
    CGRect c = [self collapsedFrame];
    CGFloat Wx = [self expW], hz = c.size.height + 4, kbH = [self kbH];
    _eqMini.frame = CGRectMake(12, (c.size.height - 14) / 2, 24, 14);
    BOOL dot = ([ISLConfig i:@"mode"] == 2);
    if (dot) { _badge.frame = CGRectMake(c.size.width - 16, 6, 8, 8); _badge.layer.cornerRadius = 4; }
    else { _badge.frame = CGRectMake(c.size.width - 30, (c.size.height - 18) / 2, 18, 18); _badge.layer.cornerRadius = 9; }
    _hdrIcon.frame = CGRectMake(14, (c.size.height - 16) / 2, 16, 16);
    _hdrCount.frame = CGRectMake(Wx - 14 - 50, (c.size.height - 16) / 2, 50, 16);
    // чат
    _chat.frame = CGRectMake(0, hz, Wx, 116);
    _avatar.frame = CGRectMake(16, 10, 44, 44); _initials.frame = _avatar.bounds;
    _appBadge.frame = CGRectMake(46, 38, 18, 18);
    _name.frame = CGRectMake(70, 10, Wx - 86, 18); _text.frame = CGRectMake(70, 30, Wx - 86, 38);
    CGFloat bw = (Wx - 32 - 8) / 2;
    _replyBtn.frame = CGRectMake(16, 74, bw, 34); _hideBtn.frame = CGRectMake(16 + bw + 8, 74, bw, 34);
    // ввод
    _compose.frame = CGRectMake(0, hz + 72, Wx, 38 + 6 + kbH + 8);
    _fieldBox.frame = CGRectMake(12, 0, Wx - 24, 38);
    _field.frame = CGRectMake(12, 0, Wx - 24 - 12 - 40, 38);
    _cancelBtn.frame = CGRectMake(Wx - 24 - 40, 0, 40, 38);
    _kb.frame = CGRectMake(0, 44, Wx, kbH);
    // «Отправлено»
    _sent.frame = CGRectMake(0, hz, Wx, 56);
    // плеер
    _media.frame = CGRectMake(0, hz, Wx, 172);
    _mTitle.frame = CGRectMake(16, 6, Wx - 32, 20); _mArtist.frame = CGRectMake(16, 26, Wx - 32, 16);
    _mPrev.frame = CGRectMake(Wx / 2 - 84, 50, 44, 36); _mPlay.frame = CGRectMake(Wx / 2 - 22, 50, 44, 36); _mNext.frame = CGRectMake(Wx / 2 + 40, 50, 44, 36);
    _mVolIcon.frame = CGRectMake(16, 94, 24, 30);
    _mVol.frame = CGRectMake(44, 94, Wx - 44 - 16 - 44, 30); _mVolLbl.frame = CGRectMake(Wx - 16 - 40, 94, 40, 30);
    _mEq.frame = CGRectMake(16, 132, Wx - 32, 28);
}

// ── состояния ──
- (void)setState:(ISLState)s {
    _state = s;
    [self layoutContent];
    BOOL exp = (s != ISLStIdle);
    CGRect f = [self frameForState:s];
    CGFloat rad = [ISLConfig f:exp ? @"radiusExp" : @"radius"];
    [UIView animateWithDuration:(exp ? 0.52 : 0.42) delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.4
                        options:(UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction) animations:^{
        self->_island.frame = f; self->_shadow.frame = f;
        self->_island.layer.cornerRadius = rad; self->_shadow.layer.cornerRadius = rad;
        [self placeEars:f expanded:exp];
    } completion:nil];
    BOOL chatLike = (s == ISLStChat || s == ISLStCompose);
    [UIView animateWithDuration:0.22 delay:(exp ? 0.12 : 0) options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self->_chat.alpha = chatLike ? 1 : 0;
        CGFloat bt = (s == ISLStChat) ? 1 : 0;
        self->_replyBtn.alpha = bt; self->_hideBtn.alpha = bt;
        self->_compose.alpha = (s == ISLStCompose) ? 1 : 0;
        self->_sent.alpha = (s == ISLStSent) ? 1 : 0;
        self->_media.alpha = (s == ISLStMedia) ? 1 : 0;
        CGFloat h = (chatLike || s == ISLStSent) ? 1 : 0;
        self->_hdrIcon.alpha = h; self->_hdrCount.alpha = h;
    } completion:nil];
    [self updateAccessories];
    [self updateMediaRunning];
    [self resetTimer];
}
- (void)updateAccessories {
    BOOL idle = (_state == ISLStIdle);
    BOOL eq = idle && [ISLConfig b:@"eqOn"] && [ISLMedia shared].playing;
    [UIView animateWithDuration:0.2 animations:^{ self->_eqMini.alpha = eq ? 1 : 0; }];
    if (eq) [_eqMini startRunning]; else [_eqMini stopRunning];
    BOOL has = idle && _queue.count > 0 && [ISLConfig b:@"msgOn"];
    if ([ISLConfig i:@"mode"] == 2) _badge.text = @"";
    else _badge.text = _queue.count > 9 ? @"9+" : [NSString stringWithFormat:@"%d", (int)_queue.count];
    [UIView animateWithDuration:0.2 animations:^{ self->_badge.alpha = has ? 1 : 0; }];
}
- (void)bounce {
    [UIView animateWithDuration:0.12 animations:^{ self->_island.transform = CGAffineTransformMakeScale(1.08, 1.08); } completion:^(BOOL f) {
        [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.8 options:0 animations:^{ self->_island.transform = CGAffineTransformIdentity; } completion:nil];
    }];
}
- (void)resetTimer {
    [_timer invalidate]; _timer = nil;
    if (_panelOpen) return;
    NSTimeInterval t = 0;
    if (_state == ISLStChat) t = MAX(2, MIN(30, [ISLConfig f:@"timeout"]));
    else if (_state == ISLStMedia) t = 12;
    if (t <= 0) return;
    _timer = [NSTimer scheduledTimerWithTimeInterval:t target:self selector:@selector(timeout) userInfo:nil repeats:NO];
}
- (void)timeout { if (_state == ISLStChat || _state == ISLStMedia) [self setState:ISLStIdle]; }
- (void)rotated {
    BOOL land = UIDeviceOrientationIsLandscape([UIDevice currentDevice].orientation);
    _win.userInteractionEnabled = !land;
    [UIView animateWithDuration:0.2 animations:^{ self->_win.alpha = land ? 0 : 1; }];
}

// ── очередь уведомлений ──
- (void)ingest:(ISLNote *)n force:(BOOL)force {
    for (ISLNote *q in _queue) if ([q.noteID isEqualToString:n.noteID]) return;
    if (n.threadID.length) {
        for (NSInteger i = 0; i < (NSInteger)_queue.count; i++) {
            ISLNote *q = _queue[i];
            BOOL composingThis = (_state == ISLStCompose && i == _idx);
            if (!composingThis && [q.bundleID isEqualToString:n.bundleID] && [q.threadID isEqualToString:n.threadID]) {
                [_queue removeObjectAtIndex:i];
                if (_idx > i) _idx--;
                break;
            }
        }
    }
    [_queue addObject:n];
    if (_queue.count > 20) { [_queue removeObjectAtIndex:0]; if (_idx > 0) _idx--; }
    if ([n.bundleID isEqualToString:@"com.apple.MobileSMS"]) ISLEnsureIMCore();
    NSInteger mode = force ? 0 : [ISLConfig i:@"mode"];
    if (_state == ISLStCompose || _state == ISLStSent) { [self updateAccessories]; [self showIdx]; return; }
    if (mode == 0) {                                   // авто-разворот
        _idx = _queue.count - 1; [self showIdx];
        ISLBuzz(UINotificationFeedbackTypeSuccess);
        [self setState:ISLStChat];
    } else if (mode == 1) {                            // бейдж
        ISLTick();
        if (_state == ISLStChat) { _idx = _queue.count - 1; [self showIdx]; }
        [self updateAccessories]; [self bounce];
    } else {                                           // тихо: только точка, без haptics и анимаций
        if (_state == ISLStChat) { _idx = _queue.count - 1; [self showIdx]; }
        [self updateAccessories];
    }
}
- (void)showTest {
    ISLNote *n = [ISLNote new];
    n.bundleID = @"com.apple.MobileSMS"; n.title = @"Тест Тестов";
    n.text = @"Привет! Это предпросмотр острова. Ответишь? 🙂";
    n.noteID = [[NSUUID UUID] UUIDString]; n.isTest = YES;
    [self ingest:n force:YES];
}
- (void)showIdx {
    if (_queue.count == 0) return;
    _idx = MAX(0, MIN(_idx, (NSInteger)_queue.count - 1));
    ISLNote *n = _queue[_idx];
    _name.text = n.title ?: @"";
    _text.text = n.text ?: @"";
    if (n.avatar) { _avatar.image = n.avatar; _initials.hidden = YES; _avatar.backgroundColor = [UIColor clearColor]; }
    else {
        _avatar.image = nil; _initials.hidden = NO;
        NSMutableString *ini = [NSMutableString string];
        for (NSString *w in [(n.title ?: @"?") componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
            if (w.length && ini.length < 2) [ini appendString:[[w substringToIndex:1] uppercaseString]];
        }
        _initials.text = ini.length ? ini : @"?";
        CGFloat hue = (CGFloat)(((NSUInteger)(n.title ?: @"").hash) % 360) / 360.0;
        _avatar.backgroundColor = [UIColor colorWithHue:hue saturation:0.55 brightness:0.75 alpha:1];
    }
    UIImage *ic = ISLAppIcon(n.bundleID);
    _appBadge.image = ic; _hdrIcon.image = ic; _appBadge.hidden = (ic == nil);
    _hdrCount.text = _queue.count > 1 ? [NSString stringWithFormat:@"%d/%d", (int)_idx + 1, (int)_queue.count] : @"";
}
- (void)hideCurrent {
    if (_queue.count == 0) { [self setState:ISLStIdle]; return; }
    [_queue removeObjectAtIndex:MIN(_idx, (NSInteger)_queue.count - 1)];
    if (_queue.count == 0) { [self setState:ISLStIdle]; }
    else { _idx = MIN(_idx, (NSInteger)_queue.count - 1); [self showIdx]; [self resetTimer]; }
    [self updateAccessories];
}
- (void)swiped:(UISwipeGestureRecognizer *)g {
    if (_state != ISLStChat || _queue.count == 0) return;
    if (g.direction == UISwipeGestureRecognizerDirectionUp) { ISLTick(); [self hideCurrent]; return; }
    BOOL next = (g.direction == UISwipeGestureRecognizerDirectionLeft);
    NSInteger ni = _idx + (next ? 1 : -1);
    if (ni < 0 || ni >= (NSInteger)_queue.count) return;
    _idx = ni;
    CATransition *t = [CATransition animation]; t.type = kCATransitionPush;
    t.subtype = next ? kCATransitionFromRight : kCATransitionFromLeft; t.duration = 0.22;
    [_chat.layer addAnimation:t forKey:@"push"];
    [self showIdx]; [self resetTimer]; ISLTick();
}

// ── тапы ──
- (void)tapIsland:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:_island];
    if (_state == ISLStIdle) {
        ISLTick();
        if (_queue.count) { _idx = _queue.count - 1; [self showIdx]; [self setState:ISLStChat]; }
        else { [self updateMedia]; [self setState:ISLStMedia]; }
        return;
    }
    CGFloat hz = [self collapsedFrame].size.height + 4;
    if (p.y < hz && _state != ISLStCompose && _state != ISLStSent) { [self setState:ISLStIdle]; return; }
    [self resetTimer];
}
- (void)longIsland:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) [self openPanel];
}
- (void)tapCard {
    if (_state != ISLStChat || _queue.count == 0) return;
    ISLNote *n = _queue[_idx];
    ISLTick();
    if (!n.isTest) ISLOpenApp(n.bundleID);
    [self hideCurrent];
}
- (void)tapReply { ISLTick(); [self enterCompose]; }
- (void)tapHide { ISLTick(); [self hideCurrent]; }
- (void)tapCancel { ISLTick(); [_kb reset]; [self setState:ISLStChat]; }

// ── ответ ──
- (void)enterCompose {
    if (_queue.count == 0) return;
    [_timer invalidate]; _timer = nil;
    [_kb reset];
    [self setState:ISLStCompose];
}
- (void)doSend:(NSString *)text {
    if (_queue.count == 0 || _sending || text.length == 0) return;
    _sending = YES;
    ISLNote *n = _queue[MIN(_idx, (NSInteger)_queue.count - 1)];
    ISLSendReply(n, text, ^(BOOL ok) { [self finishSend:ok note:n]; });
}
- (void)finishSend:(BOOL)ok note:(ISLNote *)n {
    _sending = NO;
    if (ok) {
        _sent.text = @"Отправлено ✓"; _sent.textColor = [UIColor colorWithRed:0.30 green:0.90 blue:0.45 alpha:1];
        ISLBuzz(UINotificationFeedbackTypeSuccess);
        [_queue removeObject:n];
        _idx = MAX(0, MIN(_idx, (NSInteger)_queue.count - 1));
        [_kb reset];
        [self setState:ISLStSent];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_state != ISLStSent) return;
            if (self->_queue.count && [ISLConfig i:@"mode"] == 0) { [self showIdx]; [self setState:ISLStChat]; }
            else [self setState:ISLStIdle];
        });
    } else {
        _sent.text = @"Не отправлено ✕"; _sent.textColor = [UIColor colorWithRed:1 green:0.35 blue:0.35 alpha:1];
        ISLBuzz(UINotificationFeedbackTypeError);
        [self setState:ISLStSent];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_state == ISLStSent) [self setState:ISLStCompose];   // текст сохранён, можно повторить
        });
    }
}

// ── плеер ──
- (void)mediaChanged { [self updateMedia]; [self updateAccessories]; }
- (void)updateMedia {
    ISLMedia *m = [ISLMedia shared];
    _mTitle.text = m.title ?: @"Ничего не играет";
    _mArtist.text = m.artist ?: @"";
    [_mPlay setTitle:(m.playing ? @"⏸" : @"▶︎") forState:UIControlStateNormal];
    if (!_mVol.isTracking) _mVol.value = m.volume;
    _mVolLbl.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(m.volume * 100)];
    _mVolIcon.text = m.volume < 0.01 ? @"🔇" : (m.volume < 0.5 ? @"🔉" : @"🔊");
}
- (void)updateMediaRunning {
    [_volTimer invalidate]; _volTimer = nil;
    if (_state == ISLStMedia) {
        _volTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 target:self selector:@selector(volTick) userInfo:nil repeats:YES];
        [_mEq startRunning];
    } else [_mEq stopRunning];
}
- (void)volTick { [[ISLMedia shared] pollVolume]; [self updateMedia]; }
- (void)volChanged:(UISlider *)s {
    [[ISLMedia shared] setVolumeValue:s.value];
    _mVolLbl.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(s.value * 100)];
    [self resetTimer];
}
- (void)tapPlay { ISLTick(); [[ISLMedia shared] command:2]; [self resetTimer]; }
- (void)tapPrev { ISLTick(); [[ISLMedia shared] command:5]; [self resetTimer]; }
- (void)tapNext { ISLTick(); [[ISLMedia shared] command:4]; [self resetTimer]; }

// ── панель настроек ──
- (void)openPanel {
    if (_panelOpen) return;
    [[ISLMedia shared] start];
    if (!_panel) {
        _panel = [ISLPanel new];
        __weak ISLController *ws = self;
        _panel.onClose = ^{ [ws closePanel]; };
        _panel.onTest = ^{ [ws showTest]; };
        [_root addSubview:_panel];
    }
    CGRect c = [self collapsedFrame];
    CGFloat H = [UIScreen mainScreen].bounds.size.height;
    CGFloat y = c.origin.y + c.size.height + 4 + 116 + 12;
    _panel.frame = CGRectMake(12, y, [self W] - 24, MAX(260, MIN(560, H - y - 24)));
    _panelOpen = YES;
    [_panel reloadAll]; [_panel startLive];
    _panel.alpha = 0; _panel.transform = CGAffineTransformMakeScale(0.96, 0.96); _panel.hidden = NO;
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.3 options:0 animations:^{
        self->_panel.alpha = 1; self->_panel.transform = CGAffineTransformIdentity;
    } completion:nil];
    ISLTick();
    [self setState:ISLStIdle];
}
- (void)closePanel {
    _panelOpen = NO;
    [_panel stopLive];
    [UIView animateWithDuration:0.2 animations:^{ self->_panel.alpha = 0; } completion:^(BOOL f) { self->_panel.hidden = YES; }];
    [self resetTimer];
}
@end

#pragma mark - Разбор перехваченного уведомления

static BOOL ISLAllowed(NSString *bid) {
    if (!bid.length) return NO;
    BOOL inList = [[[ISLConfig d] arrayForKey:@"listIDs"] containsObject:bid];
    return [ISLConfig i:@"listMode"] == 0 ? inList : !inList;   // 0 = whitelist, 1 = blacklist
}
// Убираем «баннерное» назначение у запроса (в центре уведомлений и на экране блокировки оно остаётся)
static void ISLStripBanner(id req) {
    if (!req || ![ISLConfig b:@"hideBanner"]) return;
    @try {
        id d = ISLKV(req, @"requestDestinations");
        if ([d isKindOfClass:[NSSet class]]) {
            NSMutableSet *m = [d mutableCopy];
            for (id x in d)
                if ([x isKindOfClass:[NSString class]] && [(NSString *)x rangeOfString:@"Banner" options:NSCaseInsensitiveSearch].location != NSNotFound) [m removeObject:x];
            [req setValue:[m copy] forKey:@"requestDestinations"];
        }
    } @catch (__unused id e) {}
}
static void ISLIngest(id req, id bulletinOverride) {
    @try {
        if (![ISLConfig b:@"msgOn"]) return;
        id bulletin = bulletinOverride ?: ISLKV(req, @"bulletin");
        NSString *bid = ISLStr(ISLKV(req, @"sectionIdentifier")) ?: ISLStr(ISLKV(bulletin, @"sectionID"));
        if (!ISLAllowed(bid)) return;
        id content = ISLKV(req, @"content");
        NSString *title = ISLStr(ISLKV(content, @"title")) ?: ISLStr(ISLKV(content, @"header")) ?: ISLStr(ISLKV(bulletin, @"title"));
        NSString *sub = ISLStr(ISLKV(content, @"subtitle")) ?: ISLStr(ISLKV(bulletin, @"subtitle"));
        NSString *msg = ISLStr(ISLKV(content, @"message")) ?: ISLStr(ISLKV(bulletin, @"message"));
        if (!title && !msg) return;
        ISLNote *n = [ISLNote new];
        n.bundleID = bid; n.title = title ?: @"";
        n.text = sub.length ? [NSString stringWithFormat:@"%@: %@", sub, msg ?: @""] : (msg ?: @"");
        n.noteID = ISLStr(ISLKV(req, @"notificationIdentifier")) ?: ISLStr(ISLKV(bulletin, @"bulletinID")) ?: [[NSUUID UUID] UUIDString];
        n.threadID = ISLStr(ISLKV(req, @"threadIdentifier")) ?: ISLStr(ISLKV(bulletin, @"threadID"));
        n.request = req; n.bulletin = bulletin;
        id ic = ISLKV(content, @"icon");
        if ([ic isKindOfClass:[UIImage class]]) n.avatar = ic;
        else {
            id arr = ISLKV(content, @"icons");
            if ([arr isKindOfClass:[NSArray class]]) for (id x in arr) if ([x isKindOfClass:[UIImage class]]) { n.avatar = x; break; }
        }
        ISLStripBanner(req);
        dispatch_async(dispatch_get_main_queue(), ^{ [[ISLController shared] ingest:n force:NO]; });
    } @catch (__unused id e) {}
}

#pragma mark - Хуки (Logos)

%group GSpring
%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[ISLController shared] boot];
    });
}
%end
%end

// Основной перехват: UserNotificationsUIKit
%group GNC
%hook NCNotificationDispatcher
- (void)postNotificationWithRequest:(id)request {
    ISLIngest(request, nil);
    %orig;
}
%end
%end

// Запасной перехват: BulletinBoard (используется, только если NC-хук недоступен)
%group GBB
%hook BBServer
- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations {
    ISLIngest(nil, bulletin);
    %orig;
}
%end
%end

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
        %init(GSpring);
        Class nc = objc_getClass("NCNotificationDispatcher");
        if (nc && class_getInstanceMethod(nc, NSSelectorFromString(@"postNotificationWithRequest:"))) {
            %init(GNC);
            NSLog(@"[IslandMessenger] hook: NCNotificationDispatcher");
        } else {
            Class bb = objc_getClass("BBServer");
            if (bb && class_getInstanceMethod(bb, NSSelectorFromString(@"publishBulletin:destinations:"))) {
                %init(GBB);
                NSLog(@"[IslandMessenger] hook: BBServer (fallback)");
            } else {
                NSLog(@"[IslandMessenger] no notification hook available on this iOS");
            }
        }
    }
}
