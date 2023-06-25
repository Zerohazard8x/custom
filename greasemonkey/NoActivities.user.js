// ==UserScript==
// @name            NoActivities
// @description     Prevents websites from taking information about activities
// @author          Zerohazard8x + LLM
// @include         *instructure.com*
// @run-at          document-end
// @grant           none
// ==/UserScript==

const preventEvent = function (event) {
    event.stopPropagation();
    event.stopImmediatePropagation();
};

const eventsToPrevent = [
    "load",
    "keypress",
    "touchstart",
    "mousemove",
    "mousedown",
    "beforeunload",
    "unload",
    "hashchange",
    "popstate",
    "contextmenu",
    "dragstart",
    "dragend",
];

// Prevent events on window and document objects
eventsToPrevent.forEach(function (event) {
    window.addEventListener(event, preventEvent, true);
    document.addEventListener(event, preventEvent, true);
});

// Remove event listeners concerned with the events in eventsToPrevent
const originalAddEventListener = EventTarget.prototype.addEventListener;
const originalRemoveEventListener = EventTarget.prototype.removeEventListener;

EventTarget.prototype.addEventListener = function (type, listener, options) {
    if (eventsToPrevent.includes(type)) {
        return;
    }
    originalAddEventListener.call(this, type, listener, options);
};

EventTarget.prototype.removeEventListener = function (type, listener, options) {
    if (eventsToPrevent.includes(type)) {
        return;
    }
    originalRemoveEventListener.call(this, type, listener, options);
};
