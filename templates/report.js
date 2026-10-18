// Interacción de los reportes: filtro, chips de severidad, orden, copiar comandos, KPIs, anclas e impresión.
// Sin dependencias ni red; el DOM se construye solo con createElement y textContent. Lo autoriza la CSP por hash.
(function () {
  'use strict';
  var SEV = { crit: 'Crítico', warn: 'Advertencia', info: 'Info' };
  var RANK = { crit: 0, warn: 1, info: 2 };
  var cache = new WeakMap();   // fila -> texto normalizado (perezoso)
  var states = new Map();      // tabla -> estado del filtro

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }
  // Minúsculas y sin acentos: 'Crítico' y 'critico' coinciden.
  function norm(s) { return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase(); }
  function rowText(tr) {
    var t = cache.get(tr);
    if (t === undefined) { t = norm(tr.textContent); cache.set(tr, t); }
    return t;
  }
  function rows(table) { return table.tBodies.length ? Array.prototype.slice.call(table.tBodies[0].rows) : []; }

  // ---- Filtro y chips ----
  function apply(st) {
    var q = norm(st.input.value.trim()), shown = 0;
    for (var i = 0; i < st.rows.length; i++) {
      var tr = st.rows[i], sev = tr.getAttribute('data-sev');
      var ok = (!sev || !st.chips[sev] || st.active[sev]) && (!q || rowText(tr).indexOf(q) !== -1);
      if (tr.hidden === ok) tr.hidden = !ok;
      if (ok) shown++;
    }
    st.count.textContent = shown + ' de ' + st.rows.length + ' filas';
  }
  function setChip(st, sev, on) {
    st.active[sev] = on;
    st.chips[sev].setAttribute('aria-pressed', on ? 'true' : 'false');
  }
  function setupFilter(table) {
    var scroll = table.closest('.scroll') || table;
    var st = { table: table, rows: rows(table), chips: {}, active: {}, timer: 0 };
    var bar = el('div', 'tbl-tools');
    st.input = el('input', 'tbl-q');
    st.input.type = 'search';
    st.input.placeholder = 'Filtrar…';
    st.input.setAttribute('aria-label', 'Filtrar filas');
    bar.appendChild(st.input);
    if (table.querySelector('th[data-col="severity"]')) {
      Object.keys(SEV).forEach(function (sev) {
        var n = st.rows.filter(function (tr) { return tr.getAttribute('data-sev') === sev; }).length;
        if (!n) return;
        var b = el('button', 'chip ' + sev, SEV[sev] + ' ');
        b.type = 'button';
        b.setAttribute('data-sev', sev);
        b.appendChild(el('span', 'cnt', String(n)));
        b.addEventListener('click', function () { setChip(st, sev, !st.active[sev]); apply(st); });
        st.chips[sev] = b;
        setChip(st, sev, true);
        bar.appendChild(b);
      });
    }
    st.count = el('span', 'tbl-count');
    st.count.setAttribute('aria-live', 'polite');
    bar.appendChild(st.count);
    st.input.addEventListener('input', function () {
      clearTimeout(st.timer);
      st.timer = setTimeout(function () { apply(st); }, 150);
    });
    scroll.parentNode.insertBefore(bar, scroll);
    states.set(table, st);
    apply(st);
  }

  // ---- Orden por columna (clic, Enter o Espacio) ----
  function cellKey(tr, idx, numeric, sevCol) {
    var td = tr.cells[idx];
    if (sevCol && tr.getAttribute('data-sev') in RANK) return RANK[tr.getAttribute('data-sev')];
    if (!td || td.classList.contains('empty-cell')) return null;
    var t = td.textContent.trim();
    if (!t || t === '—') return null;
    if (!numeric) return t;
    var v = parseFloat(t.replace(/[\s ]/g, '').replace(/,(?=\d{3}(\D|$))/g, ''));
    return isNaN(v) ? null : v;
  }
  function sortBy(table, th) {
    var tbody = table.tBodies[0];
    if (!tbody) return;
    var idx = th.cellIndex, numeric = th.classList.contains('n');
    var sevCol = th.getAttribute('data-col') === 'severity';
    var dir = th.getAttribute('aria-sort') === 'ascending' ? -1 : 1;
    var keyed = rows(table).map(function (tr) { return { k: cellKey(tr, idx, numeric, sevCol), tr: tr }; });
    keyed.sort(function (a, b) {
      if (a.k === null || b.k === null) return (a.k === null) - (b.k === null);   // vacíos siempre al final
      if (numeric || sevCol) return dir * (a.k - b.k);
      return dir * a.k.localeCompare(b.k, 'es', { numeric: true, sensitivity: 'base' });
    });
    var frag = document.createDocumentFragment();
    keyed.forEach(function (o) { frag.appendChild(o.tr); });
    tbody.appendChild(frag);   // un solo reflow
    Array.prototype.forEach.call(th.parentNode.cells, function (c) { if (c !== th) c.removeAttribute('aria-sort'); });
    th.setAttribute('aria-sort', dir === 1 ? 'ascending' : 'descending');
    var st = states.get(table);
    if (st) st.rows = keyed.map(function (o) { return o.tr; });
  }
  function setupSort(table) {
    if (!table.tHead) return;
    Array.prototype.forEach.call(table.tHead.rows[0].cells, function (th) {
      th.tabIndex = 0;
      th.title = 'Ordenar por esta columna';
      th.addEventListener('click', function () { sortBy(table, th); });
      th.addEventListener('keydown', function (e) {
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); sortBy(table, th); }
      });
    });
  }

  // ---- Copiar comandos ----
  function flash(btn, text) {
    btn.textContent = text;
    clearTimeout(btn._t);
    btn._t = setTimeout(function () { btn.textContent = 'Copiar'; }, 1500);
  }
  function selectText(node) {
    var r = document.createRange(), sel = window.getSelection();
    r.selectNodeContents(node);
    sel.removeAllRanges();
    sel.addRange(r);
    try { return document.execCommand('copy'); } catch (e) { return false; }
  }
  function setupCopy(code) {
    var btn = el('button', 'copy', 'Copiar');
    btn.type = 'button';
    btn.setAttribute('aria-label', 'Copiar comando');
    btn.addEventListener('click', function () {
      var text = code.textContent;
      var fallback = function () { flash(btn, selectText(code) ? 'Copiado' : 'Seleccionado'); };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () { flash(btn, 'Copiado'); }, fallback);
      } else fallback();
    });
    code.parentNode.insertBefore(btn, code.nextSibling);
  }

  // ---- Anclas: abrir el details destino o sus ancestros ----
  function target(hash) {
    if (!hash || hash.length < 2) return null;
    try { return document.getElementById(decodeURIComponent(hash.slice(1))); } catch (e) { return null; }
  }
  function reveal(node) {
    for (var d = node; d; d = d.parentElement) if (d.tagName === 'DETAILS' && !d.open) d.open = true;
  }

  // ---- KPIs: abrir la sección y dejar activo solo el chip de esa severidad ----
  function kpiClick(a) {
    var dest = target(a.getAttribute('href')), sev = a.getAttribute('data-sev');
    if (!dest) return;
    reveal(dest);
    var table = dest.querySelector('table[data-filter]'), st = table && states.get(table);
    if (!st || !st.chips[sev]) return;
    Object.keys(st.chips).forEach(function (k) { setChip(st, k, k === sev); });
    apply(st);
  }

  // ---- Impresión: abrir todo y restaurar después ----
  var closedForPrint = [];
  window.addEventListener('beforeprint', function () {
    closedForPrint = Array.prototype.filter.call(document.querySelectorAll('details'), function (d) { return !d.open; });
    closedForPrint.forEach(function (d) { d.open = true; });
  });
  window.addEventListener('afterprint', function () {
    closedForPrint.forEach(function (d) { d.open = false; });
    closedForPrint = [];
  });

  document.querySelectorAll('table[data-filter]').forEach(function (t) { setupFilter(t); setupSort(t); });
  document.querySelectorAll('code.cmd').forEach(setupCopy);
  document.addEventListener('click', function (e) {
    var a = e.target.closest && e.target.closest('a[href^="#"]');
    if (!a) return;
    if (a.matches('a.kpi[data-sev]')) kpiClick(a);
    else { var t = target(a.getAttribute('href')); if (t) reveal(t); }
  });
  window.addEventListener('hashchange', function () { var t = target(location.hash); if (t) reveal(t); });
  var initial = target(location.hash);
  if (initial) { reveal(initial); initial.scrollIntoView(); }
})();
