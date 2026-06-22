// macos.zig — macOS WebView shell backend (WKWebView + NSWindow).
//
// ObjC interop pattern (proven in examples/desktop/spike.zig, #50):
//   - extern fn declarations for the ObjC runtime primitives
//   - typed `objc_msgSend` casts per call-site
//   - NO @cImport (AppKit.h / WebKit.h Objective-C syntax breaks translate-c)
//   - AppKit/WebKit/Foundation linked as frameworks in build.zig
//
// P2 adds the `window.mer.invoke` JS↔Zig bridge:
//   - a WKUserScript injecting the `window.mer` shim at document start
//   - a dynamically-allocated delegate class (MerInvokeHandler) conforming to
//     WKScriptMessageHandler, with an IMP that calls bridge.dispatch()
//   - the IMP evaluates the returned `window.mer._resolve(...)` JS on the webview

const std = @import("std");
const manifest = @import("manifest.zig");
const bridge = @import("bridge.zig");

// ── ObjC runtime primitives ─────────────────────────────────────────────────
extern fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
extern fn objc_msgSend() void; // variadic; cast per call-site
extern fn objc_allocateClassPair(superclass: Id, name: [*:0]const u8, extra_bytes: usize) Id;
extern fn class_addMethod(cls: Id, name: Sel, imp: *const anyopaque, types: [*:0]const u8) BOOL;
extern fn objc_registerClassPair(cls: Id) void;

// ── C types ─────────────────────────────────────────────────────────────────
const Id = ?*anyopaque;
const Sel = ?*anyopaque;
const CGFloat = f64;
const CGPoint = extern struct { x: CGFloat, y: CGFloat };
const CGSize = extern struct { width: CGFloat, height: CGFloat };
const CGRect = extern struct { origin: CGPoint, size: CGSize };
const NSUInteger = c_ulong;
const NSInteger = c_long;
const BOOL = i8;

// AppKit / WebKit constants
const NSWindowStyleMaskTitled: NSUInteger = 1;
const NSWindowStyleMaskClosable: NSUInteger = 2;
const NSWindowStyleMaskMiniaturizable: NSUInteger = 4;
const NSWindowStyleMaskResizable: NSUInteger = 8;
const NSBackingStoreBuffered: NSUInteger = 2;
const NSApplicationActivationPolicyRegular: NSInteger = 0;
const YES: BOOL = 1;
const NO: BOOL = 0;
const WKUserScriptInjectionTimeAtDocumentStart: NSUInteger = 0;

fn cls(name: [*:0]const u8) Id {
    return objc_getClass(name);
}
fn sel(name: [*:0]const u8) Sel {
    return sel_registerName(name);
}

// Typed objc_msgSend casts — one per distinct signature
fn send(recv: Id, s: Sel) Id {
    const F = *const fn (Id, Sel) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s);
}
fn sendv(recv: Id, s: Sel) void {
    const F = *const fn (Id, Sel) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s);
}
fn send1(recv: Id, s: Sel, a: Id) Id {
    const F = *const fn (Id, Sel, Id) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}
fn send1v(recv: Id, s: Sel, a: Id) void {
    const F = *const fn (Id, Sel, Id) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}
fn send2v(recv: Id, s: Sel, a1: Id, a2: Id) void {
    const F = *const fn (Id, Sel, Id, Id) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s, a1, a2);
}
fn sendStr(recv: Id, s: Sel, str: [*:0]const u8) Id {
    const F = *const fn (Id, Sel, [*:0]const u8) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, str);
}
fn sendPtr(recv: Id, s: Sel) [*:0]const u8 {
    const F = *const fn (Id, Sel) callconv(.c) [*:0]const u8;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s);
}
fn sendInt(recv: Id, s: Sel) NSInteger {
    const F = *const fn (Id, Sel) callconv(.c) NSInteger;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s);
}
fn sendIntv(recv: Id, s: Sel, a: NSInteger) void {
    const F = *const fn (Id, Sel, NSInteger) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}
fn sendBoolv(recv: Id, s: Sel, a: BOOL) void {
    const F = *const fn (Id, Sel, BOOL) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(recv, s, a);
}
fn send1Bool(recv: Id, s: Sel, a: Id) bool {
    const F = *const fn (Id, Sel, Id) callconv(.c) BOOL;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, a) != NO;
}
fn sendWindowInit(recv: Id, s: Sel, rect: CGRect, style: NSUInteger, backing: NSUInteger, defer_: BOOL) Id {
    const F = *const fn (Id, Sel, CGRect, NSUInteger, NSUInteger, BOOL) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, rect, style, backing, defer_);
}
fn sendWebViewInit(recv: Id, s: Sel, frame: CGRect, config: Id) Id {
    const F = *const fn (Id, Sel, CGRect, Id) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, frame, config);
}
fn sendUserScriptInit(recv: Id, s: Sel, source: Id, time: NSUInteger, main: BOOL) Id {
    const F = *const fn (Id, Sel, Id, NSUInteger, BOOL) callconv(.c) Id;
    return @as(F, @ptrCast(&objc_msgSend))(recv, s, source, time, main);
}

