// user_pref("dom.ipc.processCount", 8); // default value is 8, however firefox can auto set depending on pc
user_pref("accessibility.force_disabled", 0); // default value is 0
user_pref("layers.acceleration.force-enabled", false); // default value is false
user_pref("media.hardware-video-decoding.force-enabled", false);
user_pref("webgl.force-enabled", false);

user_pref("gfx.blacklist.video-overlay", "");
user_pref("gfx.blacklist.video-overlay.failureid", "");
user_pref("gfx.canvas.accelerated.force-enabled", false);
user_pref("gfx.webgpu.ignore-blocklist", false);
user_pref("gfx.webrender.all", false);
user_pref("gfx.webrender.compositor.force-enabled", false);
user_pref("gfx.webrender.dcomp-video-overlay-win", "");
user_pref("gfx.webrender.dcomp-video-yuv-overlay-win", "");
user_pref("gfx.webrender.dcomp-win.enabled", true);

user_pref("pdfjs.spreadModeOnLoad", "");
user_pref("pdfjs.defaultZoomValue", "");
user_pref("pdfjs.scrollModeOnLoad", "-1");

user_pref("network.dns.disablePrefetch", false);
user_pref("network.http.max-connections", 900);
user_pref("network.http.max-persistent-connections-per-proxy", 32);
user_pref("network.http.max-persistent-connections-per-server", 6);
user_pref(
    "network.http.referer.disallowCrossSiteRelaxingDefault.top_navigation",
    false
);
user_pref("network.http.speculative-parallel-limit", 10);
user_pref("network.predictor.enabled", true);
user_pref("network.prefetch-next", true);

user_pref("signon.firefoxRelay.feature", "available");
user_pref("signon.generation.enabled", true);

user_pref("app.update.background.enabled", true);
user_pref("app.update.auto", true);
user_pref("app.update.BITS.enabled", true);
user_pref("app.update.langpack.enabled", false);
// user_pref("app.update.channel", "release");

user_pref("browser.search.region", "");

// Scrolling
user_pref("general.smoothScroll.msdPhysics.continuousMotionMaxDeltaMS", 120);
user_pref("general.smoothScroll.msdPhysics.enabled", false);
user_pref("general.smoothScroll.msdPhysics.motionBeginSpringConstant", 1250);
user_pref("general.smoothScroll.msdPhysics.regularSpringConstant", 1000);
user_pref("general.smoothScroll.msdPhysics.slowdownMinDeltaMS", 12);
user_pref("general.smoothScroll.msdPhysics.slowdownMinDeltaRatio", "1.3");
user_pref("general.smoothScroll.msdPhysics.slowdownSpringConstant", 2000);
user_pref("general.smoothScroll.currentVelocityWeighting", "0.25");
user_pref("general.smoothScroll.stopDecelerationWeighting", "0.4");
