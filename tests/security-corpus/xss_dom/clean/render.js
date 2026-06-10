// CLEAN: textContent never parses HTML.
export function render(el) { el.textContent = decodeURIComponent(location.hash.slice(1)); }
