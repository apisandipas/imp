// imp website: the hero's recorded session, the feature tabs, copy buttons.

(() => {
  "use strict";

  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const stacked = () => window.matchMedia("(max-width: 720px)").matches;

  // ------------------------------------------------------------------
  // The hero session. It replays what this sequence does in imp:
  //   Go <the code> <esc>  SPC e b  C-w l  SPC i d
  // ------------------------------------------------------------------

  const TYPED = [
    "",
    "(define-command! 'insert-date",
    "  (lambda (count)",
    "    \"Insert today's date at the cursor.\"",
    "    (begin-change!)",
    "    (buffer-insert! (cursor)",
    "      (without-final-newline",
    "        (cadr (run-shell \"date +%F\" \"\"))))))",
    "(define-leader-group! \"i\" \"insert\")",
    "(define-leader! \"id\" 'insert-date \"insert date\")",
  ];

  const LEADER_TOP = [
    ["SPC", "find file"], ["b", "+buffer"], ["c", "+code"], ["e", "+eval"],
    ["f", "+file"], ["g", "+git"], ["h", "+help"], ["i", "+insert"],
    ["o", "+org"], ["p", "+project"], ["s", "+search"], ["w", "+window"],
  ];
  const LEADER_E = [
    ["b", "buffer"], ["d", "top-level form"], ["e", "form at cursor"],
    ["i", "REPL"], ["r", "region"], ["x", "expression"],
  ];
  const LEADER_I = [["d", "insert date"]];

  const today = () => {
    const d = new Date();
    const p = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
  };

  const initial = () => ({
    active: "left",
    mode: "NORMAL",
    left: {
      file: "init.scm", lang: "scheme", modified: false,
      lines: [";;; init.scm", "(load-theme! 'everforest-dark)", "(set-option! 'relativenumber #t)"],
      cur: [0, 0],
    },
    right: {
      file: "notes.md", lang: "markdown", modified: false,
      lines: ["# Release notes", "", "Window dividers you can grab.", "Shipped on ."],
      cur: [3, 11],
      fresh: null, // [line, from, to] of text just inserted
    },
  });

  const esc = (s) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));

  // One class per character of a line of Scheme.
  function schemeClasses(line) {
    const cls = new Array(line.length).fill("");
    let i = 0;
    while (i < line.length) {
      const c = line[i];
      if (c === ";") { cls.fill("t-c", i); break; }
      if (c === '"') {
        let j = i + 1;
        while (j < line.length && line[j] !== '"') j++;
        cls.fill("t-s", i, Math.min(j + 1, line.length));
        i = j + 1; continue;
      }
      if (c === "'") {
        let j = i + 1;
        while (j < line.length && !/[\s()]/.test(line[j])) j++;
        cls.fill("t-q", i, j); i = j; continue;
      }
      if (c === "#" && /[tf]/.test(line[i + 1] || "")) { cls.fill("t-b", i, i + 2); i += 2; continue; }
      if (c === "(" || c === ")") {
        cls[i] = "t-p";
        if (c === "(") {
          let j = i + 1;
          while (j < line.length && !/[\s()"]/.test(line[j])) j++;
          cls.fill("t-f", i + 1, j); i = j; continue;
        }
      }
      i++;
    }
    return cls;
  }

  function markdownClasses(line, lineNo, fresh) {
    const cls = new Array(line.length).fill(line.startsWith("#") ? "t-h" : "");
    if (fresh && fresh[0] === lineNo) cls.fill("t-new", fresh[1], fresh[2]);
    return cls;
  }

  function renderLine(text, cls, cursorCol, bar) {
    let html = "";
    const n = Math.max(text.length, cursorCol === null ? 0 : cursorCol + 1);
    let run = "", runCls = null;
    const flush = () => {
      if (run) html += runCls ? `<span class="${runCls}">${esc(run)}</span>` : esc(run);
      run = "";
    };
    for (let i = 0; i < n; i++) {
      const ch = i < text.length ? text[i] : " ";
      const c = cls[i] || "";
      if (i === cursorCol) {
        flush();
        html += `<span class="cursor${bar ? " bar" : ""}">${esc(ch)}</span>`;
        runCls = null; continue;
      }
      if (c !== runCls) { flush(); runCls = c; }
      run += ch;
    }
    flush();
    return html;
  }

  const demoEl = document.getElementById("demo");
  if (demoEl) {
    const els = {
      left: document.getElementById("pane-left"),
      right: document.getElementById("pane-right"),
      sLeft: document.getElementById("status-left"),
      sRight: document.getElementById("status-right"),
      leader: document.getElementById("leader"),
      keys: document.getElementById("keys"),
      steps: document.getElementById("steps"),
      replay: document.getElementById("replay"),
    };
    let st = initial();
    let run = 0;

    function paintPane(name) {
      const p = st[name];
      const active = st.active === name;
      const ol = els[name];
      const rows = Math.max(p.lines.length + 3, 14);
      let html = "";
      for (let i = 0; i < rows; i++) {
        if (i < p.lines.length) {
          const text = p.lines[i];
          const cls = p.lang === "scheme" ? schemeClasses(text) : markdownClasses(text, i, p.fresh);
          const onCursor = i === p.cur[0];
          const col = onCursor ? p.cur[1] : null;
          const bar = active && st.mode === "INSERT";
          html += `<li class="${onCursor ? "cur" : ""}"><span class="ln">${i + 1}</span><span class="tx">${renderLine(text, cls, col, bar)}</span></li>`;
        } else {
          html += `<li><span class="ln tilde">~</span><span class="tx"></span></li>`;
        }
      }
      ol.innerHTML = html;
      // Keep the cursor's line in view, as the editor scrolls.
      const visible = Math.floor(ol.clientHeight / (ol.firstElementChild?.offsetHeight || 1));
      const over = p.cur[0] - visible + 2;
      ol.scrollTop = over > 0 ? over * (ol.firstElementChild?.offsetHeight || 0) : 0;
      ol.parentElement.classList.toggle("active", active);

      const s = name === "left" ? els.sLeft : els.sRight;
      const mode = active
        ? `<span class="mode${st.mode === "INSERT" ? " insert" : ""}">${st.mode}</span>`
        : "";
      s.innerHTML = `${mode}<span class="file">${p.file}</span>${p.modified ? '<span class="mod">●</span>' : ""}` +
        `<span class="right">${p.lang}&nbsp;&nbsp;${p.cur[0] + 1}:${p.cur[1] + 1}</span>`;
    }

    function paint() { paintPane("left"); paintPane("right"); }

    function showLeader(title, items, hit) {
      if (!items) { els.leader.hidden = true; return; }
      els.leader.innerHTML = `<div class="lh">${esc(title)}</div>` + items.map(([k, d]) =>
        `<div class="${k === hit ? "hit" : ""}"><span class="lk">${esc(k)}</span> → <span class="ld">${esc(d)}</span></div>`).join("");
      els.leader.hidden = false;
    }

    let keyTimer;
    function key(label) {
      clearTimeout(keyTimer);
      const span = document.createElement("span");
      span.textContent = label;
      els.keys.appendChild(span);
      while (els.keys.children.length > 4) els.keys.firstChild.remove();
      keyTimer = setTimeout(() => { els.keys.innerHTML = ""; }, 1400);
    }

    function step(n) {
      [...els.steps.children].forEach((li) => {
        const k = Number(li.dataset.step);
        li.classList.toggle("on", k === n);
        li.classList.toggle("done", k < n);
      });
    }

    const sleep = (ms, id) => new Promise((res, rej) =>
      setTimeout(() => (id === run ? res() : rej(new Error("stopped"))), ms));

    async function play() {
      const id = ++run;
      st = initial();
      els.keys.innerHTML = "";
      showLeader(null);
      step(0);
      paint();
      const L = st.left;
      try {
        await sleep(900, id);
        step(1);
        key("G"); L.cur = [L.lines.length - 1, 0]; paint(); await sleep(450, id);
        key("o"); L.lines.push(""); L.cur = [L.lines.length - 1, 0]; st.mode = "INSERT"; L.modified = true; paint();
        await sleep(350, id);
        for (let li = 0; li < TYPED.length; li++) {
          const target = TYPED[li];
          if (li > 0) { L.lines.push(""); L.cur = [L.lines.length - 1, 0]; }
          const indent = target.match(/^ */)[0];
          L.lines[L.lines.length - 1] = indent;
          L.cur[1] = indent.length;
          paint();
          for (let c = indent.length; c < target.length; c++) {
            L.lines[L.lines.length - 1] = target.slice(0, c + 1);
            L.cur[1] = c + 1;
            paint();
            await sleep(target[c] === " " ? 34 : 22, id);
          }
          await sleep(110, id);
        }
        key("Esc"); st.mode = "NORMAL"; L.cur[1] = Math.max(0, L.cur[1] - 1); paint();
        await sleep(700, id);

        step(2);
        key("SPC"); showLeader("SPC", LEADER_TOP); await sleep(800, id);
        showLeader("SPC", LEADER_TOP, "e"); await sleep(250, id);
        key("e"); showLeader("SPC e", LEADER_E); await sleep(700, id);
        showLeader("SPC e", LEADER_E, "b"); await sleep(250, id);
        key("b"); showLeader(null); key("✓ insert-date defined");
        await sleep(1500, id);

        step(3);
        key(stacked() ? "C-w j" : "C-w l"); st.active = "right"; paint();
        await sleep(800, id);
        key("SPC"); showLeader("SPC", LEADER_TOP); await sleep(700, id);
        showLeader("SPC", LEADER_TOP, "i"); await sleep(250, id);
        key("i"); showLeader("SPC i", LEADER_I, "d"); await sleep(700, id);
        key("d"); showLeader(null);
        const R = st.right;
        const [ln, col] = R.cur;
        const date = today();
        R.lines[ln] = R.lines[ln].slice(0, col) + date + R.lines[ln].slice(col);
        R.cur = [ln, col + date.length];
        R.fresh = [ln, col, col + date.length];
        R.modified = true;
        paint();
        await sleep(2600, id);
        R.fresh = null; paint();
        step(4);
      } catch (e) { /* a newer run took over */ }
    }

    function finalState() {
      st = initial();
      st.left.lines.push(...TYPED);
      st.left.cur = [st.left.lines.length - 1, 0];
      st.left.modified = true;
      st.active = "right";
      const R = st.right;
      const [ln, col] = R.cur;
      const date = today();
      R.lines[ln] = R.lines[ln].slice(0, col) + date + R.lines[ln].slice(col);
      R.cur = [ln, col + date.length];
      R.modified = true;
      paint();
      step(4);
    }

    els.replay.addEventListener("click", () => { reduced ? finalState() : play(); });

    if (reduced) {
      finalState();
    } else {
      paint();
      let started = false;
      const io = new IntersectionObserver((entries) => {
        if (!started && entries.some((e) => e.isIntersecting)) { started = true; play(); io.disconnect(); }
      }, { threshold: 0.2 });
      io.observe(demoEl);
    }
  }

  // ------------------------------------------------------------------
  // Tabs (ARIA tablist with arrow keys)
  // ------------------------------------------------------------------
  document.querySelectorAll('[role="tablist"]').forEach((list) => {
    const tabs = [...list.querySelectorAll('[role="tab"]')];
    const select = (tab, focus) => {
      tabs.forEach((t) => {
        const on = t === tab;
        t.setAttribute("aria-selected", String(on));
        t.tabIndex = on ? 0 : -1;
        document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
      });
      if (focus) tab.focus();
    };
    tabs.forEach((t, i) => {
      t.addEventListener("click", () => select(t));
      t.addEventListener("keydown", (e) => {
        const d = { ArrowRight: 1, ArrowLeft: -1, l: 1, h: -1 }[e.key];
        if (d) { e.preventDefault(); select(tabs[(i + d + tabs.length) % tabs.length], true); }
        if (e.key === "Home") { e.preventDefault(); select(tabs[0], true); }
        if (e.key === "End") { e.preventDefault(); select(tabs[tabs.length - 1], true); }
      });
    });
  });

  // Lazy images in hidden tab panels never load until their tab opens, so
  // fetch them once the page has loaded: switching tabs is then instant.
  window.addEventListener("load", () => {
    document.querySelectorAll(".panel img").forEach((img) => {
      img.loading = "eager";
      new Image().src = img.currentSrc || img.src;
    });
  });

  // ------------------------------------------------------------------
  // Copy buttons
  // ------------------------------------------------------------------
  document.querySelectorAll(".copy").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const text = btn.parentElement.querySelector("code").textContent;
      try {
        await navigator.clipboard.writeText(text);
        btn.textContent = "Copied";
        btn.classList.add("ok");
      } catch {
        btn.textContent = "Select and copy";
      }
      setTimeout(() => { btn.textContent = "Copy"; btn.classList.remove("ok"); }, 1800);
    });
  });
})();
