// Thunderbird background-use tuning
// Place this file in the active Thunderbird profile directory as user.js.
// Thunderbird reads user.js on startup and applies these user preferences.
//
// Goal
// Reduce background indexing, proactive IMAP body downloads, disk activity,
// and unnecessary polling while retaining IMAP IDLE push notifications.
//
// Notes
// 1. Quit Thunderbird before editing this file.
// 2. Preferences in user.js are reapplied on every Thunderbird startup.
// 3. Per-account mail.server.serverN.* values can override mail.server.default.*.
// 4. GPU and accessibility workarounds below are intentionally commented out.

// -----------------------------------------------------------------------------
// Global search / Gloda
// -----------------------------------------------------------------------------

// Disable Thunderbird's global message indexer.
// Tradeoff: Global Search loses much of its indexed-search functionality.
user_pref("mailnews.database.global.indexer.enabled", false);


// -----------------------------------------------------------------------------
// IMAP offline synchronization
// -----------------------------------------------------------------------------

// Do not proactively download IMAP message bodies into offline stores.
user_pref("mail.server.default.autosync_offline_stores", false);

// Do not make newly created server folders offline-download folders by default.
user_pref("mail.server.default.offline_download", false);


// -----------------------------------------------------------------------------
// IMAP notification and fallback polling
// -----------------------------------------------------------------------------

// Keep IMAP IDLE enabled so a capable server can notify Thunderbird immediately.
user_pref("mail.server.default.use_idle", true);

// Use a relatively infrequent fallback poll, in minutes.
// Existing accounts may have mail.server.serverN.check_time set explicitly.
user_pref("mail.server.default.check_time", 60);


// -----------------------------------------------------------------------------
// Optional per-account overrides
// -----------------------------------------------------------------------------
//
// Existing accounts often have their own mail.server.serverN.* preferences.
// Find the relevant server number in Settings > General > Config Editor by
// searching for mail.server.server and inspecting hostname/type entries.
//
// Example for server3
//
// user_pref("mail.server.server3.autosync_offline_stores", false);
// user_pref("mail.server.server3.offline_download", false);
// user_pref("mail.server.server3.use_idle", true);
// user_pref("mail.server.server3.check_time", 60);
//
// Repeat for each IMAP account you want tuned.


// -----------------------------------------------------------------------------
// Accessibility-related performance workaround
// -----------------------------------------------------------------------------
//
// Try the accessibility cache first if Thunderbird shows UI lag associated
// with accessibility handling.
//
// user_pref("accessibility.cache.enabled", true);
//
// More aggressive workaround, only if needed.
// Tradeoff: disables accessibility services used by screen readers and
// related assistive software.
//
// user_pref("accessibility.force_disabled", 1);


// -----------------------------------------------------------------------------
// Graphics workaround
// -----------------------------------------------------------------------------
//
// Only enable this if hardware acceleration is demonstrably causing high GPU
// use, hangs, rendering glitches, or elevated power consumption.
// Software rendering can increase CPU use on otherwise healthy systems.
//
// user_pref("layers.acceleration.disabled", true);


// -----------------------------------------------------------------------------
// Background sending
// -----------------------------------------------------------------------------
//
// This affects compose-window behavior rather than idle resource use.
// Uncomment if desired.
//
// user_pref("mailnews.sendInBackground", true);
