user_pref("app.normandy.first_run", false);

user_pref("browser.discovery.enabled", false);
user_pref("browser.newtabpage.activity-stream.feeds.topsites", true); // New tab shortcuts
user_pref("browser.newtabpage.activity-stream.newtabLayouts.variant-b", true);
user_pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);
user_pref("browser.profiles.enabled", true);
user_pref("browser.startup.page", 3);
user_pref("browser.tabs.groups.smart.enabled", true);

user_pref("app.shield.optoutstudies.enabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);

user_pref("dom.security.https_only_mode", true);
user_pref("dom.security.https_only_mode_ever_enabled", true);

user_pref("dom.private-attribution.submission.enabled", false);

user_pref("browser.contentblocking.category", "custom");
user_pref("browser.search.suggest.enabled", true);
user_pref("browser.search.suggest.enabled.private", true);
user_pref("privacy.annotate_channels.strict_list.enabled", true);
user_pref("privacy.fingerprintingProtection.pbmode", false);
user_pref("privacy.partition.network_state.ocsp_cache", true);
user_pref("privacy.query_stripping.enabled", true);
user_pref("privacy.query_stripping.enabled.pbmode", true);
user_pref("privacy.resistFingerprinting.pbmode", false); /// local font rendering
user_pref("privacy.trackingprotection.emailtracking.enabled", true);
user_pref("privacy.trackingprotection.enabled", true);
user_pref("privacy.trackingprotection.socialtracking.enabled", true);

user_pref("gfx.color_management.mode", 1);
user_pref("gfx.font_rendering.cleartype_params.rendering_mode", 5);

user_pref("media.wmf.hevc.enabled", 1);
// user_pref("media.ffvpx-hw.enabled", true);
// user_pref("gfx.webrender.all", true);

user_pref(
    "network.http.referer.disallowCrossSiteRelaxingDefault.top_navigation",
    true
);
// user_pref("network.trr.custom_uri", "https://dns11.quad9.net/dns-query");
user_pref("network.trr.mode", 3);
// user_pref("network.trr.uri", "https://dns11.quad9.net/dns-query");
user_pref("networkuser_pref.trr.excluded-domains", "discord.com,discord.gg,discordapp.net,facebook.com,fbcdn.net,telegram.com,twitter.com,x.com");
// user_pref("network.trr.use_ohttp", true);

user_pref("pdfjs.defaultZoomValue", "page-height"); /// zoom
user_pref("pdfjs.scrollModeOnLoad", 3); /// scroll mode

user_pref("permissions.default.camera", 2);
user_pref("permissions.default.desktop-notification", 2);
user_pref("permissions.default.geo", 2);
user_pref("permissions.default.microphone", 2);
user_pref("permissions.default.xr", 2);

user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true); /// userchrome.css, etc

user_pref("app.update.auto", true);
user_pref("app.update.background.enabled", true);	
user_pref("app.update.background.interval", 1);

// user_pref("sidebar.revamp", true);
// user_pref("sidebar.verticalTabs", true);

user_pref("browser.tabs.allow_transparent_browser", true);

// downloads
user_pref("browser.download.useDownloadDir", true);
user_pref("browser.download.always_ask_before_handling_new_types", false);

user_pref("widget.windows.mica", true)
// user_pref("widget.windows.mica.popups", true)

// zen browser
// user_pref("zen.theme.content-element-separation", 0)

// Telemetry - https://github.com/K3V1991/Disable-Firefox-Telemetry-and-Data-Collection
// user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
// user_pref("browser.newtabpage.activity-stream.telemetry", false);
// user_pref("browser.ping-centre.telemetry", false);
// user_pref("datareporting.healthreport.service.enabled", false);
// user_pref("datareporting.healthreport.uploadEnabled", false);
// user_pref("datareporting.policy.dataSubmissionEnabled", false);
// user_pref("datareporting.sessions.current.clean", true);
// user_pref("devtools.onboarding.telemetry.logged", false);
// user_pref("toolkit.telemetry.archive.enabled", false);
// user_pref("toolkit.telemetry.bhrPing.enabled", false);
// user_pref("toolkit.telemetry.enabled", false);
// user_pref("toolkit.telemetry.firstShutdownPing.enabled", false);
// user_pref("toolkit.telemetry.hybridContent.enabled", false);
// user_pref("toolkit.telemetry.newProfilePing.enabled", false);
// user_pref("toolkit.telemetry.prompted", 2);
// user_pref("toolkit.telemetry.rejected", true);
// user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
// user_pref("toolkit.telemetry.server", "");
// user_pref("toolkit.telemetry.shutdownPingSender.enabled", false);
// user_pref("toolkit.telemetry.unified", false);
// user_pref("toolkit.telemetry.unifiedIsOptIn", false);
// user_pref("toolkit.telemetry.updatePing.enabled", false);

// https://github.com/yokoffing/Betterfox