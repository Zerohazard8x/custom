// ==UserScript==
// @name            SomeName
// @description     Prevents websites from taking information about activities
// @match           *://*/*
// @run-at          document-end
// @grant           none
// @exclude         *bing.com*
// @exclude         *discord.com*
// @exclude         *youtube.com*
// @exclude         *nvidia.com*
// @exclude         *lazada.com.ph*
// @exclude         *alicdn.com*
// @exclude         *live.com*
// @exclude         *pcpartpicker.com*
// ==/UserScript==

const preventEvent = function (event) {
  event.stopPropagation();
  event.stopImmediatePropagation();
};

[
  // window.onload -> "onload"
  "onload",
  "onclick",
  "onkeypress",
  "ontouchstart",
  "onmousemove",
  "onmousedown",
  "onbeforeunload",
  "onunload",
  "onhashchange",
  "onpopstate",
  "oncontextmenu",
  "ondragstart",
  "ondragend",
  "ondragover",
  "ondragenter",
  "ondragleave",
  "ondrop",
].forEach((event) => {
  window[event] = preventEvent;
});

document.addEventListener("visibilitychange", preventEvent);

// Removing all event listeners "visibilitychange"
const visibilityChangeEvent = "visibilitychange";
const oldAddEventListener = EventTarget.prototype.addEventListener;
const oldRemoveEventListener = EventTarget.prototype.removeEventListener;
const listeners = new Map();

EventTarget.prototype.addEventListener = function (type, listener, options) {
  if (type === visibilityChangeEvent) {
    listeners.set(listener, options);
  }
  oldAddEventListener.call(this, type, listener, options);
};

EventTarget.prototype.removeEventListener = function (type, listener) {
  if (type === visibilityChangeEvent) {
    listeners.delete(listener);
  }
  oldRemoveEventListener.call(this, type, listener);
};

function removeAllVisibilityChangeListeners() {
  for (const [listener, options] of listeners) {
    document.removeEventListener(visibilityChangeEvent, listener, options);
  }
  listeners.clear();
}
removeAllVisibilityChangeListeners();
