// ==UserScript==
// @name         YouTube AV1
// @namespace    http://www.youtube.com
// @version      1.0.0
// @description  Prioritize/force AV1 on YouTube - Adapted by LLM from update.greasyfork.org/scripts/584262/Youtube%20H264%20%28upd%202026%29.user.js
// @match        *://youtube.com/*
// @match        *://*.youtube.com/*
// @license      MIT
// @grant        none
// @run-at       document-start
// @downloadURL https://github.com/Zerohazard8x/custom/raw/main/js/youtube-av1.js
// @updateURL https://github.com/Zerohazard8x/custom/raw/main/js/youtube-av1.js
// ==/UserScript==

var youtubeAV1 = function () {
    var fallback = ['av01', 'vp09', 'vp9', 'avc1', 'avc3', 'vp8', 'vp08'];
    function isFallback(type) {
        if (!type) return false;
        if (type.indexOf('opus') !== -1) return false;
        return fallback.slice(1).some(c => type.indexOf(c) !== -1);
    }

    var videoElem = document.createElement('video');
    var origCanPlayType = videoElem.canPlayType.bind(videoElem);
    videoElem.__proto__.canPlayType = function (type) {
        if (isFallback(type) && origCanPlayType(type)) return 'maybe';
        return origCanPlayType(type);
    };
};

youtubeAV1();
