// ==UserScript==
// @name        Zerohazard's Font Script
// @author      twitter @Zerohazard8x + ChatGPT
// @match       *://*/*
// ==/UserScript==

const iconFonts = "Material Icons Extended, Material Icons, Google Material Icons, Material Design Icons, rtings-icons, VideoJS";

// Regular expression to test for fonts to replace
const fontRegex = /font1|font2|角/;

// Apply ligatures and font features to all text
document.body.style.fontVariantLigatures = "common";
document.body.style.fontVariantNumeric = "lining-nums";
document.body.style.fontFeatureSettings = "kern on";

// Loop through all elements with specified tags and check if they use a target font
["body", "h1", "h2", "p"].forEach(tag => {
  const elems = document.getElementsByTagName(tag);
  for (let i = 0; i < elems.length; i++) {
    const font = window.getComputedStyle(elems[i]).getPropertyValue("font-family");
    if (fontRegex.test(font)) {
      const matchedFont = font.match(fontRegex)[0]; // get the matched font
      elems[i].style.fontFamily = `${matchedFont}, ${iconFonts}`; // replace with matched font
    }
  }
});
