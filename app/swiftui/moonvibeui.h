#pragma once

#include <stdbool.h>

// C entry points exported by the SwiftUI shell (app/swiftui/*.swift).
// All of them must be called on the main thread.
//
// Data crosses the bridge as UTF-8 JSON:
// - computers: [{uuid, name, online, paired, canWake, mac, runningAppId,
//                apps: [{id, name}],
//                addresses: [{address, port, kind: "local" | "remote" | "ipv6" | "manual", active}]}]
// - prefs: {resolutionMode, width, height, fps, bitrateKbps, windowMode,
//           vsync, framePacing, hdr, muteHost, disableAwdl}
// - status: {text, busy, error, cancellable, args}: text is a French template with %1, %2…
//   placeholders for args, which the UI translates; text without args may be final text
// - pairing: {uuid, stage: "waiting" | "paired" | "failed", pin, error}
// - add host result: {success, portBlocking}
// - wake result: {uuid, sent}
// - address test result: {uuid, address, result: "ok" | "other" | "unreachable" | "invalid"}
// - actions sent back by the shell: {action: "launch", uuid, appId, displayX, displayY,
//                                    overrides?: {resolutionMode, width, height, fps, bitrateKbps}}
//   | {action: "cancel"} | {action: "wake", uuid, mac?, address?, port?} | {action: "quitApp", uuid}
//   | {action: "setPrefs", prefs} | {action: "pair", uuid} | {action: "addHost", address}
//   | {action: "deleteHost", uuid} | {action: "streamAction", value: Session::StreamAction}
//   | {action: "rename", uuid, name} | {action: "setAddresses", uuid, addresses: [string]}
//   | {action: "testAddress", uuid, address}
// - stream overlay: begin {computer, app, targetMbps}, stats {fps, width, height,
//   bitrateMbps, rttMs, decodeMs, dropPercent}
//   | {action: "quit"}

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*MVActionCallback)(const char* json);
// Stream state flags polled by the overlay
enum { MV_STREAM_CAPTURED = 1, MV_STREAM_STATS = 2, MV_STREAM_FULLSCREEN = 4 };
typedef int (*MVStreamStateCallback)(void);

void mv_ui_show(MVActionCallback action);
void mv_ui_update_computers(const char* json);
void mv_ui_update_prefs(const char* json);
void mv_ui_set_status(const char* json);
void mv_ui_set_visible(bool visible);
void mv_ui_update_pairing(const char* json);
void mv_ui_add_host_result(const char* json);
void mv_ui_wake_result(const char* json);
void mv_ui_address_test_result(const char* json);
// How the stream that just ended went (Session::StreamReport)
void mv_ui_stream_report(const char* json);

// Stream overlays, shown above the SDL stream window (an NSWindow*). Unlike the rest
// of the API, they run while Qt's event loop is suspended, and mv_overlay_stats() is
// called from the decoder thread.
void mv_overlay_begin(void* streamWindow, const char* json, MVStreamStateCallback state);
void mv_overlay_stats(const char* json);
void mv_overlay_end(void);

#ifdef __cplusplus
}
#endif
