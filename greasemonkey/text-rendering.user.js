// ==UserScript==
// @name         Zerohazard8x's Text Rendering
// @namespace    http://tampermonkey.net/
// @version      2024-06-30
// @author       LLM + Zerohazard8x
// @match        *://*/*
// @grant        GM_addStyle
// ==/UserScript==

(function () {
    "use strict";

    // Create a single style element for all CSS rules
    const style = document.createElement("style");
    style.id = "0hz_TextRendering";
    document.head.appendChild(style);

    // Function to add CSS rules
    function addStyle(css) {
        style.sheet.insertRule(css, style.sheet.cssRules.length);
    }

    // CSS rules
    const cssRules = [
        `*:not(pre *, .far, .fa, .glyphicon, [class*="vjs-"], .fab, .fa-github, .fas, .material-icons, .icofont, .typcn, mu, [class*="mu-"], .glyphicon, .icon), pre, code, tt {
            -webkit-font-smoothing: antialiased !important;
            -moz-osx-font-smoothing: grayscale !important;
            -ms-font-smoothing: antialiased !important;
            text-rendering: optimizeLegibility !important;
            font-synthesis: none !important;
            font-optical-sizing: auto !important;
        }`,
        `pre, code, tt {
            font-feature-settings: "liga", "clig", "calt" !important;
        }`,
    ];

    // Add all CSS rules
    cssRules.forEach(addStyle);
})();