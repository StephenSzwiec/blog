// theme.js — apply saved theme on load (also called inline in <head>)
// and provide window.toggleTheme for the header button.
//
// The critical "read from localStorage" snippet is inlined in the <head>
// via render.lua to avoid flash-of-wrong-theme.  This file adds the
// toggle function and is loaded at end of <body>.

window.toggleTheme = function () {
  var root = document.documentElement;
  var current = root.dataset.theme;
  // If no explicit data-theme, fall back to system preference
  if (!current) {
    current = window.matchMedia('(prefers-color-scheme: dark)').matches
      ? 'dark' : 'light';
  }
  var next = current === 'dark' ? 'light' : 'dark';
  root.dataset.theme = next;
  localStorage.setItem('theme', next);
};
