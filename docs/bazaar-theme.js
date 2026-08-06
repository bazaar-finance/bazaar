// Renames the theme picker's "Ayu" entry to "Liberty", the display name for
// Bazaar's black-and-yellow palette.
//
// mdBook hardcodes its theme list in the index.hbs template, so the theme's
// internal id stays `ayu` — that is the class bazaar-theme.css restyles and the
// value book.toml selects. Only the visible label changes here. Relabeling from
// script rather than vendoring a copy of index.hbs keeps the docs buildable on
// any mdBook version, which matters because the template is not stable across
// releases: it renamed the picker's button ids from `ayu` to `mdbook-theme-ayu`
// in 0.5, so a vendored copy would build correctly on one version and produce a
// broken page on the other. The selector below matches either id, scoped to the
// picker so it cannot collide with a heading anchor of the same name.
//
// The picker is closed on load, so the label is never seen before it is swapped.
(function () {
    function renameTheme() {
        var button = document.querySelector('.theme-popup button.theme[id$="ayu"]');
        if (button) {
            button.textContent = 'Liberty';
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', renameTheme);
    } else {
        renameTheme();
    }
})();
