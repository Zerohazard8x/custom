// ==UserScript==
// @name         Zerohazard8x's font-size adjust
// @namespace    http://tampermonkey.net/
// @version      2024-06-30
// @author       LLM + Zerohazard8x
// @match        *://*/*
// @grant        GM_addStyle
// @downloadURL https://github.com/Zerohazard8x/custom/raw/main/js/font-size-adjust.user.js
// @updateURL https://github.com/Zerohazard8x/custom/raw/main/js/font-size-adjust.user.js
// @homepageURL     https://github.com/Zerohazard8x/custom/tree/main/js
// @supportURL      https://github.com/Zerohazard8x/custom/tree/main/js
// ==/UserScript==

(function () {
    "use strict";

    // Create a single style element for all CSS rules
    const style = document.createElement("style");
    style.id = "0hz_FontSizeAdjust";
    document.head.appendChild(style);

    // Function to add CSS rules
    function addStyle(css) {
        style.sheet.insertRule(css, style.sheet.cssRules.length);
    }

    // CSS rules
    const cssRules = [
        `*:not(pre *, .far, .fa, .glyphicon, [class*="vjs-"], .fab, .fa-github, .fas, .material-icons, .icofont, .typcn, mu, [class*="mu-"], .glyphicon, .icon), pre, code, tt {
            font-size-adjust: from-font !important;
        }`,
    ];

    // Add all CSS rules
    cssRules.forEach(addStyle);
})();