// ── Bridge globals (single-window app) ──────────────────────────────────────
var g_webview: Id = null;
var g_bridge_ctx: ?*bridge.Ctx = null;
var g_app_delegate: Id = null;

/// The `window.mer` shim injected at document start. Provides:
///   window.mer.invoke(cmd, args) -> Promise
///   window.mer._resolve(id, ok, value)  (called from Zig via evaluateJavaScript)
const mer_shim: [*:0]const u8 =
    "(function(){" ++
    "if(window.mer)return;" ++
    "var cb={},idc=0;" ++
    "window.mer={" ++
    "invoke:function(c,a){return new Promise(function(r,j){" ++
    "var id=++idc;cb[id]={r:r,j:j};" ++
    "try{var p=JSON.stringify({cmd:c,args:a||null,id:id});if(p.length>65536){delete cb[id];j('PayloadTooLarge');return;}window.webkit.messageHandlers.merInvoke.postMessage(p);}" ++
    "catch(e){delete cb[id];j('BridgeUnavailable');}" ++
    "});}," ++
    "_resolve:function(id,ok,v){var h=cb[id];if(!h)return;delete cb[id];if(ok)h.r(v);else h.j(v);}" ++
    "};" ++
    "})();";

/// IMP for `-[MerInvokeHandler userContentController:didReceiveScriptMessage:]`.
/// Pulls the message body (the posted JSON envelope), runs bridge.dispatch, and
/// evaluates the returned `window.mer._resolve(...)` JS on the webview.
fn merInvokeIMP(self: Id, _cmd: Sel, ucc: Id, message: Id) callconv(.c) void {
    _ = self;
    _ = _cmd;
    _ = ucc;
    const wv = g_webview orelse return;
    const ctx = g_bridge_ctx orelse return;

    const body = send(message, sel("body")) orelse return;
    if (!send1Bool(body, sel("isKindOfClass:"), cls("NSString"))) {
        const js = bridge.rejectFromPayload(ctx, "", "ParseError") catch return;
        defer ctx.allocator.free(js);
        evalJs(ctx, wv, js);
        return;
    }
    const cstr = sendPtr(body, sel("UTF8String"));
    const payload = std.mem.span(cstr);

    var origin_buf: [512]u8 = undefined;
    const origin = messageFrameOrigin(message, &origin_buf) orelse {
        const js = bridge.rejectFromPayload(ctx, payload, "OriginNotAllowed") catch return;
        defer ctx.allocator.free(js);
        evalJs(ctx, wv, js);
        return;
    };
    if (!bridge.isOriginAllowed(ctx, origin)) {
        const js = bridge.rejectFromPayload(ctx, payload, "OriginNotAllowed") catch return;
        defer ctx.allocator.free(js);
        evalJs(ctx, wv, js);
        return;
    }

    const js = bridge.dispatch(ctx, payload) catch return;
    defer ctx.allocator.free(js);
    evalJs(ctx, wv, js);
}

fn evalJs(ctx: *bridge.Ctx, webview: Id, js: []const u8) void {
    const js_z = ctx.allocator.dupeZ(u8, js) catch return;
    defer ctx.allocator.free(js_z);
    const ns_js = sendStr(cls("NSString"), sel("stringWithUTF8String:"), js_z.ptr);
    send2v(webview, sel("evaluateJavaScript:completionHandler:"), ns_js, null);
}

fn messageFrameOrigin(message: Id, buf: *[512]u8) ?[]const u8 {
    const frame_info = send(message, sel("frameInfo")) orelse return null;
    const security_origin = send(frame_info, sel("securityOrigin")) orelse return null;
    const proto_obj = send(security_origin, sel("protocol")) orelse return null;
    const host_obj = send(security_origin, sel("host")) orelse return null;
    const proto = std.mem.span(sendPtr(proto_obj, sel("UTF8String")));
    const host = std.mem.span(sendPtr(host_obj, sel("UTF8String")));
    if (proto.len == 0 or host.len == 0) return null;
    const port = sendInt(security_origin, sel("port"));
    if (port > 0) {
        return std.fmt.bufPrint(buf, "{s}://{s}:{d}", .{ proto, host, port }) catch null;
    }
    return std.fmt.bufPrint(buf, "{s}://{s}", .{ proto, host }) catch null;
}

/// Allocate the MerInvokeHandler delegate class (NSObject + one instance method).
/// Idempotent: returns the existing class if already registered.
fn createMerHandlerClass() Id {
    if (cls("MerInvokeHandler")) |existing| return existing;
    const nsobject = cls("NSObject") orelse return null;
    const new_class = objc_allocateClassPair(nsobject, "MerInvokeHandler", 0);
    if (new_class == null) return null;
    // void userContentController:(id)didReceiveScriptMessage:(id)  →  "v@:@@"
    _ = class_addMethod(
        new_class,
        sel("userContentController:didReceiveScriptMessage:"),
        @ptrCast(&merInvokeIMP),
        "v@:@@",
    );
    objc_registerClassPair(new_class);
    return new_class;
}

