(function () {
  var html = document.documentElement;
  // date
  var t = document.getElementById('today');
  if (t) {
    var d = new Date(),
        wd = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'],
        mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    t.textContent = wd[d.getDay()] + ', ' + String(d.getDate()).padStart(2, '0') + ' ' + mo[d.getMonth()] + ' ' + d.getFullYear();
  }
  // theme
  var tg = document.getElementById('theme-toggle');
  if (tg) tg.addEventListener('click', function () {
    var next = html.dataset.theme === 'light' ? 'dark' : 'light';
    html.dataset.theme = next; try { localStorage.setItem('theme', next); } catch (e) {}
  });
  // scroll-to-top. On wide screens the article scrolls inside the main column, so the
  // window never moves; below 1100px the column is static and the page scrolls instead.
  var top = document.getElementById('to-top'), main = document.getElementById('main');
  function scroller() {
    return (main && main.scrollHeight > main.clientHeight + 1) ? main : window;
  }
  function scrolled() {
    var s = scroller();
    return s === window ? window.scrollY : s.scrollTop;
  }
  if (top) {
    // Reveal on upward scroll only: reading downwards should not be interrupted, and the
    // arrow appears exactly when the intent to go back has been expressed. It stays put
    // once shown - auto-hiding on a timer would make it unclickable.
    var last = scrolled(), pending = false;
    top.hidden = false;   // JS is present; visibility is a class from here on

    function apply() {
      pending = false;
      var now = scrolled(), delta = now - last;
      if (now <= 200) { top.classList.remove('is-visible'); last = now; return; }
      if (Math.abs(delta) < 6) return;   // ignore jitter and trackpad noise
      top.classList.toggle('is-visible', delta < 0);
      last = now;
    }
    function onScroll() { if (!pending) { pending = true; requestAnimationFrame(apply); } }

    top.addEventListener('click', function () { scroller().scrollTo({ top: 0, behavior: 'smooth' }); });
    window.addEventListener('scroll', onScroll, { passive: true });
    if (main) main.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', function () { last = scrolled(); }, { passive: true });
  }
  // client detected
  var ipEl = document.getElementById('c-ip');
  if (ipEl) {
    var ua = document.getElementById('c-ua'), la = document.getElementById('c-lang'), tz = document.getElementById('c-tz');
    if (ua) ua.textContent = navigator.userAgent;
    if (la) la.textContent = navigator.language;
    if (tz) tz.textContent = Intl.DateTimeFormat().resolvedOptions().timeZone;
    var ep = ipEl.closest('[data-ip-endpoint]').dataset.ipEndpoint;
    if (ep) fetch(ep).then(function (r) { return r.json(); }).then(function (j) { ipEl.textContent = j.ip || 'n/a'; }).catch(function () { ipEl.textContent = 'n/a'; });
  }
  // search
  var input = document.getElementById('search-input'), list = document.getElementById('search-results'), idx = null;
  function base() { var b = document.querySelector('base'); return b ? b.href : '/'; }
  function load() { return idx ? Promise.resolve(idx) : fetch('/index.json').then(function (r) { return r.json(); }).then(function (j) { idx = j; return j; }); }
  function render(items, q) {
    list.innerHTML = '';
    if (!q) { list.hidden = true; return; }
    if (!items.length) { list.innerHTML = '<li class="none">no results for "' + q.replace(/</g, '&lt;') + '"</li>'; list.hidden = false; return; }
    items.slice(0, 8).forEach(function (p) {
      var li = document.createElement('li'), a = document.createElement('a'), tm = document.createElement('time'), s = document.createElement('span');
      a.href = p.url; tm.textContent = p.date; s.textContent = p.title; a.appendChild(tm); a.appendChild(s); li.appendChild(a); list.appendChild(li);
    });
    list.hidden = false;
  }
  if (input) {
    input.addEventListener('input', function () {
      var q = input.value.trim().toLowerCase();
      load().then(function (posts) {
        render(posts.filter(function (p) {
          return (p.title + ' ' + (p.summary || '') + ' ' + (p.tags || []).join(' ') + ' ' + (p.categories || []).join(' ')).toLowerCase().indexOf(q) > -1;
        }), q);
      });
    });
    document.addEventListener('keydown', function (e) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); input.focus(); }
      if (e.key === 'Escape') { list.hidden = true; input.blur(); }
    });
    document.addEventListener('click', function (e) { if (!e.target.closest('#search')) list.hidden = true; });
  }
})();
