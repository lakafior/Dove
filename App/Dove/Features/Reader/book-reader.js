// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Dove's EPUB reader: a layer over epub.js 0.3.93 (BSD-2-Clause), written for AudiobookSwift by the same author
// and brought over. Swift drives it through `window.book`; answers go to `webkit.messageHandlers.book`. The book's
// own scripts never run (`allowScriptedContent: false`).
(function () {
  'use strict'

  const send = (type, data) => {
    try {
      window.webkit.messageHandlers.book.postMessage(Object.assign({ type }, data || {}))
    } catch (e) {}
  }
  const text = (e) => String((e && (e.stack || e.message)) || e)
  window.addEventListener('error', (e) => send('error', { message: String(e.message || e) }))
  window.addEventListener('unhandledrejection', (e) => send('error', { message: text(e.reason) }))

  let epub = null
  let rendition = null
  // No moves are reported until the saved place is on screen: the start of the chapter would otherwise overwrite
  // the place another device saved.
  let shown = false
  let look = { page: '#ffffff', ink: '#1c1c1e', link: '#0a60c2', font: '', size: 100, leading: 1.5 }

  function css(l) {
    const family = l.font ? `font-family: ${l.font} !important;` : ''
    return `
      html, body { background: ${l.page} !important; color: ${l.ink} !important; }
      body { line-height: ${l.leading} !important; ${family} }
      body * { color: inherit !important; background-color: transparent !important; ${family} }
      body p, body li, body blockquote, body div { line-height: ${l.leading} !important; }
      body a, body a * { color: ${l.link} !important; }
      img, svg, video { max-width: 100% !important; }
    `
  }

  function applyLook() {
    document.documentElement.style.setProperty('--page', look.page)
    if (!rendition) return
    rendition.getContents().forEach((c) => c.addStylesheetCss(css(look), 'dove'))
    rendition.themes.fontSize(`${look.size}%`)
  }

  // The table of contents, flat with depths; hrefs as the navigation file has them (`go` matches them to spine
  // items by the end of the path).
  function contents() {
    const out = []
    const visit = (list, depth) => {
      for (const item of list || []) {
        out.push({ label: (item.label || '').trim(), href: item.href || '', depth })
        visit(item.subitems, depth + 1)
      }
    }
    visit(epub.navigation && epub.navigation.toc, 0)
    return out
  }

  function spineItemFor(path) {
    const items = (epub.spine && epub.spine.spineItems) || []
    return items.find((s) => s.href && (path === s.href || path.endsWith('/' + s.href) || s.href.endsWith('/' + path)))
  }

  function chapterTitle(href) {
    if (!href || !epub.navigation) return null
    const item = epub.navigation.get(href)
    return item ? (item.label || '').trim() : null
  }

  function where(location) {
    return {
      cfi: location.start.cfi,
      href: location.start.href,
      // The end of the visible page, so the last page is 100%.
      progress: epub.locations.length() ? location.end.percentage : null,
      chapter: chapterTitle(location.start.href),
      atStart: !!location.atStart,
      atEnd: !!location.atEnd
    }
  }

  function size() {
    const box = document.getElementById('book')
    return { width: box.clientWidth, height: box.clientHeight }
  }

  const api = {
    open(options) {
      look = Object.assign(look, options.look || {})
      applyLayout(options.layout)
      applyLook()
      epub = ePub('dovebook://local/book.epub', { openAs: 'epub' })
      const box = size()
      rendition = epub.renderTo('book', {
        width: box.width,
        height: box.height,
        flow: 'paginated',
        spread: options.spread || 'none',
        allowScriptedContent: false
      })
      rendition.on('rendered', (section, view) => {
        applyLook()
        // Links are Swift's (the frame runs no scripts): without `target` a tap navigates the frame, and the app
        // catches that navigation and hands it to `book.link`.
        const doc = view && view.contents && view.contents.document
        if (doc) doc.querySelectorAll('a[target]').forEach((a) => a.removeAttribute('target'))
      })
      rendition.on('relocated', (location) => {
        if (shown) send('moved', where(location))
      })
      const start = options.location && String(options.location).startsWith('epubcfi(') ? options.location : undefined
      rendition
        .display(start)
        .catch((error) => {
          send('log', { message: 'the saved place does not open: ' + text(error) })
          return rendition.display()
        })
        .then(() => {
          // WebKit can leave the page blank after starting mid-chapter; showing the same place again a moment
          // later draws it.
          const location = rendition.currentLocation()
          if (start && location && location.start) {
            return new Promise((resolve) => setTimeout(resolve, 60)).then(() => rendition.display(location.start.cfi))
          }
        })
        .then(() => {
          shown = true
          api.report()
        })
        .catch((error) => send('error', { message: 'display: ' + text(error) }))

      epub.ready
        .then(() => {
          const meta = epub.package.metadata || {}
          send('opened', { title: meta.title || '', toc: contents(), rtl: meta.direction === 'rtl' })
          if (options.locations) {
            epub.locations.load(options.locations)
            send('locationsReady', {})
            api.report()
          } else {
            // The default split, so the percentage means the same on every device.
            epub.locations.generate().then(() => {
              send('locations', { json: epub.locations.save() })
              send('locationsReady', {})
              api.report()
            })
          }
        })
        .catch((error) => send('error', { message: text(error) }))
    },
    report() {
      if (!shown || !rendition || !rendition.manager) return
      const location = rendition.currentLocation()
      if (location && location.start) send('moved', where(location))
    },
    next() {
      if (rendition && rendition.manager) return rendition.next()
    },
    prev() {
      if (rendition && rendition.manager) return rendition.prev()
    },
    // A table of contents entry or a CFI.
    go(target) {
      if (!rendition || !rendition.manager) return
      if (String(target).startsWith('epubcfi(')) return rendition.display(target)
      const [path, hash] = String(target).split('#')
      const item = spineItemFor(decodeURIComponent(path).replace(/^(\.\.?\/)+/, ''))
      return rendition.display(item ? item.href + (hash ? '#' + hash : '') : target)
    },
    // A link inside the book (the address the frame tried to go to).
    link(url) {
      let path = url
      let hash = ''
      try {
        const parsed = new URL(url)
        path = decodeURIComponent(parsed.pathname)
        hash = parsed.hash
      } catch (e) {}
      const item = spineItemFor(path.replace(/^\/+/, ''))
      if (item) rendition.display(item.href + hash)
      else send('log', { message: 'link to no chapter: ' + url })
    },
    // A place from the slider (0…1); needs the locations.
    seek(fraction) {
      if (!rendition || !epub.locations.length()) return
      const cfi = epub.locations.cfiFromPercentage(Math.min(1, Math.max(0, fraction)))
      if (cfi) return rendition.display(cfi)
    },
    setLook(next) {
      look = Object.assign(look, next || {})
      applyLook()
    },
    setLayout(layout) {
      applyLayout(layout)
      api.resize()
    },
    setSpread(spread) {
      if (rendition) rendition.spread(spread || 'none')
    },
    // A new size (rotation, margins): lay the text out again and return to the same place.
    resize() {
      const box = size()
      if (!rendition || !rendition.manager || box.width <= 0 || box.height <= 0) return
      const location = rendition.currentLocation()
      if (!restoreCfi) restoreCfi = location && location.start && location.start.cfi
      rendition.resize(box.width, box.height)
      // Back to the place from before only once the size settles (a rotation sends several events).
      clearTimeout(restoreTimer)
      restoreTimer = setTimeout(() => {
        const cfi = restoreCfi
        restoreCfi = null
        if (cfi) rendition.display(cfi).then(repaint)
      }, 400)
    }
  }

  // WebKit does not always repaint the chapter frame after the container scrolls in code (the screen stays on the
  // old page though the DOM is on the new one); an opacity change in the next frame forces it.
  function repaint() {
    const box = document.getElementById('book')
    box.style.opacity = '0.99'
    requestAnimationFrame(() => requestAnimationFrame(() => { box.style.opacity = '' }))
  }

  // The page's side margins and room for the app's bars (top and bottom), in points.
  function applyLayout(layout) {
    if (!layout) return
    const root = document.documentElement.style
    root.setProperty('--side', `${layout.side || 20}px`)
    root.setProperty('--top', `${layout.top || 0}px`)
    root.setProperty('--bottom', `${layout.bottom || 0}px`)
  }

  let resizeTimer = null
  let restoreTimer = null
  let restoreCfi = null
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimer)
    resizeTimer = setTimeout(() => api.resize(), 120)
  })

  window.book = api
  send('ready', {})
})()
