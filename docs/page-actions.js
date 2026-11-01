// Page actions beside each chapter's title: copy the page as Markdown, or open
// it in an AI assistant picked from the "Open in AI" menu.
//
// The Markdown is a copy of the chapter's source that the docs workflow
// publishes beside its HTML (guide/trading.md next to guide/trading.html);
// mdBook itself copies no .md files into the book. Under `mdbook serve` the
// copies are absent, so Copy reports failure, and no assistant can fetch a
// localhost URL anyway.
//
// The source path comes from the meta tag theme/head.hbs writes, which only
// chapter pages carry.
(function () {
    // An assistant with `prefill` takes a question in its link, so it opens
    // asking it to read the page's Markdown, which hands it the page without the
    // sidebar, menu bar and inline icons. Gemini takes no question from its link,
    // so choosing it copies the page itself for the reader to paste, and Gemini
    // never has to fetch anything.
    var ASSISTANTS = [
        { name: 'ChatGPT', url: 'https://chatgpt.com/?hints=search&q=', prefill: true },
        { name: 'Claude', url: 'https://claude.ai/new?q=', prefill: true },
        { name: 'Grok', url: 'https://grok.com/?q=', prefill: true },
        { name: 'Gemini', url: 'https://gemini.google.com/app', prefill: false }
    ];

    var ICON_COPY = '<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="5.5" y="5.5" width="8" height="9" rx="1.5"/><path d="M10.5 3.5v-1a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h1"/></svg>';
    var ICON_SPARKLE = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 1.5l1.5 5 5 1.5-5 1.5-1.5 5-1.5-5-5-1.5 5-1.5z"/></svg>';
    var ICON_CHEVRON = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4 6l4 4 4-4"/></svg>';
    var ICON_EXTERNAL = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M9 2.5h4.5V7M13.5 2.5L7 9M11.5 9.5v3a1 1 0 0 1-1 1h-7a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1h3"/></svg>';

    function init() {
        var meta = document.querySelector('meta[name="bazaar-page-source"]');
        var title = document.querySelector('#mdbook-content main h1');
        if (!meta || !title) {
            return;
        }

        var markdownUrl = new URL(path_to_root + meta.content.replace(/\\/g, '/'), location.href).href;
        var question = 'Read ' + markdownUrl + ' from the Bazaar Protocol docs so I can ask questions about it.';
        var pasteIntro = 'Here is the "' + title.textContent.trim() + '" page of the Bazaar Protocol docs (' +
            location.origin + location.pathname + '). I want to ask questions about it.\n\n---\n\n';

        var actions = document.createElement('div');
        actions.className = 'page-actions';
        actions.setAttribute('role', 'group');
        actions.setAttribute('aria-label', 'Page actions');
        actions.innerHTML =
            '<button type="button" class="page-action page-action-copy" title="Copy this page as Markdown for LLMs">' + ICON_COPY +
                '<span class="page-action-copy-label" aria-live="polite">Copy page</span></button>' +
            '<div class="page-action-ai">' +
                '<button type="button" class="page-action page-action-toggle" aria-haspopup="menu" aria-expanded="false"' +
                    ' aria-controls="page-action-menu">' + ICON_SPARKLE + '<span>Open in AI</span>' + ICON_CHEVRON + '</button>' +
                '<ul class="page-action-menu" id="page-action-menu" role="menu" aria-label="Open in AI" hidden>' +
                    ASSISTANTS.map(function (assistant) {
                        return menuItem(assistant, question);
                    }).join('') +
                '</ul>' +
            '</div>';

        // The title and the actions share a wrapping row, so the actions sit
        // beside a title short enough to leave them room and drop beneath a
        // longer one rather than squeezing it.
        var row = document.createElement('div');
        row.className = 'page-title';
        title.parentNode.insertBefore(row, title);
        row.appendChild(title);
        row.appendChild(actions);

        var markdownRequest = null;
        var markdownText = null;
        function loadMarkdown() {
            if (!markdownRequest) {
                markdownRequest = fetchText(markdownUrl);
                markdownRequest.then(function (text) {
                    markdownText = text;
                }, function () {
                    markdownRequest = null;
                });
            }
            return markdownRequest;
        }

        var label = actions.querySelector('.page-action-copy-label');
        var resetTimer;
        actions.querySelector('.page-action-copy').addEventListener('click', function () {
            clearTimeout(resetTimer);
            copyText(loadMarkdown()).then(function () {
                label.textContent = 'Copied';
            }, function () {
                label.textContent = 'Copy failed';
            }).then(function () {
                resetTimer = setTimeout(function () {
                    label.textContent = 'Copy page';
                }, 2000);
            });
        });

        var toggle = actions.querySelector('.page-action-toggle');
        var menu = actions.querySelector('.page-action-menu');
        var items = Array.prototype.slice.call(menu.querySelectorAll('[role="menuitem"]'));

        function setMenu(open, focusToggle) {
            menu.hidden = !open;
            toggle.setAttribute('aria-expanded', String(open));
            if (open) {
                // Fetched now so the page is in hand by the time an item that
                // pastes it is chosen; see the click handler below.
                loadMarkdown().catch(function () {});
                items[0].focus();
            } else if (focusToggle) {
                toggle.focus();
            }
        }

        toggle.addEventListener('click', function () {
            setMenu(menu.hidden, false);
        });
        menu.addEventListener('click', function (event) {
            var item = event.target.closest('[role="menuitem"]');
            if (!item) {
                return;
            }
            // The write starts inside this click, while the docs tab still has
            // focus; once the link opens the assistant's tab, a write still
            // waiting on the fetch would be refused. Should the fetch not have
            // finished, the question pointing at the Markdown goes instead.
            if (item.dataset.paste && navigator.clipboard) {
                navigator.clipboard.writeText(markdownText === null ? question : pasteIntro + markdownText)
                    .catch(function () {});
            }
            setMenu(false, false);
        });
        menu.addEventListener('keydown', function (event) {
            var index = items.indexOf(document.activeElement);
            if (event.key === 'Escape') {
                setMenu(false, true);
            } else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
                var step = event.key === 'ArrowDown' ? 1 : items.length - 1;
                items[(index + step) % items.length].focus();
            } else if (event.key === 'Home' || event.key === 'End') {
                items[event.key === 'Home' ? 0 : items.length - 1].focus();
            } else if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') {
                return;
            }
            // mdBook's document-level handler turns the page on ArrowLeft and
            // ArrowRight wherever focus sits, so those are swallowed too rather
            // than navigating away from an open menu.
            event.preventDefault();
            event.stopPropagation();
        });
        document.addEventListener('click', function (event) {
            if (!menu.hidden && !actions.contains(event.target)) {
                setMenu(false, false);
            }
        });
        actions.addEventListener('focusout', function (event) {
            if (!menu.hidden && !actions.contains(event.relatedTarget)) {
                setMenu(false, false);
            }
        });
    }

    function menuItem(assistant, question) {
        var href = assistant.prefill ? assistant.url + encodeURIComponent(question) : assistant.url;
        var description = assistant.prefill ? 'Opens with your question ready' : 'Copies this page for you to paste';
        return '<li role="none"><a role="menuitem" class="page-action-item" href="' + href + '" target="_blank" rel="noopener"' +
            (assistant.prefill ? '' : ' data-paste="true"') + '>' + ICON_EXTERNAL +
            '<span><span class="page-action-item-title">' + assistant.name + '</span>' +
            '<span class="page-action-item-description">' + description + '</span></span></a></li>';
    }

    function fetchText(url) {
        return fetch(url).then(function (response) {
            if (!response.ok) {
                throw new Error('HTTP ' + response.status);
            }
            return response.text();
        });
    }

    // Safari grants clipboard access only within the click that asked for it,
    // which an awaited fetch outlasts. Handing ClipboardItem the pending text
    // keeps the write inside that click; writeText after the fetch covers
    // browsers whose ClipboardItem refuses a promise.
    function copyText(text) {
        if (!navigator.clipboard) {
            return Promise.reject(new Error('Clipboard unavailable'));
        }
        function writeText() {
            return text.then(function (value) {
                return navigator.clipboard.writeText(value);
            });
        }
        if (!window.ClipboardItem || !navigator.clipboard.write) {
            return writeText();
        }
        try {
            var blob = text.then(function (value) {
                return new Blob([value], { type: 'text/plain' });
            });
            return navigator.clipboard.write([new ClipboardItem({ 'text/plain': blob })]).catch(writeText);
        } catch (error) {
            return writeText();
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
