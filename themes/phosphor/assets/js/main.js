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
  // scroll-to-top: shows when search field leaves viewport
  var top = document.getElementById('to-top'), bar = document.getElementById('search');
  if (top) {
    top.addEventListener('click', function () { window.scrollTo({ top: 0, behavior: 'smooth' }); });
    if (bar && 'IntersectionObserver' in window) {
      new IntersectionObserver(function (e) { top.hidden = e[0].isIntersecting; }, { threshold: 0 }).observe(bar);
    } else {
      window.addEventListener('scroll', function () { top.hidden = window.scrollY < 200; }, { passive: true });
    }
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