fn appShouldTerminateAfterLastWindowClosed(self: Id, _cmd: Sel, app: Id) callconv(.c) BOOL {
    _ = self;
    _ = _cmd;
    _ = app;
    return YES;
}

fn createAppDelegateClass() Id {
    if (cls("MerAppDelegate")) |existing| return existing;
    const nsobject = cls("NSObject") orelse return null;
    const new_class = objc_allocateClassPair(nsobject, "MerAppDelegate", 0);
    if (new_class == null) return null;
    _ = class_addMethod(
        new_class,
        sel("applicationShouldTerminateAfterLastWindowClosed:"),
        @ptrCast(&appShouldTerminateAfterLastWindowClosed),
        "c@:@",
    );
    objc_registerClassPair(new_class);
    return new_class;
}

/// Inject the `window.mer` shim and register the merInvoke message handler on
/// the webview's userContentController. Safe to call once per webview.
fn setupBridge(webview: Id, ctx: *bridge.Ctx) void {
    g_webview = webview;
    g_bridge_ctx = ctx;

    // Reach the webview's shared userContentController via its configuration.
    const config = send(webview, sel("configuration"));
    const ucc = send(config, sel("userContentController"));

    // 1. Inject the shim at document start.
    const ns_shim = sendStr(cls("NSString"), sel("stringWithUTF8String:"), mer_shim);
    const user_script = sendUserScriptInit(
        send(cls("WKUserScript"), sel("alloc")),
        sel("initWithSource:injectionTime:forMainFrameOnly:"),
        ns_shim,
        WKUserScriptInjectionTimeAtDocumentStart,
        YES,
    );
    send1v(ucc, sel("addUserScript:"), user_script);

    // 2. Register the message handler.
    const handler_class = createMerHandlerClass() orelse return;
    const handler = send(send(handler_class, sel("alloc")), sel("init"));
    var name_buf: [32]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name_buf, "merInvoke", .{}) catch return;
    const ns_name = sendStr(cls("NSString"), sel("stringWithUTF8String:"), name_z.ptr);
    send2v(ucc, sel("addScriptMessageHandler:name:"), handler, ns_name);
}

/// Open a native window hosting a WKWebView pointed at `url_z`. Blocks on the
/// NSApp event loop until the window is closed.
///
/// `url_z` must be NUL-terminated. `ctx` (if non-null) enables the
/// `window.mer.invoke` bridge.
pub fn openWindow(url_z: [*:0]const u8, win: manifest.WindowConfig, ctx: ?*bridge.Ctx) void {
    const app = send(cls("NSApplication"), sel("sharedApplication"));
    sendIntv(app, sel("setActivationPolicy:"), NSApplicationActivationPolicyRegular);
    if (createAppDelegateClass()) |delegate_class| {
        g_app_delegate = send(send(delegate_class, sel("alloc")), sel("init"));
        send1v(app, sel("setDelegate:"), g_app_delegate);
    }

    const frame = CGRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(win.width), .height = @floatFromInt(win.height) },
    };
    const style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    const window = sendWindowInit(
        send(cls("NSWindow"), sel("alloc")),
        sel("initWithContentRect:styleMask:backing:defer:"),
        frame,
        style,
        NSBackingStoreBuffered,
        NO,
    );

    var title_buf: [256]u8 = undefined;
    const title_z = std.fmt.bufPrintZ(&title_buf, "{s}", .{win.title}) catch "merjs";
    const title = sendStr(cls("NSString"), sel("stringWithUTF8String:"), title_z.ptr);
    send1v(window, sel("setTitle:"), title);

    // WKWebView with a configuration we can reach for the bridge.
    const wkconfig = send(
        send(cls("WKWebViewConfiguration"), sel("alloc")),
        sel("init"),
    );
    const webview = sendWebViewInit(
        send(cls("WKWebView"), sel("alloc")),
        sel("initWithFrame:configuration:"),
        frame,
        wkconfig,
    );
    send1v(window, sel("setContentView:"), webview);

    // Bridge: inject shim + register handler before the first load.
    if (ctx) |c| setupBridge(webview, c);

    // Load the merjs server URL.
    const ns_url_str = sendStr(cls("NSString"), sel("stringWithUTF8String:"), url_z);
    const url = send1(cls("NSURL"), sel("URLWithString:"), ns_url_str);
    const request = send1(cls("NSURLRequest"), sel("requestWithURL:"), url);
    _ = send1(webview, sel("loadRequest:"), request);

    send1v(window, sel("makeKeyAndOrderFront:"), null);
    sendBoolv(app, sel("activateIgnoringOtherApps:"), YES);
    sendv(app, sel("run")); // blocks until window closed
}
