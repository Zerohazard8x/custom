// ==UserScript==
// @name         Hide ALL Twitch Replies
// @namespace    http://tampermonkey.net/
// @match        https://www.twitch.tv/*
// @grant        none
// @version      1.0
// @description  Hide all reply headers/messages in Twitch chat (client-side, per-browser) - Adapted by LLM from reddit.com/r/Twitch/comments/1jzgdng
// ==/UserScript==

(function() {
    'use strict';

    const observer = new MutationObserver(mutations => {
        for (const m of mutations) {
            if (!m.addedNodes) continue;
            for (const node of m.addedNodes) {
                try {
                    const messages = node.querySelectorAll ? node.querySelectorAll('.chat-line__message, .vod-message') : [];
                    messages.forEach(message => {
                        // Twitch places a small reply header with a title like "Replying to @username"
                        const replyTitle = message.querySelector('p[title^="Replying to"]');
                        if (replyTitle) {
                            // hide the whole message container
                            message.style.display = 'none';
                        }
                    });
                } catch (e) { /* ignore nodes that aren't elements */ }
            }
        }
    });

    const chatContainer = document.querySelector('.chat-scrollable-area__message-container') || document.body;
    observer.observe(chatContainer, { childList: true, subtree: true });

    console.log('Hide ALL Twitch Replies script active.');
})();
