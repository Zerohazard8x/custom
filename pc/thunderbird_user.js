// do below in profile folder
// [ -f "./prefs.js" ] || {
//     echo "Invalid Thunderbird profile."
//     exit 1
// }

// # Print each file and optionally delete it.
// delete_file() {
//     echo "Deleting: $1"
//     rm -- "$1"
// }

// # Clean IMAP accounts and RSS feeds.
// for root in "$PROFILE/ImapMail" "$PROFILE/Mail/Feeds"; do
//     [ -d "$root" ] || continue

//     # Only touch Feeds if RSS subscriptions are present.
//     if [ "$root" = "$PROFILE/Mail/Feeds" ] &&
//        [ ! -f "$root/feeds.json" ] &&
//        [ ! -f "$root/feeds.rdf" ]; then
//         echo "Skipping unverified RSS folder: $root"
//         continue
//     fi

//     echo "Scanning: $root"

//     # Remove mbox or Maildir message bodies.
//     while IFS= read -r -d '' f; do
//         store="${f%.msf}"

//         # mbox
//         [ ! -f "$store" ] || delete_file "$store"

//         # Maildir (preserve folder structure)
//         for dir in cur new tmp; do
//             if [ -d "$store/$dir" ]; then
//                 while IFS= read -r -d '' file; do
//                     delete_file "$file"
//                 done < <(find "$store/$dir" -type f -print0)
//             fi
//         done

//         # Remove the corresponding message index.
//         delete_file "$f"
//     done < <(find "$root" -type f -name '*.msf' -print0)
// done

// for f in "$PROFILE/Mail/Feeds/feeditems.json" "$PROFILE/Mail/Feeds/feeditems.rdf"; do
//     [ ! -f "$f" ] || delete_file "$f"
// done

// # Remove IMAP indexes so Thunderbird rebuilds them.
// echo "Deleting IMAP indexes..."
// find . -type f -name '*.msf' -print -delete
// rm -f global-messages-db.sqlite

user_pref("mail.closeToTray", true);
user_pref("mail.closeToTray.startInTray", true);

user_pref("mail.biff.play_sound", false);

// Disable global message indexer.
user_pref("mailnews.database.global.indexer.enabled", false);

// Do not proactively download IMAP message bodies into offline stores.
user_pref("mail.server.default.autosync_offline_stores", false);

// Do not make newly created server folders offline-download folders by default.
user_pref("mail.server.default.offline_download", false);

// Keep IMAP IDLE enabled so a capable server can notify Thunderbird immediately.
user_pref("mail.server.default.use_idle", true);

// server1
user_pref("mail.server.server1.autosync_offline_stores", false);
user_pref("mail.server.server1.offline_download", false);
user_pref("mail.server.server1.use_idle", true);

// server2
user_pref("mail.server.server2.autosync_offline_stores", false);
user_pref("mail.server.server2.offline_download", false);
user_pref("mail.server.server2.use_idle", true);

// server3
user_pref("mail.server.server3.autosync_offline_stores", false);
user_pref("mail.server.server3.offline_download", false);
user_pref("mail.server.server3.use_idle", true);

// server4
user_pref("mail.server.server4.autosync_offline_stores", false);
user_pref("mail.server.server4.offline_download", false);
user_pref("mail.server.server4.use_idle", true);

// server5
user_pref("mail.server.server5.autosync_offline_stores", false);
user_pref("mail.server.server5.offline_download", false);
user_pref("mail.server.server5.use_idle", true);

user_pref("datareporting.healthreport.uploadEnabled", false);

user_pref("dom.security.https_only_mode", true);
user_pref("dom.security.https_only_mode_ever_enabled", true);

user_pref("browser.search.suggest.enabled", true);
user_pref("browser.search.suggest.enabled.private", true);
user_pref("privacy.annotate_channels.strict_list.enabled", true);
user_pref("privacy.fingerprintingProtection.pbmode", false);

user_pref("gfx.color_management.mode", 1);
user_pref("gfx.color_management.hdr", true);

user_pref("media.hardware-video-decoding-vulkan.enabled", true);
user_pref("media.ffvpx-hw.enabled", true);

user_pref("gfx.font_rendering.cleartype_params.rendering_mode", 5);

user_pref("pdfjs.defaultZoomValue", "page-height"); /// zoom
user_pref("pdfjs.scrollModeOnLoad", 3); /// scroll mode

// downloads
user_pref("browser.download.useDownloadDir", true);
user_pref("browser.download.always_ask_before_handling_new_types", false);

user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.archive.enabled", false);
user_pref("toolkit.telemetry.bhrPing.enabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.firstShutdownPing.enabled", false);
user_pref("toolkit.telemetry.newProfilePing.enabled", false);
user_pref("toolkit.telemetry.shutdownPingSender.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("toolkit.telemetry.updatePing.enabled", false);